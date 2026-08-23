;;;; World-owned attachment point for one Wayland application.
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
   "World-owned wrapper around one stable Kernel WAYLAND-APPLICATION. The binding belongs to exactly one World and Kernel never stores or interprets it."))

(defmethod initialize-instance :after ((binding application-binding) &key)
  (unless (typep (binding-application binding)
                 'ataxia.kernel:wayland-application)
    (error "APPLICATION-BINDING requires a Kernel WAYLAND-APPLICATION.")))
