;;;; Typed Runtime native wrappers and exact sink protocol.
;;;;
;;;; Wrappers retain native identity and liveness. Sink generics name concrete
;;;; wlroots facts so the next layer receives no invented event envelope.

(in-package #:ataxia.runtime)

(defclass native-object ()
  ((pointer :initarg :pointer :accessor %native-pointer)
   (runtime :initarg :runtime :reader %native-runtime)
   (live-p :initform t :accessor native-object-live-p)
   (listeners :initform nil :accessor %native-listeners)))

(defclass wl-display (native-object) ())
(defclass wl-event-loop (native-object) ())
(defclass wlr-backend (native-object) ())
(defclass wlr-renderer (native-object) ())
(defclass wlr-egl (native-object) ())
(defclass wlr-allocator (native-object) ())
(defclass wlr-compositor (native-object) ())
(defclass wlr-subcompositor (native-object) ())

(defclass wlr-output (native-object)
  ((name :initform nil :accessor output-name)
   (description :initform nil :accessor output-description)
   (width :initform 0 :accessor output-width)
   (height :initform 0 :accessor output-height)
   (scale :initform 1d0 :accessor output-scale)
   (transform :initform 0 :accessor output-transform)
   (enabled-p :initform nil :accessor output-enabled-p)
   (global-p :initform nil :accessor output-global-p)
   (modes :initform nil :accessor %output-modes)))

(defclass wlr-input-device (native-object)
  ((name :initform nil :accessor input-device-name)
   (type :initform :unknown :accessor input-device-type)
   (type-code :initform #xffffffff :accessor input-device-type-code)))

(defclass wlr-pointer (wlr-input-device) ())
(defclass wlr-keyboard (wlr-input-device) ())

(defclass wlr-surface (native-object)
  ((mapped-p :initform nil :accessor surface-mapped-p)))

(defclass wlr-seat (native-object)
  ((name :initarg :name :accessor %seat-name)))

(defclass wlr-data-device-manager (native-object) ())

(defstruct (damage-rectangle
             (:constructor %make-damage-rectangle (&key x y width height))
             (:conc-name damage-rectangle-))
  (x 0 :type (signed-byte 32) :read-only t)
  (y 0 :type (signed-byte 32) :read-only t)
  (width 0 :type (signed-byte 32) :read-only t)
  (height 0 :type (signed-byte 32) :read-only t))

(defun make-damage-rectangle (x y width height)
  (%make-damage-rectangle :x x :y y :width width :height height))

(defstruct (surface-commit-event
             (:constructor %make-surface-commit-event
                 (&key sequence fields width height buffer-width buffer-height
                       mapped-p damage-rectangles))
             (:conc-name surface-commit-))
  (sequence 0 :type (unsigned-byte 32) :read-only t)
  (fields 0 :type (unsigned-byte 32) :read-only t)
  (width 0 :type integer :read-only t)
  (height 0 :type integer :read-only t)
  (buffer-width 0 :type integer :read-only t)
  (buffer-height 0 :type integer :read-only t)
  (mapped-p nil :type boolean :read-only t)
  (damage-rectangles nil :type list :read-only t))

(defstruct (pointer-motion-event
             (:constructor %make-pointer-motion-event
                 (&key pointer time-msec delta-x delta-y
                       unaccelerated-delta-x unaccelerated-delta-y))
             (:conc-name pointer-motion-))
  (pointer nil :type wlr-pointer :read-only t)
  (time-msec 0 :type (unsigned-byte 32) :read-only t)
  (delta-x 0d0 :type double-float :read-only t)
  (delta-y 0d0 :type double-float :read-only t)
  (unaccelerated-delta-x 0d0 :type double-float :read-only t)
  (unaccelerated-delta-y 0d0 :type double-float :read-only t))

(defstruct (pointer-motion-absolute-event
             (:constructor %make-pointer-motion-absolute-event
                 (&key pointer time-msec x y))
             (:conc-name pointer-motion-absolute-))
  (pointer nil :type wlr-pointer :read-only t)
  (time-msec 0 :type (unsigned-byte 32) :read-only t)
  (x 0d0 :type double-float :read-only t)
  (y 0d0 :type double-float :read-only t))

(defstruct (pointer-button-event
             (:constructor %make-pointer-button-event
                 (&key pointer time-msec code state state-code))
             (:conc-name pointer-button-))
  (pointer nil :type wlr-pointer :read-only t)
  (time-msec 0 :type (unsigned-byte 32) :read-only t)
  (code 0 :type (unsigned-byte 32) :read-only t)
  (state :released :type keyword :read-only t)
  (state-code 0 :type (unsigned-byte 32) :read-only t))

(defstruct (pointer-axis-event
             (:constructor %make-pointer-axis-event
                 (&key pointer time-msec source source-code orientation
                       orientation-code relative-direction
                       relative-direction-code delta discrete-delta))
             (:conc-name pointer-axis-))
  (pointer nil :type wlr-pointer :read-only t)
  (time-msec 0 :type (unsigned-byte 32) :read-only t)
  (source :wheel :type keyword :read-only t)
  (source-code 0 :type (unsigned-byte 32) :read-only t)
  (orientation :vertical :type keyword :read-only t)
  (orientation-code 0 :type (unsigned-byte 32) :read-only t)
  (relative-direction :identical :type keyword :read-only t)
  (relative-direction-code 0 :type (unsigned-byte 32) :read-only t)
  (delta 0d0 :type double-float :read-only t)
  (discrete-delta 0 :type (signed-byte 32) :read-only t))

(defstruct (keyboard-key-event
             (:constructor %make-keyboard-key-event
                 (&key keyboard time-msec keycode update-state-p state
                       state-code))
             (:conc-name keyboard-key-))
  (keyboard nil :type wlr-keyboard :read-only t)
  (time-msec 0 :type (unsigned-byte 32) :read-only t)
  (keycode 0 :type (unsigned-byte 32) :read-only t)
  (update-state-p nil :type boolean :read-only t)
  (state :released :type keyword :read-only t)
  (state-code 0 :type (unsigned-byte 32) :read-only t))

(defstruct (keyboard-modifiers-event
             (:constructor %make-keyboard-modifiers-event
                 (&key keyboard depressed latched locked group))
             (:conc-name keyboard-modifiers-))
  (keyboard nil :type wlr-keyboard :read-only t)
  (depressed 0 :type (unsigned-byte 32) :read-only t)
  (latched 0 :type (unsigned-byte 32) :read-only t)
  (locked 0 :type (unsigned-byte 32) :read-only t)
  (group 0 :type (unsigned-byte 32) :read-only t))

(defstruct (keyboard-repeat-event
             (:constructor %make-keyboard-repeat-event
                 (&key keyboard rate delay))
             (:conc-name keyboard-repeat-))
  (keyboard nil :type wlr-keyboard :read-only t)
  (rate 0 :type (signed-byte 32) :read-only t)
  (delay 0 :type (signed-byte 32) :read-only t))

(defstruct (seat-cursor-request
             (:constructor %make-seat-cursor-request
                 (&key seat surface serial hotspot-x hotspot-y))
             (:conc-name seat-cursor-request-))
  (seat nil :type wlr-seat :read-only t)
  (surface nil :type (or null wlr-surface) :read-only t)
  (serial 0 :type (unsigned-byte 32) :read-only t)
  (hotspot-x 0 :type (signed-byte 32) :read-only t)
  (hotspot-y 0 :type (signed-byte 32) :read-only t))

(defclass runtime-sink () ())

(defclass diagnostic-sink (runtime-sink)
  ((stream :initarg :stream :initform *error-output*
           :reader diagnostic-stream)))

(defgeneric runtime-started (sink runtime))
(defgeneric runtime-stopping (sink runtime reason))
(defgeneric backend-new-output (sink runtime output))
(defgeneric backend-new-input (sink runtime input-device))
(defgeneric backend-destroying (sink runtime backend))
(defgeneric renderer-lost (sink runtime renderer))
(defgeneric compositor-new-surface (sink runtime surface))
(defgeneric output-frame (sink output))
(defgeneric output-destroying (sink output))
(defgeneric input-device-destroying (sink input-device))
(defgeneric pointer-motion (sink event))
(defgeneric pointer-motion-absolute (sink event))
(defgeneric pointer-button (sink event))
(defgeneric pointer-axis (sink event))
(defgeneric pointer-frame (sink pointer))
(defgeneric keyboard-key (sink event))
(defgeneric keyboard-modifiers (sink event))
(defgeneric keyboard-keymap-changed (sink keyboard))
(defgeneric keyboard-repeat-info (sink event))
(defgeneric seat-destroying (sink seat))
(defgeneric seat-request-set-cursor (sink request))
(defgeneric surface-committed (sink surface event))
(defgeneric surface-mapped (sink surface))
(defgeneric surface-unmapped (sink surface))
(defgeneric surface-destroying (sink surface))

(defmethod runtime-started ((sink runtime-sink) runtime)
  (declare (ignore sink runtime)))
(defmethod runtime-stopping ((sink runtime-sink) runtime reason)
  (declare (ignore sink runtime reason)))
(defmethod backend-new-output ((sink runtime-sink) runtime output)
  (declare (ignore sink runtime output)))
(defmethod backend-new-input ((sink runtime-sink) runtime input-device)
  (declare (ignore sink runtime input-device)))
(defmethod backend-destroying ((sink runtime-sink) runtime backend)
  (declare (ignore sink runtime backend)))
(defmethod renderer-lost ((sink runtime-sink) runtime renderer)
  (declare (ignore sink runtime renderer)))
(defmethod compositor-new-surface ((sink runtime-sink) runtime surface)
  (declare (ignore sink runtime surface)))
(defmethod output-frame ((sink runtime-sink) output)
  (declare (ignore sink output)))
(defmethod output-destroying ((sink runtime-sink) output)
  (declare (ignore sink output)))
(defmethod input-device-destroying ((sink runtime-sink) input-device)
  (declare (ignore sink input-device)))
(defmethod pointer-motion ((sink runtime-sink) event)
  (declare (ignore sink event)))
(defmethod pointer-motion-absolute ((sink runtime-sink) event)
  (declare (ignore sink event)))
(defmethod pointer-button ((sink runtime-sink) event)
  (declare (ignore sink event)))
(defmethod pointer-axis ((sink runtime-sink) event)
  (declare (ignore sink event)))
(defmethod pointer-frame ((sink runtime-sink) pointer)
  (declare (ignore sink pointer)))
(defmethod keyboard-key ((sink runtime-sink) event)
  (declare (ignore sink event)))
(defmethod keyboard-modifiers ((sink runtime-sink) event)
  (declare (ignore sink event)))
(defmethod keyboard-keymap-changed ((sink runtime-sink) keyboard)
  (declare (ignore sink keyboard)))
(defmethod keyboard-repeat-info ((sink runtime-sink) event)
  (declare (ignore sink event)))
(defmethod seat-destroying ((sink runtime-sink) seat)
  (declare (ignore sink seat)))
(defmethod seat-request-set-cursor ((sink runtime-sink) request)
  (declare (ignore sink request)))
(defmethod surface-committed ((sink runtime-sink) surface event)
  (declare (ignore sink surface event)))
(defmethod surface-mapped ((sink runtime-sink) surface)
  (declare (ignore sink surface)))
(defmethod surface-unmapped ((sink runtime-sink) surface)
  (declare (ignore sink surface)))
(defmethod surface-destroying ((sink runtime-sink) surface)
  (declare (ignore sink surface)))

(defun native-object-address (object)
  (check-type object native-object)
  (if (native-object-live-p object)
      (ataxia.runtime.raw:pointer-address (%native-pointer object))
      0))

(defun %ensure-live (object)
  (unless (and (typep object 'native-object)
               (native-object-live-p object)
               (not (ataxia.runtime.raw:null-pointer-p
                     (%native-pointer object))))
    (error 'dead-native-object :object object))
  object)

(defun %invalidate-native-object (object)
  (when (and object (native-object-live-p object))
    (setf (native-object-live-p object) nil
          (%native-pointer object) (ataxia.runtime.raw:null-pointer)))
  object)

(defun %copy-native-string (pointer)
  (unless (ataxia.runtime.raw:null-pointer-p pointer)
    (ataxia.runtime.raw:foreign-string-to-lisp pointer)))

(defun %refresh-output (output)
  (%ensure-live output)
  (let ((pointer (%native-pointer output)))
    (setf (output-name output)
          (%copy-native-string (ataxia.runtime.raw:%output-name pointer))
          (output-description output)
          (%copy-native-string (ataxia.runtime.raw:%output-description pointer))
          (output-width output) (ataxia.runtime.raw:%output-width pointer)
          (output-height output) (ataxia.runtime.raw:%output-height pointer)
          (output-scale output)
          (coerce (ataxia.runtime.raw:%output-scale pointer) 'double-float)
          (output-transform output)
          (ataxia.runtime.raw:%output-transform pointer)
          (output-enabled-p output)
          (ataxia.runtime.raw:%output-enabled pointer)))
  output)

(defun %input-type-keyword (type-code)
  (case type-code
    (0 :keyboard)
    (1 :pointer)
    (2 :touch)
    (3 :tablet)
    (4 :tablet-pad)
    (5 :switch)
    (otherwise :unknown)))

(defun %refresh-input-device (input-device)
  (%ensure-live input-device)
  (let* ((pointer (%native-pointer input-device))
         (type-code (ataxia.runtime.raw:%input-device-type pointer)))
    (setf (input-device-name input-device)
          (%copy-native-string
           (ataxia.runtime.raw:%input-device-name pointer))
          (input-device-type-code input-device) type-code
          (input-device-type input-device) (%input-type-keyword type-code)))
  input-device)

(defun %button-state-keyword (state-code)
  (case state-code
    (0 :released)
    (1 :pressed)
    (otherwise :unknown)))

(defun %axis-source-keyword (source-code)
  (case source-code
    (0 :wheel)
    (1 :finger)
    (2 :continuous)
    (3 :wheel-tilt)
    (otherwise :unknown)))

(defun %axis-orientation-keyword (orientation-code)
  (case orientation-code
    (0 :vertical)
    (1 :horizontal)
    (otherwise :unknown)))

(defun %axis-relative-direction-keyword (direction-code)
  (case direction-code
    (0 :identical)
    (1 :inverted)
    (otherwise :unknown)))

(defun %pointer-motion-snapshot (pointer event-pointer)
  (%make-pointer-motion-event
   :pointer pointer
   :time-msec (ataxia.runtime.raw:%pointer-motion-time-msec event-pointer)
   :delta-x (ataxia.runtime.raw:%pointer-motion-delta-x event-pointer)
   :delta-y (ataxia.runtime.raw:%pointer-motion-delta-y event-pointer)
   :unaccelerated-delta-x
   (ataxia.runtime.raw:%pointer-motion-unaccel-dx event-pointer)
   :unaccelerated-delta-y
   (ataxia.runtime.raw:%pointer-motion-unaccel-dy event-pointer)))

(defun %pointer-motion-absolute-snapshot (pointer event-pointer)
  (%make-pointer-motion-absolute-event
   :pointer pointer
   :time-msec
   (ataxia.runtime.raw:%pointer-motion-absolute-time-msec event-pointer)
   :x (ataxia.runtime.raw:%pointer-motion-absolute-x event-pointer)
   :y (ataxia.runtime.raw:%pointer-motion-absolute-y event-pointer)))

(defun %pointer-button-snapshot (pointer event-pointer)
  (let ((state-code
          (ataxia.runtime.raw:%pointer-button-state event-pointer)))
    (%make-pointer-button-event
     :pointer pointer
     :time-msec (ataxia.runtime.raw:%pointer-button-time-msec event-pointer)
     :code (ataxia.runtime.raw:%pointer-button-button event-pointer)
     :state (%button-state-keyword state-code)
     :state-code state-code)))

(defun %pointer-axis-snapshot (pointer event-pointer)
  (let ((source-code (ataxia.runtime.raw:%pointer-axis-source event-pointer))
        (orientation-code
          (ataxia.runtime.raw:%pointer-axis-orientation event-pointer))
        (relative-direction-code
          (ataxia.runtime.raw:%pointer-axis-relative-direction event-pointer)))
    (%make-pointer-axis-event
     :pointer pointer
     :time-msec (ataxia.runtime.raw:%pointer-axis-time-msec event-pointer)
     :source (%axis-source-keyword source-code)
     :source-code source-code
     :orientation (%axis-orientation-keyword orientation-code)
     :orientation-code orientation-code
     :relative-direction
     (%axis-relative-direction-keyword relative-direction-code)
     :relative-direction-code relative-direction-code
     :delta (ataxia.runtime.raw:%pointer-axis-delta event-pointer)
     :discrete-delta
     (ataxia.runtime.raw:%pointer-axis-delta-discrete event-pointer))))

(defun %keyboard-key-snapshot (keyboard event-pointer)
  (let ((state-code (ataxia.runtime.raw:%keyboard-key-state event-pointer)))
    (%make-keyboard-key-event
     :keyboard keyboard
     :time-msec (ataxia.runtime.raw:%keyboard-key-time-msec event-pointer)
     :keycode (ataxia.runtime.raw:%keyboard-key-keycode event-pointer)
     :update-state-p
     (ataxia.runtime.raw:%keyboard-key-update-state event-pointer)
     :state (%button-state-keyword state-code)
     :state-code state-code)))

(defun %keyboard-modifiers-snapshot (keyboard)
  (let ((pointer (%native-pointer (%ensure-live keyboard))))
    (%make-keyboard-modifiers-event
     :keyboard keyboard
     :depressed
     (ataxia.runtime.raw:%keyboard-modifiers-depressed pointer)
     :latched (ataxia.runtime.raw:%keyboard-modifiers-latched pointer)
     :locked (ataxia.runtime.raw:%keyboard-modifiers-locked pointer)
     :group (ataxia.runtime.raw:%keyboard-modifiers-group pointer))))

(defun %keyboard-repeat-snapshot (keyboard)
  (let ((pointer (%native-pointer (%ensure-live keyboard))))
    (%make-keyboard-repeat-event
     :keyboard keyboard
     :rate (ataxia.runtime.raw:%keyboard-repeat-rate pointer)
     :delay (ataxia.runtime.raw:%keyboard-repeat-delay pointer))))

(defun %surface-effective-damage-snapshot (pointer)
  (let ((count
          (ataxia.runtime.raw:%surface-effective-damage-rectangles
           pointer (cffi:null-pointer) 0)))
    (when (plusp count)
      (cffi:with-foreign-object (rectangles :int32 (* count 4))
        (let ((reported
                (ataxia.runtime.raw:%surface-effective-damage-rectangles
                 pointer rectangles count)))
          (loop for index below (min count reported)
                for offset = (* index 4)
                collect
                (%make-damage-rectangle
                 :x (cffi:mem-aref rectangles :int32 offset)
                 :y (cffi:mem-aref rectangles :int32 (+ offset 1))
                 :width (cffi:mem-aref rectangles :int32 (+ offset 2))
                 :height (cffi:mem-aref rectangles :int32 (+ offset 3)))))))))

(defun %surface-commit-snapshot (surface)
  (%ensure-live surface)
  (let ((pointer (%native-pointer surface)))
    (%make-surface-commit-event
     :sequence (ataxia.runtime.raw:%surface-current-sequence pointer)
     :fields (ataxia.runtime.raw:%surface-current-committed pointer)
     :width (ataxia.runtime.raw:%surface-current-width pointer)
     :height (ataxia.runtime.raw:%surface-current-height pointer)
     :buffer-width (ataxia.runtime.raw:%surface-current-buffer-width pointer)
     :buffer-height (ataxia.runtime.raw:%surface-current-buffer-height pointer)
     :mapped-p (ataxia.runtime.raw:%surface-mapped pointer)
     :damage-rectangles (%surface-effective-damage-snapshot pointer))))
