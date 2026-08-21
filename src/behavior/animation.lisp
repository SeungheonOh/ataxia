;;;; Behavior-owned animation selection.
;;;;
;;;; Core samples and executes tracks; policies choose per-view definitions
;;;; and may override resolution for any typed transition.

(in-package #:ataxia.compositor)

(defgeneric behavior-default-animation-definition
    (policy subject descriptor context)
  (:documentation
   "Implement BEHAVIOR-DEFAULT-ANIMATION-DEFINITION for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))

(defmethod behavior-default-animation-definition
    ((policy standard-behavior-policy) (subject view) descriptor context)
  "Implement BEHAVIOR-DEFAULT-ANIMATION-DEFINITION for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (declare (ignore context))
  (cond
    ((typep descriptor 'visibility-transition)
     (if (visibility-new-state descriptor)
         (or (make-codec-reveal-animation policy subject)
             (make-instance
              'animation-definition :name :appear :duration 0.18d0
              :tracks
              (list (make-instance 'animation-track
                                   :property 'opacity :from 0d0 :to 1d0)
                    (make-instance 'animation-track
                                   :property 'scale :from 0.96d0 :to 1d0))))
         (make-instance
          'animation-definition :name :disappear :duration 0.14d0
          :tracks
          (list (make-instance 'animation-track
                               :property 'opacity :from 1d0 :to 0d0)))))
    ((typep descriptor 'interaction-transition)
     (let* ((state (view-presentation-state subject))
            (moving-p (eq :move (interaction-new-state descriptor)))
            (target-scale
              (if (interaction-new-state descriptor) 1.018d0 1d0))
            (target-elevation (if moving-p 1d0 0d0)))
       (make-instance
        'animation-definition
        :name (cond (moving-p :lift)
                    ((interaction-new-state descriptor) :interaction-active)
                    (t :settle))
        :duration (if (interaction-new-state descriptor) 0.14d0 0.20d0)
        :tracks
        (list
         (make-instance
          'animation-track :property 'scale
          :from (presentation-scale state) :to target-scale)
         (make-instance
          'animation-track
          :property (make-instance 'effect-parameter-binding :name 'elevation)
          :from (view-effect-parameter subject 'elevation 0d0)
          :to target-elevation)))))
    (t nil)))

(defmethod behavior-resolve-animation
    ((policy behavior-policy) (engine animation-engine)
     (subject view) descriptor context)
  "Implement BEHAVIOR-RESOLVE-ANIMATION for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (or (operation-animation-override descriptor)
      (let ((view-policy (view-animation-policy subject)))
        (when view-policy
          (or (gethash (class-name (class-of descriptor))
                       (animation-policy-definitions view-policy))
              (animation-policy-fallback view-policy))))
      (behavior-default-animation-definition
       policy subject descriptor context)
      (funcall (animation-engine-default-resolver engine)
               subject descriptor context)))

(defmethod behavior-set-view-animation-definition
    ((policy behavior-policy) (view view) descriptor-class definition)
  "Implement BEHAVIOR-SET-VIEW-ANIMATION-DEFINITION for this policy specialization. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."
  (let ((view-policy
          (or (view-animation-policy view)
              (setf (view-animation-policy view)
                    (make-instance 'animation-policy)))))
    (set-animation-policy-definition
     view-policy descriptor-class definition)
    (incf (behavior-policy-revision policy))
    definition))
