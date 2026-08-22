;;;; Kernel aggregate and lifecycle.
;;;;
;;;; One Kernel owns all stable Wayland identities and the single Runtime/World
;;;; connection. Its tables are direct indexes, not independently communicating
;;;; managers.

(in-package #:ataxia.kernel)

(defclass kernel (ataxia.runtime:runtime-sink)
  ((runtime :initform nil :accessor kernel-runtime)
   (world :initarg :world :accessor kernel-world)
   (state :initform :constructing :accessor kernel-state)
   (next-object-id :initform 0 :accessor %kernel-next-object-id)
   (objects :initform (make-hash-table :test #'eql)
            :reader %kernel-object-table)
   (world-objects :initform (make-hash-table :test #'eql)
                  :reader %kernel-world-object-table)
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
   (graphics-attached-p :initform nil :accessor %kernel-graphics-attached-p))
  (:documentation
   "Stable mechanism joining one Runtime to one replaceable World on one owner thread."))

(defun %hash-values (table)
  (loop for value being the hash-values of table collect value))

(defun kernel-objects (kernel)
  (%hash-values (%kernel-world-object-table kernel)))

(defun kernel-outputs (kernel)
  (%hash-values (%kernel-output-table kernel)))

(defun kernel-input-devices (kernel)
  (%hash-values (%kernel-input-table kernel)))

(defun kernel-seats (kernel)
  (%hash-values (%kernel-seat-table kernel)))

(defun find-kernel-object (kernel id)
  (gethash id (%kernel-object-table kernel)))

(defun %allocate-object-id (kernel)
  (incf (%kernel-next-object-id kernel)))

(defun %register-object (kernel object &key runtime-object world-visible-p)
  (setf (gethash (object-id object) (%kernel-object-table kernel)) object)
  (when runtime-object
    (setf (gethash runtime-object (%kernel-runtime-index kernel)) object))
  (when world-visible-p
    (setf (gethash (object-id object) (%kernel-world-object-table kernel))
          object))
  (setf (object-state object) :live)
  object)

(defun %retire-object (kernel object &key runtime-object world-visible-p)
  (when world-visible-p
    (remhash (object-id object) (%kernel-world-object-table kernel)))
  (when runtime-object
    (remhash runtime-object (%kernel-runtime-index kernel)))
  (remhash (object-id object) (%kernel-object-table kernel))
  (setf (object-state object) :retired)
  object)

(defun %find-runtime-object (kernel runtime-object)
  (gethash runtime-object (%kernel-runtime-index kernel)))

(defun make-kernel (world)
  (check-type world world)
  (make-instance 'kernel :world world))

(defun attach-runtime (kernel runtime)
  (check-type kernel kernel)
  (check-type runtime ataxia.runtime:runtime)
  (when (kernel-runtime kernel)
    (error "Kernel already has a Runtime."))
  (setf (kernel-runtime kernel) runtime
        (kernel-state kernel) :ready)
  (world-attached (kernel-world kernel) kernel)
  kernel)

(defun detach-runtime (kernel)
  (when (kernel-runtime kernel)
    (world-quiescing (kernel-world kernel) :runtime-detaching)
    (setf (kernel-runtime kernel) nil
          (kernel-state kernel) :detached))
  kernel)

(defun create-kernel
    (world &key (backend :auto) (headless-width 1280)
                (headless-height 720) (socket-p t) debug-p
                (default-seat-name "seat0"))
  "Construct Runtime protocol globals, attach WORLD, and create an optional seat."
  (let* ((kernel (make-kernel world))
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
       (world-graphics-detaching
        (kernel-world kernel)
        (ataxia.runtime:runtime-egl (kernel-runtime kernel))
        reason)))
    (setf (%kernel-graphics-attached-p kernel) nil))
  kernel)

(defun destroy-kernel (kernel &optional (reason :shutdown))
  (when (and kernel (kernel-runtime kernel))
    (%detach-world-graphics kernel reason)
    (unless (eq (kernel-state kernel) :stopping)
      (world-quiescing (kernel-world kernel) reason)
      (setf (kernel-state kernel) :stopping))
    (ataxia.runtime:destroy-runtime (kernel-runtime kernel) reason)
    (setf (kernel-runtime kernel) nil))
  (setf (kernel-state kernel) :destroyed)
  nil)

(defun install-world (kernel world)
  "Replace the active World and replay only live Kernel-owned public objects."
  (check-type world world)
  (let ((old-world (kernel-world kernel)))
    (unless (eq old-world world)
      (world-quiescing old-world :world-replaced)
      (setf (kernel-world kernel) world)
      (world-attached world kernel)
      (dolist (output (kernel-outputs kernel))
        (world-output-added world output))
      (dolist (seat (kernel-seats kernel))
        (world-seat-added world seat))
      (dolist (object (kernel-objects kernel))
        (world-register-object world object))))
  world)
