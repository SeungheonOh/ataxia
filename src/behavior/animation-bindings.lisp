;;;; Behavior-owned animation configuration values.
;;;;
;;;; These objects name presentation mutations understood by behavior. The
;;;; core animation engine treats every binding and conflict key as opaque.

(in-package #:ataxia.compositor)

(defclass animation-policy ()
  ((definitions :initform (make-hash-table :test #'eq)
                :reader animation-policy-definitions)
   (fallback :initarg :fallback :initform nil
             :accessor animation-policy-fallback)))

(defclass shader-uniform-binding ()
  ((name :initarg :name :reader shader-uniform-binding-name)))

(defun set-animation-policy-definition (policy descriptor-class definition)
  (check-type policy animation-policy)
  (check-type definition animation-definition)
  (setf (gethash descriptor-class (animation-policy-definitions policy))
        definition)
  policy)
