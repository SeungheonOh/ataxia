;;;; Frame boundary values.
;;;;
;;;; Kernel creates a short-lived lease after acquiring an output target and
;;;; activating EGL. World owns presentation and damage, returning only commit
;;;; metadata that Kernel can validate without understanding the scene.

(in-package #:ataxia.kernel)

(defstruct (frame-damage-rectangle
             (:constructor make-frame-damage-rectangle (x y width height)))
  (x 0 :type integer :read-only t)
  (y 0 :type integer :read-only t)
  (width 0 :type integer :read-only t)
  (height 0 :type integer :read-only t))

(defclass frame-lease ()
  ((output :initarg :output :reader frame-output)
   (target-token :initarg :target-token :reader frame-target-token)
   (framebuffer :initarg :framebuffer :reader frame-framebuffer)
   (width :initarg :width :reader frame-width)
   (height :initarg :height :reader frame-height)
   (scale :initarg :scale :reader frame-scale)
   (transform :initarg :transform :reader frame-transform)
   (timestamp :initarg :timestamp :reader frame-timestamp)
   (generation :initarg :generation :reader frame-generation)
   (valid-p :initarg :valid-p :initform t :accessor frame-lease-valid-p))
  (:documentation "Dynamically scoped access to one acquired output framebuffer."))

(defclass world-frame-result ()
  ((target-token :initarg :target-token :reader frame-result-target-token)
   (damage :initarg :damage :reader frame-result-damage)
   (presentation-tokens
    :initarg :presentation-tokens
    :initform #()
    :reader frame-result-presentation-tokens)
   (callback-tokens :initarg :callback-tokens :initform #()
                    :reader frame-result-callback-tokens)
   (complete-p :initarg :complete-p :reader frame-result-complete-p)
   (world-cookie :initarg :world-cookie :reader frame-result-world-cookie))
  (:documentation
   "World result containing final damage, opaque World state, and presented Kernel tokens. CALLBACK-TOKENS additionally release visible clients' frame callbacks after commit without claiming texture presentation."))

(defstruct (output-presentation
             (:constructor make-output-presentation
                 (&key commit-sequence presented-p seconds nanoseconds sequence
                       refresh-nanoseconds flags)))
  (commit-sequence 0 :type (unsigned-byte 32) :read-only t)
  (presented-p nil :type boolean :read-only t)
  (seconds 0 :type (signed-byte 64) :read-only t)
  (nanoseconds 0 :type (signed-byte 64) :read-only t)
  (sequence 0 :type (unsigned-byte 32) :read-only t)
  (refresh-nanoseconds 0 :type (signed-byte 32) :read-only t)
  (flags 0 :type (unsigned-byte 32) :read-only t))
