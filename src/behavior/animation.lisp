;;;; Behavior-owned animation selection.
;;;;
;;;; Core samples and executes tracks; policies choose per-view definitions
;;;; and may override resolution for any typed transition.

(in-package #:ataxia.compositor)

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
