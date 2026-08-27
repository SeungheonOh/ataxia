;;;; Minimal recovery World.
;;;;
;;;; This World deliberately owns no application policy or persistent graphics
;;;; resources. It paints a diagnostic solid frame while Kernel keeps every
;;;; Wayland connection and stable protocol object alive for a later restart.

(in-package #:ataxia.world)

(defclass rescue-world (ataxia.kernel:world)
  ((kernel :initform nil :accessor %rescue-kernel)
   (outputs :initform nil :accessor %rescue-outputs)))

(defun make-rescue-world ()
  (make-instance 'rescue-world))

(defmethod ataxia.kernel:world-attached ((world rescue-world) kernel)
  (setf (%rescue-kernel world) kernel)
  world)

(defmethod ataxia.kernel:world-kernel ((world rescue-world))
  (%rescue-kernel world))

(defmethod ataxia.kernel:world-quiescing ((world rescue-world) reason)
  (declare (ignore reason))
  world)

(defmethod ataxia.kernel:world-detached ((world rescue-world) kernel)
  (when (eq kernel (%rescue-kernel world))
    (setf (%rescue-kernel world) nil
          (%rescue-outputs world) nil))
  world)

(defmethod ataxia.kernel:world-output-added ((world rescue-world) output)
  (pushnew output (%rescue-outputs world) :test #'eq)
  (ataxia.kernel:request-output-frame output)
  output)

(defmethod ataxia.kernel:world-output-removing ((world rescue-world) output)
  (setf (%rescue-outputs world)
        (delete output (%rescue-outputs world) :test #'eq))
  output)

(defmethod ataxia.kernel:world-output-changed
    ((world rescue-world) output change)
  (declare (ignore world change))
  (ataxia.kernel:request-output-frame output)
  output)

(defmethod ataxia.kernel:world-render ((world rescue-world) frame)
  (declare (ignore world))
  (ataxia.world.gles:gles-reset-state)
  (ataxia.world.gles:gles-clear 0.16 0.035 0.045 1.0)
  (ataxia.world.gles:gles-flush)
  (make-instance
   'ataxia.kernel:world-frame-result
   :target-token (ataxia.kernel:frame-target-token frame)
   :damage
   (vector
    (ataxia.kernel:make-frame-damage-rectangle
     0 0
     (ataxia.kernel:frame-width frame)
     (ataxia.kernel:frame-height frame)))
   :presentation-tokens #()
   :complete-p t
   :world-cookie nil))

(defmacro %define-rescue-noop (name lambda-list result)
  `(defmethod ,name ,lambda-list
     ,result))

(%define-rescue-noop ataxia.kernel:world-register-object
    ((world rescue-world) object) object)
(%define-rescue-noop ataxia.kernel:world-unregister-object
    ((world rescue-world) object reason) object)
(%define-rescue-noop ataxia.kernel:world-object-changed
    ((world rescue-world) object change) object)
(%define-rescue-noop ataxia.kernel:world-object-invalidated
    ((world rescue-world) object invalidation) object)
(%define-rescue-noop ataxia.kernel:world-output-presented
    ((world rescue-world) output presentation) nil)
(%define-rescue-noop ataxia.kernel:world-seat-added
    ((world rescue-world) seat) seat)
(%define-rescue-noop ataxia.kernel:world-seat-removing
    ((world rescue-world) seat) seat)
(%define-rescue-noop ataxia.kernel:world-cursor-motion
    ((world rescue-world) seat input) input)
(%define-rescue-noop ataxia.kernel:world-cursor-button
    ((world rescue-world) seat input) input)
(%define-rescue-noop ataxia.kernel:world-cursor-axis
    ((world rescue-world) seat input) input)
(%define-rescue-noop ataxia.kernel:world-key-event
    ((world rescue-world) seat input) input)
(%define-rescue-noop ataxia.kernel:world-seat-cursor-request
    ((world rescue-world) seat request) request)
(%define-rescue-noop ataxia.kernel:world-client-request
    ((world rescue-world) object request) object)
(%define-rescue-noop ataxia.kernel:world-graphics-attached
    ((world rescue-world) graphics-context) world)
(%define-rescue-noop ataxia.kernel:world-frame-committed
    ((world rescue-world) output result commit-info) nil)
(%define-rescue-noop ataxia.kernel:world-frame-failed
    ((world rescue-world) output result reason) nil)
(%define-rescue-noop ataxia.kernel:world-graphics-detaching
    ((world rescue-world) graphics-context reason) world)
