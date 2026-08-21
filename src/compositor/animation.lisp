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

(defclass animation-definition ()
  ((duration :initarg :duration :reader animation-definition-duration)
   (tracks :initarg :tracks :reader animation-definition-tracks)
   (name :initarg :name :initform nil :reader animation-definition-name)))

(defclass animation-instance ()
  ((subject :initarg :subject :reader animation-instance-subject)
   (descriptor :initarg :descriptor :reader animation-instance-descriptor)
   (definition :initarg :definition :reader animation-instance-definition)
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
  (or (operation-animation-override descriptor)
      (let ((policy (view-animation-policy subject)))
        (when policy
          (or (gethash (class-name (class-of descriptor))
                       (animation-policy-definitions policy))
              (animation-policy-fallback policy))))
      (funcall (animation-engine-default-resolver engine)
               subject descriptor context)))

(defmethod apply-animation-sample
    ((subject view) property value context)
  (declare (ignore context))
  (let ((state (view-presentation-state subject)))
    (ecase property
      (opacity (setf (presentation-opacity state) value))
      (scale (setf (presentation-scale state) value))
      (offset-x (setf (presentation-offset-x state) value))
      (offset-y (setf (presentation-offset-y state) value))))
  subject)

(defun conflicting-animation-properties (definition)
  (mapcar #'animation-track-property
          (animation-definition-tracks definition)))

(defun start-transition (engine subject descriptor context)
  (let ((definition (resolve-animation engine subject descriptor context)))
    (when definition
      (let ((properties (conflicting-animation-properties definition)))
        (setf (animation-engine-active engine)
              (delete-if
               (lambda (instance)
                 (and (eq subject (animation-instance-subject instance))
                      (intersection
                       properties
                       (conflicting-animation-properties
                        (animation-instance-definition instance)))))
               (animation-engine-active engine))))
      (let ((instance
              (make-instance 'animation-instance
                             :subject subject :descriptor descriptor
                             :definition definition
                             :started-at (context-timestamp context))))
        (push instance (animation-engine-active engine))
        instance))))

(defun sample-track (track progress)
  (let* ((eased (funcall (animation-track-interpolator track) progress))
         (from (animation-track-from track))
         (to (animation-track-to track)))
    (+ from (* (- to from) eased))))

(defun sample-animation-instance (instance timestamp)
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
      (setf (animation-instance-state instance) :complete))
    (< progress 1d0)))

(defun sample-animations (engine timestamp)
  (setf (animation-engine-active engine)
        (delete-if-not
         (lambda (instance)
           (sample-animation-instance instance timestamp))
         (animation-engine-active engine)))
  (not (null (animation-engine-active engine))))

(defun active-animations-p (engine)
  (not (null (animation-engine-active engine))))
