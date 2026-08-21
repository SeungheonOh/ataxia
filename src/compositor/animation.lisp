;;;; Per-subject animation engine.
;;;;
;;;; Definitions bind typed transition descriptors to presentation properties.
;;;; Each view can override resolution without changing the engine or renderer.

(in-package #:ataxia.compositor)

(defclass animation-policy ()
  ((definitions :initform (make-hash-table :test #'eq)
                :reader animation-policy-definitions)
   (fallback :initarg :fallback :initform nil
             :accessor animation-policy-fallback)))

(defclass animation-track ()
  ((property :initarg :property :reader animation-track-property)
   (from :initarg :from :reader animation-track-from)
   (to :initarg :to :reader animation-track-to)
   (interpolator :initarg :interpolator :initform #'ease-out-cubic
                 :reader animation-track-interpolator)))

(defclass shader-uniform-binding ()
  ((name :initarg :name :reader shader-uniform-binding-name)))

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
   (state :initform :running :accessor animation-instance-state)))

(defclass animation-engine (compositor-component)
  ((active :initform nil :accessor animation-engine-active)
   (default-resolver :initarg :default-resolver
                     :initform #'default-animation-definition
                     :reader animation-engine-default-resolver)))

(defgeneric resolve-animation (engine subject descriptor context))
(defgeneric apply-animation-sample (subject property value context))

(defun linear-interpolation (progress)
  progress)

(defun ease-out-cubic (progress)
  (- 1d0 (expt (- 1d0 progress) 3)))

(defun set-animation-policy-definition (policy descriptor-class definition)
  (check-type policy animation-policy)
  (check-type definition animation-definition)
  (setf (gethash descriptor-class (animation-policy-definitions policy))
        definition)
  policy)

(defun default-animation-definition (subject descriptor context)
  (declare (ignore subject context))
  (cond
    ((typep descriptor 'visibility-transition)
     (if (visibility-new-state descriptor)
         (make-instance
          'animation-definition :name :appear :duration 0.18d0
          :tracks
          (list (make-instance 'animation-track
                               :property 'opacity :from 0d0 :to 1d0)
                (make-instance 'animation-track
                               :property 'scale :from 0.96d0 :to 1d0)))
         (make-instance
          'animation-definition :name :disappear :duration 0.14d0
          :tracks
          (list (make-instance 'animation-track
                               :property 'opacity :from 1d0 :to 0d0)))))
    ((typep descriptor 'interaction-transition)
     (make-instance
      'animation-definition :name :interaction-state :duration 0.12d0
      :tracks
      (list (make-instance
             'animation-track :property 'scale
             :from (if (interaction-new-state descriptor) 1d0 1.018d0)
             :to (if (interaction-new-state descriptor) 1.018d0 1d0)))))
    (t nil)))

(defmethod resolve-animation
    ((engine animation-engine) (subject view) descriptor context)
  (behavior-resolve-animation
   (compositor-behavior-policy (component-compositor engine))
   engine subject descriptor context))

(defmethod behavior-resolve-animation
    ((policy behavior-policy) (engine animation-engine)
     (subject view) descriptor context)
  (declare (ignore policy))
  (or (operation-animation-override descriptor)
      (let ((view-policy (view-animation-policy subject)))
        (when view-policy
          (or (gethash (class-name (class-of descriptor))
                       (animation-policy-definitions view-policy))
              (animation-policy-fallback view-policy))))
      (funcall (animation-engine-default-resolver engine)
               subject descriptor context)))

(defmethod behavior-set-view-animation-definition
    ((policy behavior-policy) (view view) descriptor-class definition)
  (let ((view-policy
          (or (view-animation-policy view)
              (setf (view-animation-policy view)
                    (make-instance 'animation-policy)))))
    (set-animation-policy-definition
     view-policy descriptor-class definition)
    (incf (behavior-policy-revision policy))
    definition))

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

(defmethod apply-animation-sample
    ((subject view) property value context)
  (declare (ignore context))
  (let ((state (view-presentation-state subject)))
    (typecase property
      (shader-uniform-binding
       (setf (gethash (shader-uniform-binding-name property)
                      (presentation-shader-uniforms state))
             value))
      (symbol
       (ecase property
         (opacity (setf (presentation-opacity state) value))
         (scale (setf (presentation-scale state) value))
         (offset-x (setf (presentation-offset-x state) value))
         (offset-y (setf (presentation-offset-y state) value))))
      (t (error 'compositor-error))))
  subject)

(defun animation-property-key (property)
  (typecase property
    (shader-uniform-binding
     (list :shader-uniform (shader-uniform-binding-name property)))
    (t property)))

(defun conflicting-animation-properties (definition)
  (mapcar (lambda (track)
            (animation-property-key (animation-track-property track)))
          (animation-definition-tracks definition)))

(defun cancel-animation-instance (engine instance timestamp)
  (setf (animation-instance-state instance) :cancelled)
  (run-hook
   (animation-hooks engine) 'animation-cancelled
   (animation-hook-context
    (animation-instance-context instance) :cancelled
    :timestamp timestamp :metadata instance))
  nil)

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
      (let ((properties (conflicting-animation-properties definition)))
        (setf (animation-engine-active engine)
              (delete-if
               (lambda (instance)
                 (when (and
                        (eq effective-subject
                            (animation-instance-subject instance))
                        (intersection
                         properties
                         (conflicting-animation-properties
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

(defun sample-track (track progress)
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
      (apply-animation-sample
       (animation-instance-subject instance)
       (animation-track-property track)
       (sample-track track progress)
       instance))
    (when (= progress 1d0)
      (setf (animation-instance-state instance) :complete)
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
