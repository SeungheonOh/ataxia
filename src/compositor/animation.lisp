;;;; Per-subject animation engine.
;;;;
;;;; Definitions bind transitions to opaque behavior-owned mutations. Core owns
;;;; only timing, sampling, conflict cancellation, and animation lifecycle.

(in-package #:ataxia.compositor)

(defclass animation-track ()
  ((binding :initarg :binding :initarg :property
            :reader animation-track-binding)
   (conflict-key :initarg :conflict-key :initform nil
                 :reader animation-track-conflict-key)
   (from :initarg :from :reader animation-track-from)
   (to :initarg :to :reader animation-track-to)
   (interpolator :initarg :interpolator :initform #'ease-out-cubic
                 :reader animation-track-interpolator)
   (sampler :initarg :sampler :initform #'sample-numeric-animation-track
            :reader animation-track-sampler)))

(defclass animation-definition ()
  ((duration :initarg :duration :reader animation-definition-duration)
   (tracks :initarg :tracks :reader animation-definition-tracks)
   (name :initarg :name :initform nil :reader animation-definition-name)))

(defclass animation-instance ()
  ((subject :initarg :subject :reader animation-instance-subject)
   (descriptor :initarg :descriptor :reader animation-instance-descriptor)
   (definition :initarg :definition :reader animation-instance-definition)
   (context :initarg :context :reader animation-instance-context)
   (started-at :initarg :started-at :reader animation-instance-started-at)
   (state :initform :running :accessor animation-instance-state)
   (resources-finalized-p :initform nil
                          :accessor animation-resources-finalized-p)))

(defclass animation-engine (compositor-component)
  ((active :initform nil :accessor animation-engine-active)))

(defgeneric resolve-animation (engine subject descriptor context))

(defun linear-interpolation (progress)
  progress)

(defun ease-out-cubic (progress)
  (- 1d0 (expt (- 1d0 progress) 3)))

(defmethod resolve-animation
    ((engine animation-engine) (subject view) descriptor context)
  (behavior-resolve-animation
   (compositor-behavior-policy (component-compositor engine))
   engine subject descriptor context))
(defun animation-hook-context (context phase &key metadata timestamp)
  (make-instance
   'hook-context
   :subject (context-subject context)
   :operation (context-operation context)
   :old-state (context-old-state context)
   :new-state (context-new-state context)
   :cause (context-cause context)
   :provenance (context-provenance context)
   :timestamp (or timestamp (context-timestamp context))
   :phase phase
   :metadata metadata))

(defun animation-hooks (engine)
  (extension-hooks
   (compositor-extensions (component-compositor engine))))

(defun active-animation-policy (engine)
  (compositor-behavior-policy (component-compositor engine)))

(defun conflicting-animation-bindings (definition)
  (mapcar (lambda (track)
            (or (animation-track-conflict-key track)
                (animation-track-binding track)))
          (animation-definition-tracks definition)))

(defun finalize-animation-instance (engine instance reason)
  (unless (animation-resources-finalized-p instance)
    (setf (animation-resources-finalized-p instance) t)
    (dolist (track
              (animation-definition-tracks
               (animation-instance-definition instance)))
      (behavior-finalize-animation-binding
       (active-animation-policy engine)
       (animation-instance-subject instance)
       (animation-track-binding track) instance reason)))
  instance)

(defun prepare-active-animations-for-policy (engine policy)
  (dolist (instance (animation-engine-active engine))
    (dolist (track
              (animation-definition-tracks
               (animation-instance-definition instance)))
      (unless (behavior-prepare-animation-binding
               policy (animation-instance-subject instance)
               (animation-track-binding track) instance)
        (error 'invalid-compositor-state
               :operation :replace-behavior-policy
               :state :animation-resource-rejected))))
  policy)

(defun cancel-animation-instance (engine instance timestamp)
  (when (eq (animation-instance-state instance) :running)
    (setf (animation-instance-state instance) :cancelled)
    (finalize-animation-instance engine instance :cancelled)
    (run-hook
     (animation-hooks engine) 'animation-cancelled
     (animation-hook-context
      (animation-instance-context instance) :cancelled
      :timestamp timestamp :metadata instance)))
  nil)

(defun cancel-animations-for-subject
    (engine subject &optional (timestamp (monotonic-seconds)))
  (setf (animation-engine-active engine)
        (delete-if
         (lambda (instance)
           (when (eq subject (animation-instance-subject instance))
             (cancel-animation-instance engine instance timestamp)
             t))
         (animation-engine-active engine)))
  subject)

(defun start-transition (engine subject descriptor context)
  (let* ((hooks (animation-hooks engine))
         (resolution-context
           (run-hook hooks 'animation-resolving
                     (animation-hook-context context :resolve)))
         (effective-subject (context-subject resolution-context))
         (effective-descriptor (context-operation resolution-context))
         (definition
           (resolve-animation
            engine effective-subject effective-descriptor resolution-context)))
    (unless (and (typep effective-descriptor 'operation-descriptor)
                 (eq effective-subject
                     (operation-subject effective-descriptor)))
      (error 'compositor-error))
    (when definition
      (run-hook
       hooks 'before-animation-start
       (animation-hook-context resolution-context :before
                               :metadata definition))
      (let ((bindings (conflicting-animation-bindings definition)))
        (setf (animation-engine-active engine)
              (delete-if
               (lambda (instance)
                 (when (and
                        (eq effective-subject
                            (animation-instance-subject instance))
                        (intersection
                         bindings
                         (conflicting-animation-bindings
                          (animation-instance-definition instance))
                         :test #'equal))
                   (cancel-animation-instance
                    engine instance (context-timestamp resolution-context))
                   t))
               (animation-engine-active engine))))
      (let ((instance
              (make-instance 'animation-instance
                             :subject effective-subject
                             :descriptor effective-descriptor
                             :definition definition
                             :context resolution-context
                             :started-at
                             (context-timestamp resolution-context))))
        (push instance (animation-engine-active engine))
        (run-hook
         hooks 'after-animation-start
         (animation-hook-context resolution-context :after
                                 :metadata instance))
        instance))))

(defun sample-numeric-animation-track (track progress)
  (let* ((eased (funcall (animation-track-interpolator track) progress))
         (from (animation-track-from track))
         (to (animation-track-to track)))
    (+ from (* (- to from) eased))))

(defun sample-animation-instance (engine instance timestamp)
  (let* ((definition (animation-instance-definition instance))
         (duration (animation-definition-duration definition))
         (progress
           (if (zerop duration)
               1d0
               (max 0d0
                    (min 1d0
                         (/ (- timestamp
                               (animation-instance-started-at instance))
                            duration))))))
    (dolist (track (animation-definition-tracks definition))
      (behavior-apply-animation-value
       (active-animation-policy engine)
       (animation-instance-subject instance)
       (animation-track-binding track)
       (funcall (animation-track-sampler track) track progress)
       instance))
    (when (= progress 1d0)
      (setf (animation-instance-state instance) :complete)
      (finalize-animation-instance engine instance :completed)
      (run-hook
       (animation-hooks engine) 'animation-completed
       (animation-hook-context
        (animation-instance-context instance) :complete
        :timestamp timestamp :metadata instance)))
    (< progress 1d0)))

(defun sample-animations (engine timestamp)
  (setf (animation-engine-active engine)
        (delete-if-not
         (lambda (instance)
           (sample-animation-instance engine instance timestamp))
         (animation-engine-active engine)))
  (not (null (animation-engine-active engine))))

(defun active-animations-p (engine)
  (not (null (animation-engine-active engine))))

(defmethod detach-component :before ((engine animation-engine) reason)
  (declare (ignore reason))
  (let ((timestamp (monotonic-seconds)))
    (dolist (instance (animation-engine-active engine))
      (cancel-animation-instance engine instance timestamp)))
  (setf (animation-engine-active engine) nil))
