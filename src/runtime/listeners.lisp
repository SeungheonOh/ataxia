;;;; Native signal subscriptions and callback containment.
;;;;
;;;; One C listener cell maps to one exact Lisp dispatcher. Callback conditions
;;;; are contained before returning to C and adoption occurs on the owner thread.

(in-package #:ataxia.runtime)

(defclass signal-subscription ()
  ((cookie :initarg :cookie :reader %subscription-cookie)
   (runtime :initarg :runtime :reader %subscription-runtime)
   (signal-name :initarg :signal-name :reader %subscription-signal-name)
   (dispatcher :initarg :dispatcher :reader %subscription-dispatcher)
   (cell :initform (ataxia.runtime.raw:null-pointer)
         :accessor %subscription-cell)
   (destroy-cell :initarg :destroy-cell
                 :initform #'ataxia.runtime.raw:%glue-listener-destroy
                 :reader %subscription-destroy-cell)
   (active-p :initform t :accessor %subscription-active-p)))

(defvar *subscription-registry* (make-hash-table :test #'eql))
(defvar *next-subscription-cookie* 0)

(defun %next-subscription-cookie ()
  (loop
    for candidate = (incf *next-subscription-cookie*)
    unless (or (zerop candidate)
               (gethash candidate *subscription-registry*))
      return candidate))

(defun %dispatch-native-listener (cookie data)
  (let ((subscription (gethash cookie *subscription-registry*)))
    (when (and subscription (%subscription-active-p subscription))
      (let ((runtime (%subscription-runtime subscription))
            (signal-name (%subscription-signal-name subscription)))
        (%runtime-callback-enter runtime signal-name)
        (unwind-protect
             (handler-case
                 (funcall (%subscription-dispatcher subscription) data)
               (serious-condition (cause)
                 (%record-runtime-callback-fault runtime signal-name cause)))
          (%runtime-callback-leave runtime))))))

(cffi:defcallback listener-dispatch :void
    ((cookie :uintptr) (data :pointer))
  (handler-case
      (%dispatch-native-listener cookie data)
    (serious-condition () nil))
  (values))

(defun ataxia.runtime.raw:%listener-dispatch-pointer ()
  (cffi:callback listener-dispatch))

(defun %attach-listener (runtime signal-name dispatcher create-cell destroy-cell)
  "Contain a native listener using the same registration and retirement path."
  (let* ((cookie (%next-subscription-cookie))
         (subscription
           (make-instance 'signal-subscription
                          :cookie cookie
                          :runtime runtime
                          :signal-name signal-name
                          :destroy-cell destroy-cell
                          :dispatcher dispatcher))
         (completed-p nil))
    (setf (gethash cookie *subscription-registry*) subscription)
    (unwind-protect
         (let ((cell
                 (funcall create-cell cookie (ataxia.runtime.raw:%listener-dispatch-pointer))))
           (when (ataxia.runtime.raw:null-pointer-p cell)
             (error 'native-call-failed
                    :name :listener-create :detail signal-name))
           (setf (%subscription-cell subscription) cell)
           (%register-runtime-subscription runtime subscription)
           (setf completed-p t)
           subscription)
      (unless completed-p
        (remhash cookie *subscription-registry*)
        (unless (ataxia.runtime.raw:null-pointer-p
                 (%subscription-cell subscription))
          (funcall destroy-cell (%subscription-cell subscription))
          (setf (%subscription-cell subscription)
                (ataxia.runtime.raw:null-pointer)))))))

(defun %attach-signal (runtime signal-name signal-pointer dispatcher)
  (when (ataxia.runtime.raw:null-pointer-p signal-pointer)
    (error 'native-call-failed :name signal-name :detail "null wl_signal"))
  (%attach-listener
   runtime signal-name dispatcher
   (lambda (cookie callback)
     (let ((cell (ataxia.runtime.raw:%glue-listener-create cookie callback)))
       (unless (ataxia.runtime.raw:null-pointer-p cell)
         (unless (ataxia.runtime.raw:%glue-listener-attach cell signal-pointer)
           (ataxia.runtime.raw:%glue-listener-destroy cell)
           (error 'native-call-failed :name :listener-attach :detail signal-name)))
       cell))
   #'ataxia.runtime.raw:%glue-listener-destroy))

(defun %attach-object-signal
    (object signal-name signal-pointer dispatcher)
  (let ((subscription
          (%attach-signal (%native-runtime object) signal-name signal-pointer
                          dispatcher)))
    (push subscription (%native-listeners object))
    subscription))

(defun %destroy-subscription-cell (subscription)
  (unless (ataxia.runtime.raw:null-pointer-p (%subscription-cell subscription))
    (funcall (%subscription-destroy-cell subscription) (%subscription-cell subscription))
    (setf (%subscription-cell subscription)
          (ataxia.runtime.raw:null-pointer))))

(defun %retire-subscription (subscription &key immediate-p)
  (when (and subscription (%subscription-active-p subscription))
    (let ((runtime (%subscription-runtime subscription)))
      (setf (%subscription-active-p subscription) nil)
      (remhash (%subscription-cookie subscription) *subscription-registry*)
      (%unregister-runtime-subscription runtime subscription)
      (if (or immediate-p (not (%runtime-callback-active-p runtime)))
          (%destroy-subscription-cell subscription)
          (%defer-runtime-action
           runtime
           (lambda () (%destroy-subscription-cell subscription))))))
  subscription)

(defun %retire-object-listeners (object &key immediate-p)
  (dolist (subscription (copy-list (%native-listeners object)))
    (%retire-subscription subscription :immediate-p immediate-p))
  (setf (%native-listeners object) nil)
  object)

(defun %retire-runtime-listeners (runtime)
  (dolist (subscription (copy-list (%runtime-subscriptions runtime)))
    (%retire-subscription subscription :immediate-p t))
  runtime)
