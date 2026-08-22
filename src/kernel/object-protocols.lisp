;;;; Shared object protocols.
;;;;
;;;; World renders and interacts with objects through these contracts. Kernel
;;;; specializes them for Wayland objects; native objects specialize them
;;;; entirely inside their owning World.

(in-package #:ataxia.kernel)

(defclass drawable () ()
  (:documentation "Object whose immutable local render records can be queried by World."))

(defclass interactable () ()
  (:documentation "Object that accepts input already resolved to object-local coordinates."))

(defclass render-source () ()
  (:documentation "Opaque sampling or geometry resource referenced by a drawable surface."))

(defgeneric render-source-width (render-source))
(defgeneric render-source-height (render-source))
(defgeneric render-source-gles-target (render-source))
(defgeneric render-source-gles-name (render-source))
(defgeneric render-source-has-alpha-p (render-source))
(defgeneric render-source-generation (render-source))

(defclass drawable-surface ()
  ((id :initarg :id :reader drawable-surface-id)
   (local-x :initarg :local-x :reader drawable-surface-local-x)
   (local-y :initarg :local-y :reader drawable-surface-local-y)
   (width :initarg :width :reader drawable-surface-width)
   (height :initarg :height :reader drawable-surface-height)
   (order :initarg :order :reader drawable-surface-order)
   (source-box :initarg :source-box :reader drawable-surface-source-box)
   (buffer-transform
    :initarg :buffer-transform
    :reader drawable-surface-buffer-transform)
   (render-source :initarg :render-source :reader drawable-surface-render-source)
   (protocol-token
    :initarg :protocol-token
    :initform nil
    :reader drawable-surface-protocol-token)
   (damage :initarg :damage :reader drawable-surface-damage)
   (generation :initarg :generation :reader drawable-surface-generation))
  (:documentation
   "Immutable object-local render record. Only protocol-token may identify a Kernel resource."))

(defgeneric drawable-surfaces (drawable)
  (:documentation
   "Return an immutable vector of DRAWABLE-SURFACE records and its revision."))

(defgeneric drawable-local-bounds (drawable)
  (:documentation "Return object-local X, Y, width, and height as four values."))

(defgeneric retain-render-source (render-source)
  (:documentation "Retain a render source beyond the drawable query that returned it."))

(defgeneric release-render-source (render-source)
  (:documentation "Release one retention acquired by RETAIN-RENDER-SOURCE."))

(defstruct (interaction-result
             (:constructor make-interaction-result
                 (&key status object focus-changed-p capture-changed-p)))
  (status :miss :type keyword :read-only t)
  (object nil :read-only t)
  (focus-changed-p nil :type boolean :read-only t)
  (capture-changed-p nil :type boolean :read-only t))

(defgeneric interactable-pointer-motion
    (object world seat local-x local-y input)
  (:documentation "Deliver resolved pointer motion synchronously."))

(defgeneric interactable-pointer-button
    (object world seat local-x local-y input)
  (:documentation "Deliver a resolved pointer button event synchronously."))

(defgeneric interactable-pointer-axis
    (object world seat local-x local-y input)
  (:documentation "Deliver a resolved pointer axis event synchronously."))

(defgeneric interactable-key-event (object world seat input)
  (:documentation "Deliver a keyboard event to the target selected by World."))

(defgeneric interactable-focus (object world seat focus-kind)
  (:documentation "Apply or clear the protocol focus selected by World."))

(defgeneric request-object-configuration (object world configuration)
  (:documentation "Translate a World configuration decision for OBJECT into its native protocol."))

(defgeneric request-object-state (object world state value)
  (:documentation "Translate a World state decision for OBJECT into its native protocol."))
