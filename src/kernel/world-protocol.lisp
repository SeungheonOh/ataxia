;;;; World protocol.
;;;;
;;;; Kernel invokes these typed endpoints synchronously on the Runtime owner
;;;; thread. The protocol carries stable Lisp objects and copied event values,
;;;; never callback-scoped foreign pointers or presentation structures.

(in-package #:ataxia.kernel)

(defclass world () ()
  (:documentation "Base class for one complete, replaceable compositor policy and renderer."))

(defgeneric world-attached (world kernel)
  (:documentation "Attach WORLD to KERNEL at an owner-thread safe point."))

(defgeneric world-kernel (world)
  (:documentation "Return the Kernel currently attached to WORLD."))

(defgeneric world-quiescing (world reason)
  (:documentation "Stop accepting new policy operations before detachment."))

(defgeneric world-detached (world kernel)
  (:documentation "Release WORLD's final reference to KERNEL after graphics detachment."))

(defgeneric world-register-object (world object)
  (:documentation "Register a coherent Kernel-created Wayland object with WORLD."))

(defgeneric world-unregister-object (world object reason)
  (:documentation "Remove a Wayland object while its stable metadata remains readable."))

(defgeneric world-object-changed (world object change)
  (:documentation "Report non-content protocol metadata changed on OBJECT."))

(defgeneric world-object-invalidated (world object invalidation)
  (:documentation "Report new drawable content or object-local damage."))

(defgeneric world-output-added (world output)
  (:documentation "Add a configured output to WORLD."))

(defgeneric world-output-changed (world output change)
  (:documentation "Report output metadata or configuration changed."))

(defgeneric world-output-removing (world output)
  (:documentation "Remove OUTPUT before Kernel invalidates its Runtime object."))

(defgeneric world-output-presented (world output presentation)
  (:documentation "Report copied presentation feedback for OUTPUT."))

(defmethod world-output-presented ((world world) output presentation)
  (declare (ignore output presentation))
  nil)

(defgeneric world-seat-added (world seat)
  (:documentation "Add a logical Wayland seat to WORLD."))

(defgeneric world-seat-removing (world seat)
  (:documentation "Remove SEAT before its Runtime seat is destroyed."))

(defgeneric world-cursor-motion (world seat input)
  (:documentation "Let WORLD interpret copied relative or absolute pointer motion."))

(defgeneric world-cursor-button (world seat input)
  (:documentation "Let WORLD interpret a copied pointer button event."))

(defgeneric world-cursor-axis (world seat input)
  (:documentation "Let WORLD interpret a copied pointer axis event."))

(defgeneric world-key-event (world seat input)
  (:documentation "Let WORLD interpret a copied keyboard event."))

(defgeneric world-seat-cursor-request (world seat request)
  (:documentation "Report a validated client cursor-surface request using stable Kernel objects."))

(defgeneric world-client-request (world object request)
  (:documentation "Let WORLD decide a typed client policy request."))

(defgeneric world-graphics-attached (world graphics-context)
  (:documentation "Create World-owned GLES resources while Kernel has made EGL current."))

(defgeneric world-render (world frame-lease)
  (:documentation "Render one output and return a WORLD-FRAME-RESULT during FRAME-LEASE."))

(defgeneric world-frame-committed (world output frame-result commit-info)
  (:documentation "Advance World-owned presentation and damage state after commit."))

(defgeneric world-frame-failed (world output frame-result-or-nil reason)
  (:documentation "Preserve or discard staged World state after a failed frame."))

(defgeneric world-graphics-detaching (world graphics-context reason)
  (:documentation "Release World-owned GLES resources while EGL remains current."))
