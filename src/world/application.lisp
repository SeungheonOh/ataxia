;;;; World-owned attachment point for one Wayland application.
;;;;
;;;; APPLICATION-BINDING holds only the stable Kernel application reference.
;;;; Concrete Worlds subclass it to attach placement, presentation, animation,
;;;; or policy state without modifying the Kernel-owned object.

(in-package #:ataxia.world)

(defclass application-binding ()
  ((application :initarg :application :reader binding-application))
  (:documentation
   "World-owned wrapper around one stable Kernel WAYLAND-APPLICATION. The binding belongs to exactly one World and Kernel never stores or interprets it."))

(defmethod initialize-instance :after ((binding application-binding) &key)
  (unless (typep (binding-application binding)
                 'ataxia.kernel:wayland-application)
    (error "APPLICATION-BINDING requires a Kernel WAYLAND-APPLICATION.")))
