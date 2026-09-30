;;;; World-owned attachment point for one drawable/interactable application.
;;;;
;;;; APPLICATION-BINDING holds only the stable Kernel application reference.
;;;; Concrete Worlds subclass it to attach placement, presentation, animation,
;;;; or policy state without modifying the Kernel-owned object.

(in-package #:ataxia.world)

(defgeneric damage-debug-mode-p (world)
  (:documentation "Whether a World replaces undamaged buffer pixels with its diagnostic color."))

(defgeneric (setf damage-debug-mode-p) (enabled world))

(defgeneric refresh-world (world)
  (:documentation "Damage all outputs and request presentation after World policy changes."))

(defmethod refresh-world ((world ataxia.kernel:world))
  (let ((kernel (ataxia.kernel:world-kernel world)))
    (when kernel
      (dolist (output (ataxia.kernel:kernel-outputs kernel))
        (ataxia.kernel:request-output-frame output))))
  world)

(define-condition world-operation-rejected (error)
  ((cause :initarg :cause :reader world-operation-rejected-cause))
  (:report
   (lambda (condition stream)
     (format stream "World operation was rejected before installation: ~A"
             (world-operation-rejected-cause condition)))))

(defun set-damage-debug-mode (world enabled)
  "Toggle damage visualization and force one complete frame to establish its baseline."
  (setf (damage-debug-mode-p world) (not (null enabled)))
  (refresh-world world)
  world)

(defun interaction-delivered-p (result)
  "Validate an interaction result and report whether an object accepted the event."
  (unless (typep result 'ataxia.kernel:interaction-result)
    (error "Interactable returned ~S instead of INTERACTION-RESULT." result))
  (not (eq (ataxia.kernel:interaction-result-status result) :miss)))

(defclass application-binding ()
  ((application :initarg :application :reader binding-application))
  (:documentation
   "World-owned placement around an application implementing drawable and interactable. The binding belongs to exactly one World and Kernel never stores or interprets it."))

(defmethod initialize-instance :after ((binding application-binding) &key)
  (unless (typep (binding-application binding)
                 '(and ataxia.kernel:drawable ataxia.kernel:interactable))
    (error "APPLICATION-BINDING requires a drawable/interactable application.")))
