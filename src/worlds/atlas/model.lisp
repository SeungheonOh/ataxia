;;;; Unified packed-scene state.
;;;;
;;;; Every presented Wayland application or native component occupies the same
;;;; ATLAS-OBJECT node type. Mapping objects define placement without exposing
;;;; the component implementation to rendering, picking, damage, or input.

(in-package #:ataxia.atlas-world)

(defconstant +button-left+ 272)
(defconstant +button-middle+ 274)
(defconstant +resize-top+ 1)
(defconstant +resize-bottom+ 2)
(defconstant +resize-left+ 4)
(defconstant +resize-right+ 8)

(defclass atlas-mapping () ())

(defclass atlas-plane-mapping (atlas-mapping) ())

(defclass atlas-output-mapping (atlas-mapping)
  ((output-state :initarg :output-state :reader %mapping-output-state)
   (x :initarg :x :accessor %mapping-x)
   (y :initarg :y :accessor %mapping-y)))

(defgeneric %mapping-packed-p (mapping))
(defmethod %mapping-packed-p ((mapping atlas-mapping)) nil)
(defmethod %mapping-packed-p ((mapping atlas-plane-mapping)) t)

(defclass atlas-scene-root ()
  ((children :initform nil :accessor %scene-root-children)))

(defclass atlas-object ()
  ((component :initarg :component :reader atlas-object-component)
   (mapping :initarg :mapping :accessor %atlas-object-mapping)
   (parent :initform nil :accessor %atlas-object-parent)
   (children :initform nil :accessor %atlas-object-children)
   (layer :initarg :layer :initform 0 :reader %atlas-object-layer)
   (width :initarg :width :accessor atlas-object-width)
   (height :initarg :height :accessor atlas-object-height)
   (mapped-p :initarg :mapped-p :initform t :accessor %atlas-object-mapped-p)
   (hidden-p :initform nil :accessor %atlas-object-hidden-p)
   (drawable-revision :initform 0 :accessor %atlas-object-drawable-revision)
   (appearance-start :initform nil :accessor %atlas-object-appearance-start)
   (restore-size :initform nil :accessor %atlas-object-restore-size))
  (:documentation
   "World-owned scene node for any drawable and interactable component."))

(defmethod initialize-instance :after ((object atlas-object) &key)
  (unless (typep (atlas-object-component object) 'ataxia.kernel:drawable)
    (error "ATLAS-OBJECT requires a drawable component."))
  (unless (typep (atlas-object-component object) 'ataxia.kernel:interactable)
    (error "ATLAS-OBJECT requires an interactable component.")))

(defun %scene-objects (world)
  (%scene-root-children (%world-scene world)))

(defun %scene-object-sequence (world)
  (labels ((walk (object)
             (cons object (mapcan #'walk (%atlas-object-children object)))))
    (mapcan #'walk (%scene-objects world))))

(defun %insert-scene-object (world object)
  (let ((root (%world-scene world)))
    (setf (%atlas-object-parent object) root
          (%scene-root-children root)
          (stable-sort
           (append (%scene-root-children root) (list object)) #'<
           :key #'%atlas-object-layer)))
  object)

(defun %remove-scene-object (world object)
  (declare (ignore world))
  (let ((parent (%atlas-object-parent object)))
    (typecase parent
      (atlas-scene-root
       (setf (%scene-root-children parent)
             (delete object (%scene-root-children parent) :test #'eq)))
      (atlas-object
       (setf (%atlas-object-children parent)
             (delete object (%atlas-object-children parent) :test #'eq)))
      (null nil)))
  (setf (%atlas-object-parent object) nil)
  object)

(defun %object-visible-p (object)
  (and (%atlas-object-mapped-p object)
       (not (%atlas-object-hidden-p object))))

(defun %packed-object-p (object)
  (%mapping-packed-p (%atlas-object-mapping object)))

(defstruct (%atlas-placement
             (:constructor %make-atlas-placement (object x y width height)))
  object
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
  (cursor-hotspot-y 0 :type integer)
  cursor-coverage cursor-coverage-output)

(defstruct (%atlas-operation
             (:constructor %make-atlas-operation
                 (&key kind button object edges forward-release-p
                       cursor-x cursor-y camera-x camera-y
                       object-width object-height)))
  kind button object edges forward-release-p cursor-x cursor-y camera-x camera-y
  object-width object-height)

(defstruct (%world-frame-cookie
             (:constructor %make-world-frame-cookie (damage-frame)))
  damage-frame)

(defclass atlas-world (ataxia.kernel:world)
  ((kernel :initform nil :accessor ataxia.kernel:world-kernel)
   (kernel-object-index :initform (make-hash-table :test #'eq)
                        :reader %world-kernel-object-index)
   (scene :initform (make-instance 'atlas-scene-root) :reader %world-scene)
   (layout :initform (%make-atlas-layout) :reader %world-layout)
   (outputs :initform (make-hash-table :test #'eq) :reader %world-outputs)
   (output-components :initform (make-hash-table :test #'eq)
                      :reader %world-output-components)
   (retired-components :initform nil :accessor %world-retired-components)
   (seats :initform (make-hash-table :test #'eq) :reader %world-seats)
   (damage :initform (ataxia.world:make-damage-tracker) :reader %world-damage)
   (damage-debug-p :initarg :damage-debug-p :initform nil
                   :accessor %world-damage-debug-p)
   (renderer :initform nil :accessor %world-renderer)
   (component-timer :initform nil :accessor %world-component-timer)
   (quiescing-p :initform nil :accessor %world-quiescing-p))
  (:documentation
   "Packed component tree with per-output parallel cameras and overlays."))

(defun %hash-values (table)
  (loop for value being the hash-values of table collect value))

(defun %output-states (world)
  (%hash-values (%world-outputs world)))

(defun %seat-states (world)
  (%hash-values (%world-seats world)))

(defun %first-output-state (world)
  (first (%output-states world)))

(defun %request-output-state-frame (world state)
  (when (and state (not (%world-quiescing-p world)))
    (ataxia.kernel:request-output-frame (%atlas-output-output state)))
  world)

(defun %request-all-frames (world)
  (dolist (state (%output-states world))
    (%request-output-state-frame world state))
  world)
