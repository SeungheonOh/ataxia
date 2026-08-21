;;;; Extensible libwayland event-loop sources.
;;;;
;;;; This module exposes exact FD, timer, POSIX signal, and idle registrations.
;;;; Lisp callbacks run on the Runtime owner thread inside the same callback
;;;; barrier as wlroots signals, making them suitable for control safe points.

(in-package #:ataxia.runtime.raw)

(defcfun ("wl_event_loop_add_fd" %wl-event-loop-add-fd) :pointer
  (event-loop :pointer)
  (file-descriptor :int)
  (mask :uint32)
  (callback :pointer)
  (data :pointer))
(defcfun ("wl_event_loop_add_timer" %wl-event-loop-add-timer) :pointer
  (event-loop :pointer)
  (callback :pointer)
  (data :pointer))
(defcfun ("wl_event_loop_add_signal" %wl-event-loop-add-signal) :pointer
  (event-loop :pointer)
  (signal-number :int)
  (callback :pointer)
  (data :pointer))
(defcfun ("wl_event_loop_add_idle" %wl-event-loop-add-idle) :pointer
  (event-loop :pointer)
  (callback :pointer)
  (data :pointer))
(defcfun ("wl_event_source_fd_update" %wl-event-source-fd-update) :int
  (source :pointer)
  (mask :uint32))
(defcfun ("wl_event_source_timer_update" %wl-event-source-timer-update) :int
  (source :pointer)
  (milliseconds :int))
(defcfun ("wl_event_source_remove" %wl-event-source-remove) :int
  (source :pointer))

(in-package #:ataxia.runtime)

(defconstant +event-readable+ #x01)
(defconstant +event-writable+ #x02)
(defconstant +event-hangup+ #x04)
(defconstant +event-error+ #x08)

(defclass wl-event-source (native-object)
  ((kind :initarg :kind :reader event-source-kind)
   (cookie :initarg :cookie :reader %event-source-cookie)
   (callback :initarg :callback :reader %event-source-callback)
   (dispatching-p :initform nil :accessor %event-source-dispatching-p)))

(defvar *event-source-registry* (make-hash-table :test #'eql))
(defvar *next-event-source-cookie* 0)

(defun %next-event-source-cookie ()
  (loop
    for candidate = (incf *next-event-source-cookie*)
    unless (or (zerop candidate)
               (gethash candidate *event-source-registry*))
      return candidate))

(defun %event-source-from-data (data)
  (gethash (ataxia.runtime.raw:pointer-address data)
           *event-source-registry*))

(defun %event-source-result (value)
  (cond
    ((null value) 0)
    ((typep value '(signed-byte 32)) value)
    (t (error 'native-call-failed
              :name :event-source-callback-result :detail value))))

(defun %call-event-source (source function)
  (when (and source (native-object-live-p source))
    (let ((runtime (%native-runtime source))
          (signal-name (event-source-kind source)))
      (%runtime-callback-enter runtime signal-name)
      (setf (%event-source-dispatching-p source) t)
      (unwind-protect
           (handler-case
               (%event-source-result (funcall function))
             (serious-condition (cause)
               (%record-runtime-callback-fault runtime signal-name cause)
               0))
        (setf (%event-source-dispatching-p source) nil)
        (%runtime-callback-leave runtime)))))

(cffi:defcallback event-loop-fd-dispatch :int
    ((file-descriptor :int) (mask :uint32) (data :pointer))
  (handler-case
      (let ((source (%event-source-from-data data)))
        (or (%call-event-source
             source
             (lambda ()
               (funcall (%event-source-callback source)
                        source file-descriptor mask)))
            0))
    (serious-condition () 0)))

(cffi:defcallback event-loop-timer-dispatch :int ((data :pointer))
  (handler-case
      (let ((source (%event-source-from-data data)))
        (or (%call-event-source
             source
             (lambda () (funcall (%event-source-callback source) source)))
            0))
    (serious-condition () 0)))

(cffi:defcallback event-loop-signal-dispatch :int
    ((signal-number :int) (data :pointer))
  (handler-case
      (let ((source (%event-source-from-data data)))
        (or (%call-event-source
             source
             (lambda ()
               (funcall (%event-source-callback source)
                        source signal-number)))
            0))
    (serious-condition () 0)))

(cffi:defcallback event-loop-idle-dispatch :void ((data :pointer))
  (handler-case
      (let ((source (%event-source-from-data data)))
        (when source
          (%call-event-source
           source
           (lambda () (funcall (%event-source-callback source) source)))
          (remhash (%event-source-cookie source) *event-source-registry*)
          (remhash (%event-source-cookie source)
                   (%runtime-event-source-table (%native-runtime source)))
          (%invalidate-native-object source)))
    (serious-condition () nil))
  (values))

(defun %event-loop-callback-pointer (kind)
  (ecase kind
    (:fd (cffi:callback event-loop-fd-dispatch))
    (:timer (cffi:callback event-loop-timer-dispatch))
    (:signal (cffi:callback event-loop-signal-dispatch))
    (:idle (cffi:callback event-loop-idle-dispatch))))

(defun %register-event-source (runtime kind callback native-constructor)
  (%assert-runtime-live runtime kind)
  (check-type callback function)
  (let* ((cookie (%next-event-source-cookie))
         (source
           (make-instance 'wl-event-source
                          :pointer (ataxia.runtime.raw:null-pointer)
                          :runtime runtime
                          :kind kind
                          :cookie cookie
                          :callback callback))
         (completed-p nil))
    (setf (gethash cookie *event-source-registry*) source)
    (unwind-protect
         (let ((pointer
                 (%require-pointer
                  (funcall native-constructor
                           (cffi:make-pointer cookie)
                           (%event-loop-callback-pointer kind))
                  :wl-event-loop-add-source kind)))
           (setf (%native-pointer source) pointer
                 (gethash cookie (%runtime-event-source-table runtime)) source
                 completed-p t)
           source)
      (unless completed-p
        (remhash cookie *event-source-registry*)))))

(defun add-event-loop-fd (runtime file-descriptor mask callback)
  (check-type file-descriptor (signed-byte 32))
  (check-type mask (unsigned-byte 32))
  (%register-event-source
   runtime :fd callback
   (lambda (data callback-pointer)
     (ataxia.runtime.raw:%wl-event-loop-add-fd
      (%object-pointer (%runtime-event-loop runtime))
      file-descriptor mask callback-pointer data))))

(defun add-event-loop-timer (runtime callback)
  (%register-event-source
   runtime :timer callback
   (lambda (data callback-pointer)
     (ataxia.runtime.raw:%wl-event-loop-add-timer
      (%object-pointer (%runtime-event-loop runtime)) callback-pointer data))))

(defun add-event-loop-signal (runtime signal-number callback)
  (check-type signal-number (signed-byte 32))
  (%register-event-source
   runtime :signal callback
   (lambda (data callback-pointer)
     (ataxia.runtime.raw:%wl-event-loop-add-signal
      (%object-pointer (%runtime-event-loop runtime))
      signal-number callback-pointer data))))

(defun add-event-loop-idle (runtime callback)
  (%register-event-source
   runtime :idle callback
   (lambda (data callback-pointer)
     (ataxia.runtime.raw:%wl-event-loop-add-idle
      (%object-pointer (%runtime-event-loop runtime)) callback-pointer data))))

(defun update-event-loop-fd (source mask)
  (check-type source wl-event-source)
  (check-type mask (unsigned-byte 32))
  (unless (eq (event-source-kind source) :fd)
    (error 'native-call-failed
           :name :update-event-loop-fd :detail (event-source-kind source)))
  (%assert-runtime-live (%native-runtime source) :update-event-loop-fd)
  (when (minusp
         (ataxia.runtime.raw:%wl-event-source-fd-update
          (%object-pointer source) mask))
    (error 'native-call-failed :name :wl-event-source-fd-update))
  source)

(defun update-event-loop-timer (source milliseconds)
  (check-type source wl-event-source)
  (check-type milliseconds (integer 0 #.most-positive-fixnum))
  (unless (eq (event-source-kind source) :timer)
    (error 'native-call-failed
           :name :update-event-loop-timer
           :detail (event-source-kind source)))
  (%assert-runtime-live (%native-runtime source) :update-event-loop-timer)
  (when (minusp
         (ataxia.runtime.raw:%wl-event-source-timer-update
          (%object-pointer source) milliseconds))
    (error 'native-call-failed :name :wl-event-source-timer-update))
  source)

(defun %remove-event-source-now (source)
  (when (native-object-live-p source)
    (let ((runtime (%native-runtime source))
          (cookie (%event-source-cookie source)))
      (remhash cookie *event-source-registry*)
      (remhash cookie (%runtime-event-source-table runtime))
      (when (minusp
             (ataxia.runtime.raw:%wl-event-source-remove
              (%object-pointer source)))
        (error 'native-call-failed :name :wl-event-source-remove))
      (%invalidate-native-object source)))
  nil)

(defun remove-event-loop-source (source)
  (check-type source wl-event-source)
  (when (native-object-live-p source)
    (let ((runtime (%native-runtime source)))
      (%assert-owner-thread runtime :remove-event-loop-source)
      (if (or (%runtime-callback-active-p runtime)
              (%event-source-dispatching-p source))
          (progn
            (remhash (%event-source-cookie source) *event-source-registry*)
            (%defer-runtime-action
             runtime (lambda () (%remove-event-source-now source))))
          (%remove-event-source-now source))))
  nil)

(defun %remove-runtime-event-sources (runtime)
  (dolist (source (%hash-values (%runtime-event-source-table runtime)))
    (%remove-event-source-now source))
  (clrhash (%runtime-event-source-table runtime))
  runtime)
