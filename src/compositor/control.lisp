;;;; External control plane.
;;;;
;;;; Only external callers cross a queue. An eventfd wakes the Wayland event
;;;; loop, after which typed actions execute synchronously on the owner thread.

(in-package #:ataxia.compositor)

(cffi:defcfun ("eventfd" %eventfd) :int
  (initial-value :uint32) (flags :int))
(cffi:defcfun ("read" %posix-read) :long
  (file-descriptor :int) (buffer :pointer) (count :unsigned-long))
(cffi:defcfun ("write" %posix-write) :long
  (file-descriptor :int) (buffer :pointer) (count :unsigned-long))
(cffi:defcfun ("close" %posix-close) :int
  (file-descriptor :int))

(defconstant +eventfd-nonblock+ #x800)
(defconstant +eventfd-cloexec+ #x80000)

(defclass control-principal ()
  ((identity :initarg :identity :reader control-principal-identity)
   (capabilities :initarg :capabilities :initform nil
                 :reader control-principal-capabilities)))

(defclass control-action ()
  ((principal :initarg :principal :reader control-action-principal)
   (submitted-at :initform (monotonic-seconds)
                 :reader control-action-submitted-at)
   (completed-p :initform nil :accessor control-action-completed-p)
   (result :initform nil :accessor control-action-result)
   (failure :initform nil :accessor control-action-failure)
   #+sb-thread
   (completion-lock :initform (sb-thread:make-mutex :name "control action")
                    :reader control-action-completion-lock)
   #+sb-thread
   (completion-waitqueue :initform (sb-thread:make-waitqueue
                                    :name "control action")
                         :reader control-action-completion-waitqueue)))

(defclass focus-view-action (control-action)
  ((seat :initarg :seat :reader focus-action-seat)
   (view :initarg :view :reader focus-action-view)))

(defclass move-view-action (control-action)
  ((view :initarg :view :reader move-action-view)
   (x :initarg :x :reader move-action-x)
   (y :initarg :y :reader move-action-y)))

(defclass create-seat-action (control-action)
  ((name :initarg :name :reader create-seat-action-name)
   (pointer-x :initarg :pointer-x :initform 160d0
              :reader create-seat-action-pointer-x)
   (pointer-y :initarg :pointer-y :initform 100d0
              :reader create-seat-action-pointer-y)))

(defclass set-view-animation-action (control-action)
  ((view :initarg :view :reader animation-action-view)
   (descriptor-class :initarg :descriptor-class
                     :reader animation-action-descriptor-class)
   (definition :initarg :definition :reader animation-action-definition)))

(defclass install-shader-program-action (control-action)
  ((name :initarg :name :reader install-shader-action-name)
   (descriptor :initarg :descriptor :reader install-shader-action-descriptor)))

(defclass configure-view-shader-action (control-action)
  ((view :initarg :view :reader configure-shader-action-view)
   (program-name :initarg :program-name
                 :reader configure-shader-action-program-name)
   (uniforms :initarg :uniforms :initform nil
             :reader configure-shader-action-uniforms)))

(defclass control-system (compositor-component)
  ((queue :initform nil :accessor control-queue)
   (queue-limit :initarg :queue-limit :initform 1024
                :reader control-queue-limit)
   #+sb-thread
   (queue-lock :initform (sb-thread:make-mutex :name "control inbox")
               :reader control-queue-lock)
   (event-file-descriptor :initform -1
                          :accessor control-event-file-descriptor)
   (event-source :initform nil :accessor control-event-source)
   (local-principal
    :initform
    (make-instance
     'control-principal :identity :local-shell
     :capabilities '(:observe :focus :move :seat :animation :shader))
    :reader control-local-principal)))

(defgeneric required-control-capability (action))
(defgeneric execute-control-action (control action))

(defmethod required-control-capability ((action focus-view-action)) :focus)
(defmethod required-control-capability ((action move-view-action)) :move)
(defmethod required-control-capability ((action create-seat-action)) :seat)
(defmethod required-control-capability
    ((action set-view-animation-action))
  :animation)
(defmethod required-control-capability
    ((action install-shader-program-action))
  :shader)
(defmethod required-control-capability
    ((action configure-view-shader-action))
  :shader)

(defun principal-allows-action-p (principal action)
  (member (required-control-capability action)
          (control-principal-capabilities principal) :test #'eq))

(defun complete-control-action (action &key result failure)
  #+sb-thread
  (sb-thread:with-mutex ((control-action-completion-lock action))
    (setf (control-action-result action) result
          (control-action-failure action) failure
          (control-action-completed-p action) t)
    (sb-thread:condition-broadcast
     (control-action-completion-waitqueue action)))
  #-sb-thread
  (setf (control-action-result action) result
        (control-action-failure action) failure
        (control-action-completed-p action) t)
  action)

(defun wait-for-control-action (action)
  #+sb-thread
  (sb-thread:with-mutex ((control-action-completion-lock action))
    (loop until (control-action-completed-p action)
          do (sb-thread:condition-wait
              (control-action-completion-waitqueue action)
              (control-action-completion-lock action))))
  (when (control-action-failure action)
    (error (control-action-failure action)))
  (control-action-result action))

(defun execute-control-action-safely (control action)
  (handler-case
      (complete-control-action
       action :result (execute-control-action control action))
    (serious-condition (condition)
      (complete-control-action action :failure condition)))
  action)

(defun take-control-queue (control)
  #+sb-thread
  (sb-thread:with-mutex ((control-queue-lock control))
    (prog1 (control-queue control)
      (setf (control-queue control) nil)))
  #-sb-thread
  (prog1 (control-queue control)
    (setf (control-queue control) nil)))

(defun drain-control-eventfd (control)
  (cffi:with-foreign-object (counter :uint64)
    (%posix-read (control-event-file-descriptor control) counter 8))
  (dolist (action (take-control-queue control))
    (execute-control-action-safely control action))
  0)

(defmethod attach-component :after ((control control-system))
  (let ((file-descriptor
          (%eventfd 0 (logior +eventfd-nonblock+ +eventfd-cloexec+))))
    (when (minusp file-descriptor)
      (error 'control-request-rejected
             :action :initialize :reason :eventfd-failed))
    (setf (control-event-file-descriptor control) file-descriptor)
    (handler-case
        (setf (control-event-source control)
              (ataxia.runtime:add-event-loop-fd
               (compositor-runtime (component-compositor control))
               file-descriptor ataxia.runtime:+event-readable+
               (lambda (source descriptor mask)
                 (declare (ignore source descriptor mask))
                 (drain-control-eventfd control))))
      (serious-condition (condition)
        (%posix-close file-descriptor)
        (setf (control-event-file-descriptor control) -1)
        (error condition)))))

(defmethod detach-component :before ((control control-system) reason)
  (declare (ignore reason))
  (when (and (control-event-source control)
             (ataxia.runtime:native-object-live-p
              (control-event-source control)))
    (ataxia.runtime:remove-event-loop-source
     (control-event-source control)))
  (setf (control-event-source control) nil)
  (when (not (minusp (control-event-file-descriptor control)))
    (%posix-close (control-event-file-descriptor control))
    (setf (control-event-file-descriptor control) -1))
  (dolist (action (take-control-queue control))
    (complete-control-action
     action
     :failure
     (make-condition 'control-request-rejected
                     :action action :reason :compositor-stopping))))

(defun enqueue-control-action (control action)
  #+sb-thread
  (sb-thread:with-mutex ((control-queue-lock control))
    (when (>= (length (control-queue control))
              (control-queue-limit control))
      (error 'control-request-rejected
             :action action :reason :queue-full))
    (setf (control-queue control)
          (nconc (control-queue control) (list action))))
  #-sb-thread
  (setf (control-queue control)
        (nconc (control-queue control) (list action)))
  (cffi:with-foreign-object (counter :uint64)
    (setf (cffi:mem-ref counter :uint64) 1)
    (unless (= 8 (%posix-write
                  (control-event-file-descriptor control) counter 8))
      (error 'control-request-rejected
             :action action :reason :eventfd-write-failed)))
  action)

(defun submit-control-action (control action &key (wait-p t))
  (check-type control control-system)
  (check-type action control-action)
  (let ((compositor (component-compositor control)))
    #+sb-thread
    (if (eq sb-thread:*current-thread*
            (compositor-owner-thread compositor))
        (execute-control-action-safely control action)
        (enqueue-control-action control action))
    #-sb-thread
    (execute-control-action-safely control action))
  (if wait-p
      (wait-for-control-action action)
      action))

(defun validate-control-action (action)
  (unless (principal-allows-action-p
           (control-action-principal action) action)
    (error 'control-request-rejected
           :action action :reason :missing-capability))
  action)

(defmethod execute-control-action :before
    ((control control-system) (action control-action))
  (assert-compositor-owner (component-compositor control)
                           :execute-control-action)
  (validate-control-action action))

(defmethod execute-control-action
    ((control control-system) (action focus-view-action))
  (focus-view
   (compositor-interaction (component-compositor control))
   (focus-action-seat action) (focus-action-view action)))

(defmethod execute-control-action
    ((control control-system) (action move-view-action))
  (let* ((compositor (component-compositor control))
         (view (move-action-view action))
         (placement (view-placement view)))
    (unless (typep placement 'planar-placement)
      (error 'control-request-rejected
             :action action :reason :incompatible-world))
    (let ((old (copy-planar-placement placement)))
      (setf (placement-x placement) (coerce (move-action-x action) 'double-float)
            (placement-y placement) (coerce (move-action-y action) 'double-float))
      (world-update-placement
       (compositor-world compositor) view placement
       (make-instance
        'operation-context :subject view
        :operation
        (make-instance 'placement-transition :subject view
                       :old-value old :new-value placement)
        :old-state old :new-state placement :cause :agent
        :provenance
        (make-instance
         'provenance :kind :control
         :identity
         (control-principal-identity
          (control-action-principal action)))
        :phase :apply))
      (schedule-presentation (compositor-presentation compositor))
      placement)))

(defmethod execute-control-action
    ((control control-system) (action create-seat-action))
  (create-logical-seat
   (compositor-interaction (component-compositor control))
   (create-seat-action-name action)
   :pointer-x (create-seat-action-pointer-x action)
   :pointer-y (create-seat-action-pointer-y action)))

(defmethod execute-control-action
    ((control control-system) (action set-view-animation-action))
  (let* ((view (animation-action-view action))
         (policy (or (view-animation-policy view)
                     (setf (view-animation-policy view)
                           (make-instance 'animation-policy)))))
    (set-animation-policy-definition
     policy (animation-action-descriptor-class action)
     (animation-action-definition action))))

(defmethod execute-control-action
    ((control control-system) (action install-shader-program-action))
  ;; Compilation happens on the owner thread with the wlroots EGL context.
  ;; replace-shader-program activates only after the candidate links cleanly.
  (replace-shader-program
   (compositor-graphics (component-compositor control))
   (install-shader-action-name action)
   (install-shader-action-descriptor action)))

(defmethod execute-control-action
    ((control control-system) (action configure-view-shader-action))
  (let ((renderer (compositor-graphics (component-compositor control)))
        (view (configure-shader-action-view action)))
    (dolist (uniform (configure-shader-action-uniforms action))
      (set-view-shader-uniform renderer view (car uniform) (cdr uniform)))
    (set-view-shader-program
     renderer view (configure-shader-action-program-name action))))

(defun observe-compositor (control &optional principal)
  (let* ((compositor (component-compositor control))
         (effective-principal (or principal (control-local-principal control))))
    (unless (member :observe
                    (control-principal-capabilities effective-principal)
                    :test #'eq)
      (error 'control-request-rejected
             :action :observe :reason :missing-capability))
    (assert-compositor-owner compositor :observe-compositor)
    (list
     :state (compositor-state compositor)
     :socket (ataxia.runtime:runtime-socket-name (compositor-runtime compositor))
     :outputs
     (mapcar (lambda (output)
               (list :name (ataxia.runtime:output-name (output-native output))
                     :width (ataxia.runtime:output-width (output-native output))
                     :height (ataxia.runtime:output-height
                              (output-native output))))
             (compositor-outputs-list (compositor-outputs compositor)))
     :seats
     (mapcar (lambda (seat)
               (list :name (seat-name seat)
                     :pointer-x (seat-pointer-x seat)
                     :pointer-y (seat-pointer-y seat)
                     :focused-view
                     (and (seat-focused-view seat)
                          (view-id (seat-focused-view seat)))))
             (interaction-seats (compositor-interaction compositor)))
     :views
     (mapcar (lambda (view)
             (list :id (view-id view) :title (view-title view)
                     :app-id (application-app-id (view-application view))
                     :mapped-p (view-mapped-p view)
                     :shader-program (view-shader-program-name view)
                     :width (view-width view) :height (view-height view)))
             (desktop-views (compositor-desktop compositor))))))
