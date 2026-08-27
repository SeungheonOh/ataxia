;;;; Kernel aggregate and lifecycle.
;;;;
;;;; One Kernel owns all stable Wayland identities and the single Runtime/World
;;;; connection. Its tables are direct indexes, not independently communicating
;;;; managers.

(in-package #:ataxia.kernel)

(defclass kernel (ataxia.runtime:runtime-sink)
  ((runtime :initform nil :accessor kernel-runtime)
   (world :initarg :world :accessor kernel-world)
   (world-watchdog :initarg :world-watchdog :reader %kernel-world-watchdog)
   (state :initform :constructing :accessor kernel-state)
   (next-object-id :initform 0 :accessor %kernel-next-object-id)
   (objects :initform (make-hash-table :test #'eql)
            :reader %kernel-object-table)
   (runtime-index :initform (make-hash-table :test #'eq)
                  :reader %kernel-runtime-index)
   (outputs :initform (make-hash-table :test #'eq)
            :reader %kernel-output-table)
   (input-devices :initform (make-hash-table :test #'eq)
                  :reader %kernel-input-table)
   (seats :initform (make-hash-table :test #'eq)
          :reader %kernel-seat-table)
   (surfaces :initform (make-hash-table :test #'eq)
             :reader %kernel-surface-table)
   (toplevels :initform (make-hash-table :test #'eq)
              :reader %kernel-toplevel-table)
   (popups :initform (make-hash-table :test #'eq)
           :reader %kernel-popup-table)
   (default-seat :initform nil :accessor %kernel-default-seat)
   (graphics-attached-p :initform nil :accessor %kernel-graphics-attached-p)
   (frame-clock-time :initform -1d0 :accessor %kernel-frame-clock-time)
   (frame-clock-sampled-at :initform -1d0 :accessor %kernel-frame-clock-sampled-at))
  (:documentation
   "Stable mechanism joining one Runtime to one replaceable World on one owner thread."))

(defun %hash-values (table)
  (loop for value being the hash-values of table collect value))

(defun kernel-outputs (kernel)
  (%hash-values (%kernel-output-table kernel)))

(defun kernel-input-devices (kernel)
  (%hash-values (%kernel-input-table kernel)))

(defun kernel-seats (kernel)
  (%hash-values (%kernel-seat-table kernel)))

(defun kernel-applications (kernel)
  (%hash-values (%kernel-toplevel-table kernel)))

(defun find-kernel-object (kernel id)
  (gethash id (%kernel-object-table kernel)))

(defun %allocate-object-id (kernel)
  (incf (%kernel-next-object-id kernel)))

(defun %register-object (kernel object &key runtime-object)
  (setf (gethash (object-id object) (%kernel-object-table kernel)) object)
  (when runtime-object
    (setf (gethash runtime-object (%kernel-runtime-index kernel)) object))
  (setf (object-state object) :live)
  object)

(defun %retire-object (kernel object &key runtime-object)
  (when runtime-object
    (remhash runtime-object (%kernel-runtime-index kernel)))
  (remhash (object-id object) (%kernel-object-table kernel))
  (setf (object-state object) :retired)
  object)

(defun %find-runtime-object (kernel runtime-object)
  (gethash runtime-object (%kernel-runtime-index kernel)))

(defun make-kernel
    (world &key world-factory recovery-world-factory (world-timeout 1d0))
  (check-type world world)
  (make-instance
   'kernel
   :world world
   :world-watchdog
   (make-world-watchdog
    :world-factory world-factory
    :recovery-world-factory recovery-world-factory
    :timeout world-timeout)))

(defun attach-runtime (kernel runtime)
  (check-type kernel kernel)
  (check-type runtime ataxia.runtime:runtime)
  (when (kernel-runtime kernel)
    (error "Kernel already has a Runtime."))
  (setf (kernel-runtime kernel) runtime
        (kernel-state kernel) :ready)
  (%start-world-watchdog kernel)
  (%call-world kernel world-attached kernel)
  (unless (eq (kernel-world-status kernel) :recovery-pending)
    (setf (kernel-world-status kernel) :running))
  kernel)

(defun detach-runtime (kernel)
  (when (kernel-runtime kernel)
    (%call-world kernel world-quiescing :runtime-detaching)
    (%stop-world-watchdog kernel)
    (setf (kernel-runtime kernel) nil
          (kernel-state kernel) :detached))
  kernel)

(defun create-kernel
    (world &key world-factory recovery-world-factory (world-timeout 1d0)
                (backend :auto) (headless-width 1280)
                (headless-height 720) (socket-p t) debug-p
                (default-seat-name "seat0"))
  "Construct Runtime protocol globals, attach WORLD, and create an optional seat."
  (let* ((kernel
           (make-kernel
            world
            :world-factory world-factory
            :recovery-world-factory recovery-world-factory
            :world-timeout world-timeout))
         (runtime
           (ataxia.runtime:create-runtime
            :sink kernel
            :backend backend
            :headless-width headless-width
            :headless-height headless-height
            :socket-p socket-p
            :debug-p debug-p)))
    (handler-case
        (progn
          (attach-runtime kernel runtime)
          (ataxia.runtime:create-xdg-shell runtime)
          (ataxia.runtime:create-desktop-shell-protocols runtime)
          (ataxia.runtime:create-pointer-protocols runtime)
          (ataxia.runtime:create-data-device-manager runtime)
          (ataxia.runtime:create-presentation-protocols runtime)
          (when default-seat-name
            (setf (%kernel-default-seat kernel)
                  (create-logical-seat kernel default-seat-name)))
          kernel)
      (serious-condition (cause)
        (ignore-errors (%stop-world-watchdog kernel))
        (ignore-errors (ataxia.runtime:destroy-runtime runtime :kernel-construction))
        (error cause)))))

(defun start-kernel (kernel)
  (ataxia.runtime:start-runtime (kernel-runtime kernel))
  kernel)

(defun run-kernel (kernel &key run-for)
  (ataxia.runtime:run-runtime (kernel-runtime kernel) :run-for run-for)
  kernel)

(defun request-kernel-stop (kernel &optional (reason :requested))
  (ataxia.runtime:request-runtime-stop (kernel-runtime kernel) reason)
  kernel)

(defun %detach-world-graphics (kernel reason)
  (when (%kernel-graphics-attached-p kernel)
    (ataxia.runtime:call-with-egl-context
     (ataxia.runtime:runtime-egl (kernel-runtime kernel))
     (lambda ()
       (%call-world
        kernel world-graphics-detaching
        (ataxia.runtime:runtime-egl (kernel-runtime kernel)) reason)))
    (setf (%kernel-graphics-attached-p kernel) nil))
  kernel)

(defun destroy-kernel (kernel &optional (reason :shutdown))
  (when (and kernel (kernel-runtime kernel))
    (setf (kernel-world-status kernel) :stopping)
    (%detach-world-graphics kernel reason)
    (unless (eq (kernel-state kernel) :stopping)
      (%call-world kernel world-quiescing reason)
      (setf (kernel-state kernel) :stopping))
    (ataxia.runtime:destroy-runtime (kernel-runtime kernel) reason)
    (%stop-world-watchdog kernel)
    (setf (kernel-runtime kernel) nil))
  (setf (kernel-state kernel) :destroyed)
  nil)

(defun install-world (kernel world)
  "Replace the active World at an owner-thread safe point."
  (check-type world world)
  (let ((*world-call-failure-mode* :signal))
    (let ((old-world (kernel-world kernel)))
      (unless (eq old-world world)
        (let* ((runtime (kernel-runtime kernel))
               (graphics-p (%kernel-graphics-attached-p kernel))
               (egl (and runtime (ataxia.runtime:runtime-egl runtime))))
          (labels ((detach-graphics (target reason)
                     (when graphics-p
                       (%call-world-on
                        kernel target world-graphics-detaching egl reason)))
                   (attach-graphics (target)
                     (when graphics-p
                       (%call-world-on
                        kernel target world-graphics-attached egl)))
                   (replay (target)
                     (dolist (output (kernel-outputs kernel))
                       (%call-world-on
                        kernel target world-output-added output))
                     (dolist (seat (kernel-seats kernel))
                       (%call-world-on kernel target world-seat-added seat)
                       (when (%seat-cursor-request seat)
                         (%call-world-on
                          kernel target world-seat-cursor-request
                          seat (%seat-cursor-request seat))))
                     (dolist (application
                              (%hash-values (%kernel-toplevel-table kernel)))
                       (%call-world-on
                        kernel target world-register-object application))))
            (%call-world-on
             kernel old-world world-quiescing :world-replaced)
            (if graphics-p
                (ataxia.runtime:call-with-egl-context
                 egl (lambda () (detach-graphics old-world :world-replaced)))
                (detach-graphics old-world :world-replaced))
            (handler-case
                (progn
                  (incf (kernel-world-generation kernel))
                  (setf (kernel-world kernel) world)
                  (%call-world-on kernel world world-attached kernel)
                  (replay world)
                  (if graphics-p
                      (ataxia.runtime:call-with-egl-context
                       egl (lambda () (attach-graphics world)))
                      (attach-graphics world))
                  (let ((*allow-inactive-world-calls-p* t))
                    (%call-world-on
                     kernel old-world world-detached kernel))
                  (setf (kernel-world-status kernel) :running))
              (serious-condition (cause)
                (ignore-errors
                  (%call-world-on
                   kernel world world-quiescing :installation-failed))
                (when graphics-p
                  (ignore-errors
                    (ataxia.runtime:call-with-egl-context
                     egl
                     (lambda ()
                       (%call-world-on
                        kernel world world-graphics-detaching
                        egl :installation-failed)))))
                (ignore-errors
                  (%call-world-on kernel world world-detached kernel))
                (setf (kernel-world kernel) old-world)
                (%call-world-on kernel old-world world-attached kernel)
                (when graphics-p
                  (ataxia.runtime:call-with-egl-context
                   egl (lambda () (attach-graphics old-world))))
                (error cause))))))))
  world)

(defun restart-world (kernel)
  "Construct and install a fresh normal World after repairing its definition."
  (let ((factory (%kernel-world-factory kernel)))
    (unless factory
      (error "Kernel has no normal World factory."))
    (let ((*world-call-failure-mode* :signal))
      (install-world
       kernel
       (%guard-kernel-operation
        kernel nil :world-construction factory)))))
