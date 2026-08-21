;;;; Per-subject animation engine.
;;;;
;;;; Definitions bind typed transition descriptors to presentation properties.
;;;; Each view can override resolution without changing the engine or renderer.

(in-package #:ataxia.compositor)

(defclass animation-policy ()
  ((definitions :initform (make-hash-table :test #'eq)
                :reader animation-policy-definitions)
   (fallback :initarg :fallback :initform nil
             :accessor animation-policy-fallback))
  (:documentation
   "Defines the replaceable animation policy. It owns policy-specific state and must satisfy compositor generics without mutating Runtime objects directly."))

(defclass animation-track ()
  ((property :initarg :property :reader animation-track-property)
   (from :initarg :from :reader animation-track-from)
   (to :initarg :to :reader animation-track-to)
   (interpolator :initarg :interpolator :initform #'ease-out-cubic
                 :reader animation-track-interpolator))
  (:documentation
   "Represents compositor animation track. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defclass shader-uniform-binding ()
  ((name :initarg :name :reader shader-uniform-binding-name))
  (:documentation
   "Binds shader uniform binding to a concrete target. Samples must update only the declared property and preserve unrelated presentation state."))

(defclass animation-definition ()
  ((duration :initarg :duration :reader animation-definition-duration)
   (tracks :initarg :tracks :reader animation-definition-tracks)
   (name :initarg :name :initform nil :reader animation-definition-name))
  (:documentation
   "Represents compositor animation definition. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defclass animation-instance ()
  ((subject :initarg :subject :reader animation-instance-subject)
   (descriptor :initarg :descriptor :reader animation-instance-descriptor)
   (definition :initarg :definition :reader animation-instance-definition)
   (context :initarg :context :reader animation-instance-context)
   (started-at :initarg :started-at :reader animation-instance-started-at)
   (state :initform :running :accessor animation-instance-state)
   (resources-finalized-p :initform nil
                          :accessor animation-resources-finalized-p))
  (:documentation
   "Represents compositor animation instance. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defclass animation-engine (compositor-component)
  ((active :initform nil :accessor animation-engine-active)
   (default-resolver :initarg :default-resolver
                     :initform #'default-animation-definition
                     :reader animation-engine-default-resolver))
  (:documentation
   "Owns animation engine subsystem state. Attach and detach it on the owner thread, and keep its tables synchronized with object lifecycle events."))

(defgeneric resolve-animation (engine subject descriptor context)
  (:documentation
   "Implement RESOLVE-ANIMATION for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric apply-animation-sample (subject property value context)
  (:documentation
   "Implement APPLY-ANIMATION-SAMPLE for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric finalize-animation-property (property subject instance reason)
  (:documentation
   "Implement FINALIZE-ANIMATION-PROPERTY for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric prepare-animation-property-for-policy
    (property policy instance)
  (:documentation
   "Implement PREPARE-ANIMATION-PROPERTY-FOR-POLICY for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))

(defmethod finalize-animation-property
    (property subject instance reason)
  "Implement FINALIZE-ANIMATION-PROPERTY for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (declare (ignore property subject instance reason))
  nil)

(defmethod prepare-animation-property-for-policy
    (property (policy behavior-policy) instance)
  "Implement PREPARE-ANIMATION-PROPERTY-FOR-POLICY for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (declare (ignore property policy instance))
  t)

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
  ;; Core intentionally has no visual policy. Behavior may supply defaults or
  ;; a caller may install a renderer-independent resolver on the engine.
  (declare (ignore subject descriptor context))
  nil)

(defmethod resolve-animation
    ((engine animation-engine) (subject view) descriptor context)
  "Implement RESOLVE-ANIMATION for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
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

(defmethod apply-animation-sample
    ((subject view) property value context)
  "Implement APPLY-ANIMATION-SAMPLE for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
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

(defgeneric animation-property-key (property)
  (:documentation
   "Implement ANIMATION-PROPERTY-KEY for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))

(defmethod animation-property-key (property)
  "Implement ANIMATION-PROPERTY-KEY for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  property)

(defmethod animation-property-key ((property shader-uniform-binding))
  "Implement ANIMATION-PROPERTY-KEY for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (list :shader-uniform (shader-uniform-binding-name property)))

(defun conflicting-animation-properties (definition)
  (mapcar (lambda (track)
            (animation-property-key (animation-track-property track)))
          (animation-definition-tracks definition)))

(defun finalize-animation-instance (instance reason)
  (unless (animation-resources-finalized-p instance)
    (setf (animation-resources-finalized-p instance) t)
    (dolist (track
              (animation-definition-tracks
               (animation-instance-definition instance)))
      (finalize-animation-property
       (animation-track-property track)
       (animation-instance-subject instance) instance reason)))
  instance)

(defun prepare-active-animations-for-policy (engine policy)
  (dolist (instance (animation-engine-active engine))
    (dolist (track
              (animation-definition-tracks
               (animation-instance-definition instance)))
      (unless (prepare-animation-property-for-policy
               (animation-track-property track) policy instance)
        (error 'invalid-compositor-state
               :operation :replace-behavior-policy
               :state :animation-resource-rejected))))
  policy)

(defun cancel-animation-instance (engine instance timestamp)
  (when (eq (animation-instance-state instance) :running)
    (setf (animation-instance-state instance) :cancelled)
    (finalize-animation-instance instance :cancelled)
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
      (finalize-animation-instance instance :completed)
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
  "Prepare or validate DETACH-COMPONENT before primary dispatch. Do not consume ownership or perform the primary operation early."
  (declare (ignore reason))
  (let ((timestamp (monotonic-seconds)))
    (dolist (instance (animation-engine-active engine))
      (cancel-animation-instance engine instance timestamp)))
  (setf (animation-engine-active engine) nil))
