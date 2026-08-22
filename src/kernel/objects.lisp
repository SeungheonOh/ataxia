;;;; Kernel-owned stable objects.
;;;;
;;;; These objects isolate World from Runtime wrapper identity. Kernel mutates
;;;; their protocol state; World stores only references and its own wrappers.

(in-package #:ataxia.kernel)

(defclass kernel-object ()
  ((kernel :initarg :kernel :reader object-kernel)
   (id :initarg :id :reader object-id)
   (generation :initarg :generation :initform 1 :reader object-generation)
   (state :initarg :state :initform :constructing :accessor object-state))
  (:documentation "Stable Kernel identity with explicit lifecycle state and generation."))

(defclass kernel-output (kernel-object)
  ((runtime-object :initarg :runtime-object :reader output-runtime-object)
   (name :initarg :name :reader output-name)
   (description :initarg :description :reader output-description)
   (width :initarg :width :accessor output-width)
   (height :initarg :height :accessor output-height)
   (scale :initarg :scale :accessor output-scale)
   (enabled-p :initarg :enabled-p :accessor output-enabled-p))
  (:documentation "Configured output identity backed by one Runtime wlr-output."))

(defclass kernel-input-device (kernel-object)
  ((runtime-object :initarg :runtime-object :reader input-runtime-object)
   (name :initarg :name :reader input-name)
   (type :initarg :type :reader input-type)
   (seat :initarg :seat :initform nil :accessor input-seat))
  (:documentation "Runtime input device and its current logical-seat assignment."))

(defclass logical-seat (kernel-object)
  ((runtime-object :initarg :runtime-object :reader seat-runtime-object)
   (name :initarg :name :reader seat-name)
   (capabilities :initarg :capabilities :initform 0 :accessor seat-capabilities)
   (input-devices :initform (make-hash-table :test #'eq)
                  :reader seat-input-devices))
  (:documentation "Stable seat identity owning one real Runtime wlr-seat."))

(defclass surface-node (kernel-object)
  ((runtime-object :initarg :runtime-object :reader surface-runtime-object)
   (parent :initarg :parent :initform nil :accessor surface-parent)
   (children :initform nil :accessor surface-children)
   (local-x :initarg :local-x :initform 0 :accessor surface-local-x)
   (local-y :initarg :local-y :initform 0 :accessor surface-local-y)
   (width :initarg :width :initform 0 :accessor surface-width)
   (height :initarg :height :initform 0 :accessor surface-height)
   (mapped-p :initarg :mapped-p :initform nil :accessor surface-mapped-p)
   (commit-sequence :initarg :commit-sequence :initform 0
                    :accessor surface-commit-sequence))
  (:documentation "Kernel-private committed state for one wl_surface in an application tree."))

(defclass wayland-application (kernel-object drawable interactable)
  ((toplevel :initarg :toplevel :reader application-toplevel)
   (root-surface :initarg :root-surface :reader application-root-surface)
   (title :initarg :title :initform nil :accessor application-title)
   (app-id :initarg :app-id :initform nil :accessor application-app-id)
   (mapped-p :initarg :mapped-p :initform nil :accessor application-mapped-p)
   (drawable-surfaces :initform #() :accessor %application-drawable-surfaces)
   (drawable-revision :initform 0 :accessor %application-drawable-revision))
  (:documentation
   "World-visible Wayland application; all surface and input resolution remains Kernel-owned."))

(defmethod drawable-surfaces ((application wayland-application))
  (values (%application-drawable-surfaces application)
          (%application-drawable-revision application)))

(defmethod drawable-local-bounds ((application wayland-application))
  (let ((surface (application-root-surface application)))
    (values (surface-local-x surface)
            (surface-local-y surface)
            (surface-width surface)
            (surface-height surface))))
