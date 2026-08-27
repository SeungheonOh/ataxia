;;;; Synchronous World watchdog and recovery.
;;;;
;;;; World code still runs directly on the Runtime owner thread. A guardian
;;;; thread only times the bounded dynamic extent of a World protocol call. On
;;;; timeout it interrupts that extent, then recovery runs at a Wayland idle
;;;; safe point and replaces the revoked World without replacing the Runtime.

(in-package #:ataxia.kernel)

(defvar *world-call-active-p* nil)
(defvar *world-recovery-enabled-p* t)

(defclass world-watchdog ()
  ((world-factory :initarg :world-factory :initform nil
                  :reader %watchdog-world-factory)
   (recovery-world-factory :initarg :recovery-world-factory :initform nil
                           :reader %watchdog-recovery-world-factory)
   (status :initform :starting :accessor %watchdog-status)
   (generation :initform 0 :accessor %watchdog-generation)
   (last-fault :initform nil :accessor %watchdog-last-fault)
   (timeout :initarg :timeout :reader %watchdog-timeout)
   (lock
    :initform #+sb-thread
              (sb-thread:make-mutex :name "Ataxia World watchdog")
              #-sb-thread nil
    :reader %watchdog-lock)
   (waitqueue
    :initform #+sb-thread
              (sb-thread:make-waitqueue :name "Ataxia World watchdog")
              #-sb-thread nil
    :reader %watchdog-waitqueue)
   (thread :initform nil :accessor %watchdog-thread)
   (owner-thread :initform nil :accessor %watchdog-owner-thread)
   (stopping-p :initform nil :accessor %watchdog-stopping-p)
   (active-call :initform nil :accessor %watchdog-active-call)
   (recovery-pending :initform nil :accessor %watchdog-recovery-pending)
   (recovery-source :initform nil :accessor %watchdog-recovery-source))
  (:documentation
   "Owns World supervision, replacement factories, and recovery state for one Kernel."))

(defun make-world-watchdog
    (&key world-factory recovery-world-factory (timeout 1d0))
  (when world-factory (check-type world-factory function))
  (when recovery-world-factory (check-type recovery-world-factory function))
  (check-type timeout (real 0 *))
  (make-instance
   'world-watchdog
   :world-factory world-factory
   :recovery-world-factory recovery-world-factory
   :timeout (coerce timeout 'double-float)))

(defun %kernel-world-factory (kernel)
  (%watchdog-world-factory (%kernel-world-watchdog kernel)))

(defun %kernel-recovery-world-factory (kernel)
  (%watchdog-recovery-world-factory (%kernel-world-watchdog kernel)))

(defun kernel-world-status (kernel)
  (%watchdog-status (%kernel-world-watchdog kernel)))

(defun (setf kernel-world-status) (status kernel)
  (setf (%watchdog-status (%kernel-world-watchdog kernel)) status))

(defun kernel-world-generation (kernel)
  (%watchdog-generation (%kernel-world-watchdog kernel)))

(defun (setf kernel-world-generation) (generation kernel)
  (setf (%watchdog-generation (%kernel-world-watchdog kernel)) generation))

(defun kernel-world-last-fault (kernel)
  (%watchdog-last-fault (%kernel-world-watchdog kernel)))

(defun (setf kernel-world-last-fault) (fault kernel)
  (setf (%watchdog-last-fault (%kernel-world-watchdog kernel)) fault))

(defun kernel-world-timeout (kernel)
  (%watchdog-timeout (%kernel-world-watchdog kernel)))

(define-condition world-operation-failed (error)
  ((operation :initarg :operation :reader %world-failure-operation)
   (cause :initarg :cause :reader %world-failure-cause))
  (:report
   (lambda (condition stream)
     (format stream "World operation ~A failed: ~A"
             (%world-failure-operation condition)
             (%world-failure-cause condition)))))

(define-condition world-operation-timeout (error)
  ((operation :initarg :operation :reader %world-timeout-operation)
   (seconds :initarg :seconds :reader %world-timeout-seconds))
  (:report
   (lambda (condition stream)
     (format stream "World operation ~A exceeded ~,3F seconds."
             (%world-timeout-operation condition)
             (%world-timeout-seconds condition)))))

(defstruct (%world-call (:constructor %make-world-call))
  operation
  world
  tag
  deadline
  (interrupt-requested-p nil))

(defun %monotonic-time ()
  (/ (get-internal-real-time)
     (coerce internal-time-units-per-second 'double-float)))

(defun %notify-watchdog (kernel)
  #+sb-thread
  (let ((watchdog (%kernel-world-watchdog kernel)))
    (sb-thread:condition-notify
     (%watchdog-waitqueue watchdog) most-positive-fixnum))
  #-sb-thread
  (declare (ignore kernel)))

(defun %interrupt-world-call (kernel call)
  #+sb-thread
  (let* ((watchdog (%kernel-world-watchdog kernel))
         (owner (%watchdog-owner-thread watchdog)))
    (when owner
      (sb-thread:interrupt-thread
       owner
       (lambda ()
         (let ((active-p nil))
           (sb-thread:with-mutex ((%watchdog-lock watchdog))
             (setf active-p
                   (eq call (%watchdog-active-call watchdog))))
           (when active-p
             (throw (%world-call-tag call) :watchdog-timeout)))))))
  #-sb-thread
  (declare (ignore kernel call)))

(defun %world-watchdog-loop (kernel)
  #+sb-thread
  (let ((watchdog (%kernel-world-watchdog kernel)))
    (loop
      (let ((expired nil))
        (sb-thread:with-mutex ((%watchdog-lock watchdog))
          (loop
            (when (%watchdog-stopping-p watchdog)
              (return-from %world-watchdog-loop nil))
            (let ((call (%watchdog-active-call watchdog)))
              (cond
                ((or (null call) (%world-call-interrupt-requested-p call))
                 (sb-thread:condition-wait
                  (%watchdog-waitqueue watchdog)
                  (%watchdog-lock watchdog)))
                (t
                 (let ((remaining
                         (- (%world-call-deadline call) (%monotonic-time))))
                   (if (plusp remaining)
                       (sb-thread:condition-wait
                        (%watchdog-waitqueue watchdog)
                        (%watchdog-lock watchdog)
                        :timeout remaining)
                       (progn
                         (setf (%world-call-interrupt-requested-p call) t
                               expired call)
                         (return)))))))))
        (when expired
          (%interrupt-world-call kernel expired)))))
  #-sb-thread
  (declare (ignore kernel)))

(defun %start-world-watchdog (kernel)
  #+sb-thread
  (let ((watchdog (%kernel-world-watchdog kernel)))
    (unless (%watchdog-thread watchdog)
      (setf (%watchdog-owner-thread watchdog) sb-thread:*current-thread*
            (%watchdog-stopping-p watchdog) nil
            (%watchdog-thread watchdog)
            (sb-thread:make-thread
             (lambda () (%world-watchdog-loop kernel))
             :name "Ataxia World watchdog"))))
  kernel)

(defun %stop-world-watchdog (kernel)
  #+sb-thread
  (let* ((watchdog (%kernel-world-watchdog kernel))
         (thread (%watchdog-thread watchdog)))
    (when thread
      (sb-thread:with-mutex ((%watchdog-lock watchdog))
        (setf (%watchdog-stopping-p watchdog) t
              (%watchdog-active-call watchdog) nil)
        (%notify-watchdog kernel))
      (unless (eq thread sb-thread:*current-thread*)
        (sb-thread:join-thread thread))
      (setf (%watchdog-thread watchdog) nil
            (%watchdog-owner-thread watchdog) nil)))
  kernel)

(defun %report-world-fault (kernel operation cause)
  (setf (kernel-world-last-fault kernel) cause)
  (format *error-output* "[kernel] World ~A failed: ~A~%" operation cause)
  (finish-output *error-output*))

(defun %perform-world-recovery (kernel)
  (let ((watchdog (%kernel-world-watchdog kernel)))
    (setf (%watchdog-recovery-source watchdog) nil)
    (let ((fault (%watchdog-recovery-pending watchdog))
          (factory (%kernel-recovery-world-factory kernel)))
      (when fault
        (setf (%watchdog-recovery-pending watchdog) nil
              (kernel-world-status kernel) :recovering)
        (handler-case
            (unless factory
              (error "Kernel has no rescue World factory."))
          (serious-condition (cause)
            (setf (kernel-world-status kernel) :failed)
            (%report-world-fault kernel :recovery cause)
            (return-from %perform-world-recovery nil)))
        (let* ((old-world (kernel-world kernel))
               (runtime (kernel-runtime kernel))
               (egl (and runtime (ataxia.runtime:runtime-egl runtime)))
               (graphics-p (%kernel-graphics-attached-p kernel))
               (new-world nil))
          (let ((*world-recovery-enabled-p* nil)
                (*world-call-failure-mode* :signal)
                (*allow-inactive-world-calls-p* t))
            (when old-world
              (ignore-errors
                (%call-world-on
                 kernel old-world world-quiescing :watchdog-recovery))
              (when graphics-p
                (ignore-errors
                  (ataxia.runtime:call-with-egl-context
                   egl
                   (lambda ()
                     (%call-world-on
                      kernel old-world world-graphics-detaching
                      egl :watchdog-recovery))))))
            (handler-case
                (progn
                  (setf new-world
                        (%guard-kernel-operation
                         kernel nil :recovery-world-construction factory))
                  (check-type new-world world)
                  (incf (kernel-world-generation kernel))
                  (setf (kernel-world kernel) new-world)
                  (%call-world-on kernel new-world world-attached kernel)
                  (dolist (output (kernel-outputs kernel))
                    (%call-world-on
                     kernel new-world world-output-added output))
                  (dolist (seat (kernel-seats kernel))
                    (%call-world-on kernel new-world world-seat-added seat)
                    (when (%seat-cursor-request seat)
                     (%call-world-on
                      kernel new-world world-seat-cursor-request
                      seat (%seat-cursor-request seat))))
                  (dolist (application (kernel-applications kernel))
                    (%call-world-on
                     kernel new-world world-register-object application))
                  (when graphics-p
                    (ataxia.runtime:call-with-egl-context
                     egl
                     (lambda ()
                       (%call-world-on
                        kernel new-world world-graphics-attached egl))))
                  (when old-world
                    (ignore-errors
                      (%call-world-on
                       kernel old-world world-detached kernel)))
                  (setf (kernel-world-status kernel) :rescue)
                  (dolist (output (kernel-outputs kernel))
                    (request-output-frame output))
                  (format *error-output*
                          "[kernel] installed rescue World generation ~D.~%"
                          (kernel-world-generation kernel))
                  (finish-output *error-output*))
              (serious-condition (cause)
                (setf (kernel-world-status kernel) :failed)
                (%report-world-fault kernel :recovery cause))))))))
  nil)

(defun %schedule-world-recovery (kernel cause)
  (when (and *world-recovery-enabled-p*
             (not (member (kernel-world-status kernel)
                          '(:stopping :recovering :failed))))
    (let ((watchdog (%kernel-world-watchdog kernel)))
      (setf (%watchdog-recovery-pending watchdog) cause
            (kernel-world-status kernel) :recovery-pending)
      (unless (%watchdog-recovery-source watchdog)
        (handler-case
            (setf (%watchdog-recovery-source watchdog)
                  (ataxia.runtime:add-event-loop-idle
                   (kernel-runtime kernel)
                   (lambda (source)
                     (declare (ignore source))
                     (%perform-world-recovery kernel))))
          (serious-condition (schedule-cause)
            (setf (kernel-world-status kernel) :failed)
            (%report-world-fault kernel :recovery-scheduling schedule-cause))))))
  nil)

(defun %handle-world-call-failure (kernel operation cause)
  (%report-world-fault kernel operation cause)
  (%schedule-world-recovery kernel cause)
  (if (eq *world-call-failure-mode* :signal)
      (error 'world-operation-failed :operation operation :cause cause)
      nil))

(defun %guard-kernel-operation (kernel world operation function)
  (check-type function function)
  #+sb-thread
  (let ((watchdog (%kernel-world-watchdog kernel)))
    (cond
      ((and world
            (not *allow-inactive-world-calls-p*)
            (not (eq world (kernel-world kernel))))
       nil)
      ((and (eq (kernel-world-status kernel) :recovery-pending)
            (not *allow-inactive-world-calls-p*))
       nil)
      (*world-call-active-p* (funcall function))
      ((null (%watchdog-thread watchdog)) (funcall function))
      ((not (eq sb-thread:*current-thread*
                (%watchdog-owner-thread watchdog)))
       (error "World operation ~A did not run on the Runtime owner thread."
              operation))
      (t
       (let* ((tag (gensym "WORLD-CALL-"))
              (call
                (%make-world-call
                 :operation operation
                 :world world
                 :tag tag
                 :deadline (+ (%monotonic-time)
                              (kernel-world-timeout kernel))))
              (outcome nil))
         (unwind-protect
              (progn
                (sb-thread:with-mutex ((%watchdog-lock watchdog))
                  (setf (%watchdog-active-call watchdog) call)
                  (%notify-watchdog kernel))
                (setf outcome
                      (catch tag
                        (handler-case
                            (let ((*world-call-active-p* t))
                              (multiple-value-call
                                  (lambda (&rest values)
                                    (list :returned values))
                                (funcall function)))
                          (serious-condition (cause)
                            (list :failed cause))))))
           (sb-thread:with-mutex ((%watchdog-lock watchdog))
             (when (eq call (%watchdog-active-call watchdog))
               (setf (%watchdog-active-call watchdog) nil))
             (%notify-watchdog kernel)))
         (cond
           ((and (consp outcome) (eq (first outcome) :returned))
            (values-list (second outcome)))
           ((and (consp outcome) (eq (first outcome) :failed))
            (%handle-world-call-failure kernel operation (second outcome)))
           ((eq outcome :watchdog-timeout)
            (%handle-world-call-failure
             kernel operation
             (make-condition
              'world-operation-timeout
              :operation operation
              :seconds (kernel-world-timeout kernel))))
           (t
            (%handle-world-call-failure
             kernel operation
             (make-condition
              'simple-error
              :format-control "Invalid watchdog outcome ~S."
              :format-arguments (list outcome)))))))))
  #-sb-thread
  (funcall function))
