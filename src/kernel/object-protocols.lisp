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
  ((local-x :initarg :local-x :reader drawable-surface-local-x)
   (local-y :initarg :local-y :reader drawable-surface-local-y)
   (width :initarg :width :reader drawable-surface-width)
   (height :initarg :height :reader drawable-surface-height)
   (texture-coordinates
    :initarg :texture-coordinates
    :reader drawable-surface-texture-coordinates)
   (render-source :initarg :render-source :reader drawable-surface-render-source)
   (opaque-region :initarg :opaque-region :initform nil :reader drawable-surface-opaque-region)
   (frame-callback-p :initarg :frame-callback-p :initform nil :reader drawable-surface-frame-callback-p))
  (:documentation
   "Immutable origin-neutral textured quad. Texture coordinates are normalized U/V pairs in top-left, top-right, bottom-left, bottom-right order. Opaque regions contain FRAME-DAMAGE-RECTANGLEs relative to this quad's own origin, excluding LOCAL-X/Y; NIL makes no opacity guarantee."))

(defgeneric drawable-surface-presentation-token (surface)
  (:documentation
   "Return an opaque Kernel presentation token, or NIL for a World-native surface.")
  (:method ((surface drawable-surface))
    (declare (ignore surface))
    nil))

(defgeneric drawable-surfaces (drawable)
  (:documentation
   "Return an immutable vector of DRAWABLE-SURFACE records and its revision."))

(defgeneric drawable-local-bounds (drawable)
  (:documentation "Return object-local X, Y, width, and height as four values."))

(defgeneric drawable-attach-graphics (drawable)
  (:documentation "Acquire World graphics resources while a frame graphics scope is active."))

(defgeneric drawable-detach-graphics (drawable)
  (:documentation "Release World graphics resources while a frame graphics scope is active."))

(defgeneric drawable-prepare-frame (drawable)
  (:documentation "Update frame-local content and return object-local damage plus activity."))

(defgeneric drawable-active-p (drawable)
  (:documentation "Report whether DRAWABLE currently requires animation frames."))

(defmethod drawable-attach-graphics ((drawable drawable)) drawable)
(defmethod drawable-detach-graphics ((drawable drawable)) drawable)
(defmethod drawable-prepare-frame ((drawable drawable)) (values nil nil))
(defmethod drawable-active-p ((drawable drawable)) nil)

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

(defstruct (object-change (:constructor make-object-change (kind value)))
  (kind nil :type keyword :read-only t)
  (value nil :read-only t))

(defstruct (drawable-invalidation
             (:constructor make-drawable-invalidation (revision damage)))
  (revision 0 :type (integer 0) :read-only t)
  (damage nil :type list :read-only t))

(defclass toplevel-configuration ()
  ((width :initarg :width :initform :unchanged :reader configuration-width)
   (height :initarg :height :initform :unchanged :reader configuration-height)
   (activated :initarg :activated :initform :unchanged
              :reader configuration-activated)
   (resizing :initarg :resizing :initform :unchanged
             :reader configuration-resizing)
   (tiled-edges :initarg :tiled-edges :initform :unchanged
                :reader configuration-tiled-edges)
   (bounds-width :initarg :bounds-width :initform :unchanged
                 :reader configuration-bounds-width)
   (bounds-height :initarg :bounds-height :initform :unchanged
                  :reader configuration-bounds-height))
  (:documentation
   "World-selected toplevel configuration; :UNCHANGED preserves a field.
Adapters translate supported fields into their native protocol and ignore advisory
hints with no equivalent. World uses this contract without inspecting the backend."))

(defstruct (cursor-motion-input
             (:constructor make-cursor-motion-input
                 (&key device time-msec absolute-p delta-x delta-y
                       unaccelerated-delta-x unaccelerated-delta-y x y)))
  (device nil :read-only t)
  (time-msec 0 :type (unsigned-byte 32) :read-only t)
  (absolute-p nil :type boolean :read-only t)
  (delta-x 0d0 :type double-float :read-only t)
  (delta-y 0d0 :type double-float :read-only t)
  (unaccelerated-delta-x 0d0 :type double-float :read-only t)
  (unaccelerated-delta-y 0d0 :type double-float :read-only t)
  (x 0d0 :type double-float :read-only t)
  (y 0d0 :type double-float :read-only t))

(defstruct (cursor-button-input
             (:constructor make-cursor-button-input
                 (&key device time-msec code state)))
  (device nil :read-only t)
  (time-msec 0 :type (unsigned-byte 32) :read-only t)
  (code 0 :type (unsigned-byte 32) :read-only t)
  (state :released :type keyword :read-only t))

(defstruct (cursor-axis-input
             (:constructor make-cursor-axis-input
                 (&key device time-msec source orientation
                       relative-direction delta discrete-delta)))
  (device nil :read-only t)
  (time-msec 0 :type (unsigned-byte 32) :read-only t)
  (source :wheel :type keyword :read-only t)
  (orientation :vertical :type keyword :read-only t)
  (relative-direction :identical :type keyword :read-only t)
  (delta 0d0 :type double-float :read-only t)
  (discrete-delta 0 :type (signed-byte 32) :read-only t))

(defstruct (key-input
             (:constructor make-key-input
                 (&key device time-msec keycode keysyms modifiers
                       state update-state-p)))
  (device nil :read-only t)
  (time-msec 0 :type (unsigned-byte 32) :read-only t)
  (keycode 0 :type (unsigned-byte 32) :read-only t)
  (keysyms #() :type vector :read-only t)
  (modifiers nil :type list :read-only t)
  (state :released :type keyword :read-only t)
  (update-state-p nil :type boolean :read-only t))

(defstruct (modifiers-input
             (:constructor make-modifiers-input
                 (&key device depressed latched locked group names)))
  (device nil :read-only t)
  (depressed 0 :type (unsigned-byte 32) :read-only t)
  (latched 0 :type (unsigned-byte 32) :read-only t)
  (locked 0 :type (unsigned-byte 32) :read-only t)
  (group 0 :type (unsigned-byte 32) :read-only t)
  (names nil :type list :read-only t))

(defgeneric interactable-pointer-motion
    (object world seat local-x local-y input)
  (:documentation "Deliver resolved pointer motion synchronously."))

(defgeneric interactable-hit-test (object world local-x local-y)
  (:documentation "Return true when OBJECT accepts input at its local coordinate."))

(defmethod interactable-hit-test ((object interactable) world local-x local-y)
  (declare (ignore object world local-x local-y))
  t)

(defgeneric interactable-pointer-button
    (object world seat local-x local-y input)
  (:documentation "Deliver a resolved pointer button event synchronously."))

(defgeneric interactable-pointer-axis
    (object world seat local-x local-y input)
  (:documentation "Deliver a resolved pointer axis event synchronously."))

(defgeneric interactable-pointer-leave (object world seat)
  (:documentation "Notify OBJECT that pointer focus left its local area."))

(defgeneric interactable-key-event (object world seat input)
  (:documentation "Deliver a keyboard event to the target selected by World."))

(defgeneric interactable-focus (object world seat focus-kind)
  (:documentation "Apply or clear the protocol focus selected by World."))

(defgeneric request-object-configuration (object world configuration)
  (:documentation "Translate a World configuration decision for OBJECT into its native protocol."))

(defgeneric request-object-state (object world state value)
  (:documentation "Translate a World state decision for OBJECT into its native protocol."))
