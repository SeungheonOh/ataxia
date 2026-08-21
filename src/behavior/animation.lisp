;;;; Behavior-owned animation selection.
;;;;
;;;; Core samples and executes tracks; policies choose per-view definitions
;;;; and may override resolution for any typed transition.

(in-package #:ataxia.compositor)

(defun make-default-policy-animation-definition
    (policy subject descriptor context)
  (declare (ignore context))
  (cond
    ((typep descriptor 'visibility-transition)
     (if (visibility-new-state descriptor)
         (or (make-codec-reveal-animation
              policy subject (behavior-application-reveal-style policy))
             (make-instance
              'animation-definition :name :appear :duration 0.18d0
              :tracks
              (list (make-instance 'animation-track
                                   :binding 'opacity :conflict-key 'opacity
                                   :from 0d0 :to 1d0)
                    (make-instance 'animation-track
                                   :binding 'scale :conflict-key 'scale
                                   :from 0.96d0 :to 1d0))))
         (make-instance
          'animation-definition :name :disappear :duration 0.14d0
          :tracks
          (list (make-instance 'animation-track
                               :binding 'opacity :conflict-key 'opacity
                               :from 1d0 :to 0d0)))))
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
          'animation-track :binding 'scale :conflict-key 'scale
          :from (presentation-scale state) :to target-scale)
         (make-instance
          'animation-track
          :binding (make-instance 'effect-parameter-binding :name 'elevation)
          :conflict-key '(:effect-parameter elevation)
          :from (view-effect-parameter subject 'elevation 0d0)
          :to target-elevation)))))
    (t nil)))

(defun resolve-policy-animation (policy subject descriptor context)
  (or (operation-animation-override descriptor)
      (let ((view-policy (view-animation-policy subject)))
        (when view-policy
          (or (gethash (class-name (class-of descriptor))
                       (animation-policy-definitions view-policy))
              (animation-policy-fallback view-policy))))
      (make-default-policy-animation-definition
       policy subject descriptor context)))

(defun apply-policy-animation-value
    (policy subject binding value instance)
  (declare (ignore policy instance))
  (typecase binding
    (reveal-progress-binding
     (apply-reveal-progress-animation-value subject binding value))
    (shader-uniform-binding
     (setf (gethash (shader-uniform-binding-name binding)
                    (presentation-shader-uniforms
                     (view-presentation-state subject)))
           value))
    (effect-parameter-binding
     (setf (view-effect-parameter
            subject (effect-parameter-binding-name binding))
           value))
    (symbol
     (ecase binding
       (opacity
        (setf (presentation-opacity (view-presentation-state subject)) value))
       (scale
        (setf (presentation-scale (view-presentation-state subject)) value))
       (offset-x
        (setf (presentation-offset-x (view-presentation-state subject)) value))
       (offset-y
        (setf (presentation-offset-y (view-presentation-state subject)) value))))
    (t (error 'compositor-error)))
  subject)

(defun finalize-policy-animation-binding
    (policy subject binding instance reason)
  (declare (ignore policy))
  (when (typep binding 'reveal-progress-binding)
    (finalize-reveal-progress-animation subject binding instance reason)))

(defun prepare-policy-animation-binding
    (policy subject binding instance)
  (declare (ignore subject))
  (if (typep binding 'reveal-progress-binding)
      (prepare-reveal-progress-animation policy binding instance)
      t))

(defun set-policy-view-animation-definition
    (policy view descriptor-class definition)
  (let ((view-policy
          (or (view-animation-policy view)
              (setf (view-animation-policy view)
                    (make-instance 'animation-policy)))))
    (set-animation-policy-definition
     view-policy descriptor-class definition)
    (incf (behavior-policy-revision policy))
    definition))

(defmacro define-policy-animation-methods (policy-class)
  `(progn
     (defmethod behavior-resolve-animation
         ((policy ,policy-class) (engine animation-engine)
          (subject view) descriptor context)
       (declare (ignore engine))
       (resolve-policy-animation policy subject descriptor context))

     (defmethod behavior-apply-animation-value
         ((policy ,policy-class) (subject view) binding value instance)
       (apply-policy-animation-value
        policy subject binding value instance))

     (defmethod behavior-finalize-animation-binding
         ((policy ,policy-class) (subject view) binding instance reason)
       (finalize-policy-animation-binding
        policy subject binding instance reason))

     (defmethod behavior-prepare-animation-binding
         ((policy ,policy-class) (subject view) binding instance)
       (prepare-policy-animation-binding
        policy subject binding instance))

     (defmethod behavior-set-view-animation-definition
         ((policy ,policy-class) (view view) descriptor-class definition)
       (set-policy-view-animation-definition
        policy view descriptor-class definition))

     (defmethod behavior-view-unmapped :after
         ((policy ,policy-class) view)
       (declare (ignore policy))
       (clear-view-codec-reveal-if-active view))))

(define-policy-animation-methods planar-behavior-policy)
(define-policy-animation-methods spherical-behavior-policy)
