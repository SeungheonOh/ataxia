;;;; Local SLYNK access to the live compositor.
;;;;
;;;; SLY may inspect the whole Lisp image. Mutations enter the Wayland owner
;;;; thread through CALL-IN-KERNEL-THREAD so World and wlroots state never race
;;;; a SLY worker thread.

(in-package #:ataxia.sly-control)

(cffi:defcfun ("read" %posix-read) :long
  (file-descriptor :int)
  (buffer :pointer)
  (count :unsigned-long))

(cffi:defcfun ("write" %posix-write) :long
  (file-descriptor :int)
  (buffer :pointer)
  (count :unsigned-long))

(defstruct (%control-request (:constructor %make-control-request (function)))
  function
  values
  condition
  (cancelled-p nil)
  (completion (sb-thread:make-semaphore :count 0)))

(defclass sly-control ()
  ((kernel :initarg :kernel :reader %sly-control-kernel)
   (owner-thread :initarg :owner-thread :reader %sly-control-owner-thread)
   (port :initarg :port :reader sly-control-port)
   (state :initform :starting :accessor sly-control-state)
   (event-source :initform nil :accessor %sly-control-event-source)
   (read-fd :initarg :read-fd :reader %sly-control-read-fd)
   (write-fd :initarg :write-fd :reader %sly-control-write-fd)
   (queue :initform nil :accessor %sly-control-queue)
   (wakeup-pending-p :initform nil :accessor %sly-control-wakeup-pending-p)
   (queue-lock
    :initform (sb-thread:make-mutex :name "Ataxia SLY control queue")
    :reader %sly-control-queue-lock)))

(defvar *sly-control* nil)

(defun current-sly-control ()
  (or *sly-control* (error "No Ataxia SLY control plane is running.")))

(defun current-kernel ()
  (let ((control (current-sly-control)))
    (unless (eq (sly-control-state control) :running)
      (error "The Ataxia SLY control plane is not accepting work."))
    (%sly-control-kernel control)))

(defun %take-control-requests (control)
  (sb-thread:with-mutex ((%sly-control-queue-lock control))
    (prog1 (nreverse (%sly-control-queue control))
      (setf (%sly-control-queue control) nil
            (%sly-control-wakeup-pending-p control) nil))))

(defun %complete-control-request (request)
  (unless (%control-request-cancelled-p request)
    (handler-case
        (setf (%control-request-values request)
              (multiple-value-list
               (funcall (%control-request-function request))))
      (serious-condition (condition)
        (setf (%control-request-condition request) condition))))
  (sb-thread:signal-semaphore (%control-request-completion request)))

(defun %drain-control-requests (control)
  (dolist (request (%take-control-requests control))
    (%complete-control-request request))
  control)

(defun %consume-control-wakeup (control)
  (cffi:with-foreign-object (byte :uint8)
    (unless (= 1 (%posix-read (%sly-control-read-fd control) byte 1))
      (error "Failed to consume the Ataxia SLY control wakeup."))))

(defun %control-ready (control source file-descriptor mask)
  (declare (ignore source file-descriptor))
  (when (logtest ataxia.runtime:+event-readable+ mask)
    (%consume-control-wakeup control)
    (when (eq (sly-control-state control) :running)
      (%drain-control-requests control)))
  0)

(defun %signal-control (control)
  (cffi:with-foreign-object (byte :uint8)
    (setf (cffi:mem-ref byte :uint8) 1)
    (unless (= 1 (%posix-write (%sly-control-write-fd control) byte 1))
      (error "Failed to wake the Ataxia compositor owner thread."))))

(defun call-in-kernel-thread
    (function &key (control (current-sly-control)) timeout)
  "Run arbitrary Lisp on the compositor owner thread and return its values."
  (check-type function function)
  (when timeout (check-type timeout (real 0 *)))
  (unless (eq (sly-control-state control) :running)
    (error "The Ataxia SLY control plane is not accepting work."))
  (if (eq sb-thread:*current-thread* (%sly-control-owner-thread control))
      (funcall function)
      (let ((request (%make-control-request function)))
        (let ((wake-p nil))
          (sb-thread:with-mutex ((%sly-control-queue-lock control))
            (unless (eq (sly-control-state control) :running)
              (error "The Ataxia SLY control plane stopped while queuing work."))
            (push request (%sly-control-queue control))
            (unless (%sly-control-wakeup-pending-p control)
              (setf (%sly-control-wakeup-pending-p control) t
                    wake-p t)))
          (when wake-p
            (%signal-control control)))
        (unless (sb-thread:wait-on-semaphore
                 (%control-request-completion request) :timeout timeout)
          (let ((cancelled-p nil))
            (sb-thread:with-mutex ((%sly-control-queue-lock control))
              (when (member request (%sly-control-queue control) :test #'eq)
                (setf (%sly-control-queue control)
                      (delete request (%sly-control-queue control) :test #'eq)
                      (%control-request-cancelled-p request) t
                      cancelled-p t)))
            (if cancelled-p
                (error "Timed out before the compositor owner thread began the request.")
                (sb-thread:wait-on-semaphore
                 (%control-request-completion request)))))
        (when (%control-request-condition request)
          (error (%control-request-condition request)))
        (values-list (%control-request-values request)))))

(defmacro with-kernel-thread ((kernel) &body body)
  `(call-in-kernel-thread
    (lambda ()
      (let ((,kernel (current-kernel)))
        ,@body))))

(defun %reject-pending-requests (control)
  (dolist (request (%take-control-requests control))
    (setf (%control-request-condition request)
          (make-condition
           'simple-error
           :format-control "The Ataxia SLY control plane stopped."))
    (sb-thread:signal-semaphore (%control-request-completion request)))
  control)

(defun start-sly-control (kernel &key (port 4005))
  "Expose KERNEL through SLYNK on localhost and PORT."
  (check-type kernel ataxia.kernel:kernel)
  (check-type port (integer 1 65535))
  (when *sly-control*
    (error "An Ataxia SLY control plane is already running."))
  (multiple-value-bind (read-fd write-fd) (sb-posix:pipe)
    (let ((control
            (make-instance
             'sly-control
             :kernel kernel
             :owner-thread sb-thread:*current-thread*
             :port port
             :read-fd read-fd
             :write-fd write-fd)))
      (handler-case
          (progn
            (setf *sly-control* control
                  (sly-control-state control) :running
                  (%sly-control-event-source control)
                  (ataxia.runtime:add-event-loop-fd
                   (ataxia.kernel:kernel-runtime kernel)
                   read-fd ataxia.runtime:+event-readable+
                   (lambda (source file-descriptor mask)
                     (%control-ready
                      control source file-descriptor mask))))
            (slynk:create-server
             :port port :interface "localhost" :style :spawn :dont-close t)
            control)
        (serious-condition (condition)
          (when (%sly-control-event-source control)
            (ignore-errors
              (ataxia.runtime:remove-event-loop-source
               (%sly-control-event-source control))))
          (ignore-errors (sb-posix:close read-fd))
          (ignore-errors (sb-posix:close write-fd))
          (setf (sly-control-state control) :failed
                *sly-control* nil)
          (error condition))))))

(defun stop-sly-control (&optional (control *sly-control*))
  (when control
    (unless (eq sb-thread:*current-thread* (%sly-control-owner-thread control))
      (error "STOP-SLY-CONTROL must run on the compositor owner thread."))
    (when (eq (sly-control-state control) :running)
      (setf (sly-control-state control) :stopping)
      (%reject-pending-requests control)
      (when (%sly-control-event-source control)
        (ataxia.runtime:remove-event-loop-source
         (%sly-control-event-source control))
        (setf (%sly-control-event-source control) nil))
      (ignore-errors (slynk:stop-server (sly-control-port control)))
      (ignore-errors (sb-posix:close (%sly-control-read-fd control)))
      (ignore-errors (sb-posix:close (%sly-control-write-fd control)))
      (setf (sly-control-state control) :stopped))
    (when (eq control *sly-control*)
      (setf *sly-control* nil)))
  nil)
