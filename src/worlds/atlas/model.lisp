;;;; Coordinate-free packed-plane state.
;;;;
;;;; ATLAS-WINDOW deliberately has no position. Window identity, dimensions,
;;;; and protocol state are durable; placement is a derived result rebuilt by
;;;; the atlas packer whenever the set of visible rectangles changes.

(in-package #:ataxia.atlas-world)

(defconstant +button-left+ 272)
(defconstant +button-middle+ 274)
(defconstant +resize-top+ 1)
(defconstant +resize-bottom+ 2)
(defconstant +resize-left+ 4)
(defconstant +resize-right+ 8)

(defclass atlas-window (ataxia.world:application-binding)
  ((width :initarg :width :accessor atlas-window-width)
   (height :initarg :height :accessor atlas-window-height)
   (mapped-p :initform nil :accessor %atlas-window-mapped-p)
   (hidden-p :initform nil :accessor %atlas-window-hidden-p)
   (drawable-revision :initform 0 :accessor %atlas-window-drawable-revision)
   (appearance-start :initform nil :accessor %atlas-window-appearance-start)
   (restore-size :initform nil :accessor %atlas-window-restore-size))
  (:documentation
   "World attachment for one packed Wayland application. Placement is never stored here; it is derived from the complete visible window set."))

(defun atlas-window-application (window)
  (ataxia.world:binding-application window))

(defstruct (%atlas-placement
             (:constructor %make-atlas-placement (window x y width height)))
  window
  (x 0d0 :type double-float)
  (y 0d0 :type double-float)
  (width 0d0 :type double-float)
  (height 0d0 :type double-float))

(defstruct (%atlas-layout (:constructor %make-atlas-layout))
  (placements (make-hash-table :test #'eq))
  (previous nil)
  (width 0d0 :type double-float)
  (height 0d0 :type double-float)
  (transition-start 0d0 :type double-float)
  (transition-duration 0.22d0 :type double-float)
  (revision 0 :type integer))

(defstruct (%atlas-output (:constructor %make-atlas-output (output)))
  output
  (camera-x 0d0 :type double-float)
  (camera-y 0d0 :type double-float)
  (zoom 1d0 :type double-float)
  (camera-authored-p nil :type boolean)
  (buffer-width 0 :type integer)
  (buffer-height 0 :type integer)
  (transform 0 :type integer))

(defstruct (%atlas-seat (:constructor %make-atlas-seat (seat)))
  seat output
  (x 0d0 :type double-float)
  (y 0d0 :type double-float)
  (buttons (make-hash-table :test #'eql))
  focused hovered operation last-pointer-input
  cursor-surface
  (cursor-hotspot-x 0 :type integer)
  (cursor-hotspot-y 0 :type integer))

(defstruct (%atlas-operation
             (:constructor %make-atlas-operation
                 (&key kind button window edges forward-release-p
                       cursor-x cursor-y camera-x camera-y
                       window-width window-height)))
  kind button window edges forward-release-p cursor-x cursor-y camera-x camera-y
  window-width window-height)

(defstruct (%world-frame-cookie
             (:constructor %make-world-frame-cookie (damage-frame)))
  damage-frame)

(defun %window-visible-p (window)
  (and (%atlas-window-mapped-p window)
       (not (%atlas-window-hidden-p window))))
