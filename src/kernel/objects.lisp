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

(defclass wayland-client (kernel-object) ()
  (:documentation "Opaque Kernel-owned identity of one Wayland connection."))

(defclass kernel-output (kernel-object)
  ((runtime-object :initarg :runtime-object :reader output-runtime-object)
   (name :initarg :name :reader output-name)
   (description :initarg :description :reader output-description)
   (width :initarg :width :accessor output-width)
   (height :initarg :height :accessor output-height)
   (scale :initarg :scale :accessor output-scale)
   (transform :initarg :transform :accessor output-transform)
   (enabled-p :initarg :enabled-p :accessor output-enabled-p)
   (swapchain :initform nil :accessor %output-swapchain)
   (swapchain-generation :initform 0 :accessor %output-swapchain-generation)
   (target-tokens :initform (make-hash-table :test #'eql)
                  :reader %output-target-tokens)
   (frame-requested-p :initform nil :accessor %output-frame-requested-p)
   (frame-active-p :initform nil :accessor %output-frame-active-p)
   (next-frame-requested-p :initform nil
                           :accessor %output-next-frame-requested-p)
   (retry-timer :initform nil :accessor %output-retry-timer)
   (consecutive-frame-failures :initform 0
                               :accessor %output-consecutive-frame-failures))
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
                  :reader seat-input-devices)
   (keyboard :initform nil :accessor %seat-keyboard)
   (implicit-pointer-grab :initform nil :accessor %seat-implicit-pointer-grab)
   (cursor-request :initform nil :accessor %seat-cursor-request)
   (drag :initform nil :accessor %seat-drag)
   (drag-icon :initform nil :accessor seat-drag-icon))
  (:documentation "Stable seat identity owning one real Runtime wlr-seat."))

(defclass surface-node (kernel-object drawable)
  ((runtime-object :initarg :runtime-object :reader surface-runtime-object)
   (parent :initarg :parent :initform nil :accessor surface-parent)
   (children :initform nil :accessor surface-children)
   (local-x :initarg :local-x :initform 0 :accessor surface-local-x)
   (local-y :initarg :local-y :initform 0 :accessor surface-local-y)
   (width :initarg :width :initform 0 :accessor surface-width)
   (height :initarg :height :initform 0 :accessor surface-height)
   (mapped-p :initarg :mapped-p :initform nil :accessor surface-mapped-p)
   (commit-sequence :initarg :commit-sequence :initform 0
                    :accessor surface-commit-sequence)
   (offset-x :initform 0 :accessor %surface-offset-x)
   (offset-y :initform 0 :accessor %surface-offset-y)
   (application :initform nil :accessor %surface-application)
   (source-box :initform #(0d0 0d0 0d0 0d0) :accessor %surface-source-box)
   (buffer-transform :initform 0 :accessor %surface-buffer-transform)
   (damage :initform nil :accessor %surface-damage)
   (opaque-region :initform nil :accessor %surface-opaque-region)
   (frame-callback-p :initform nil :accessor %surface-frame-callback-p)
   (render-source :initform nil :accessor %surface-render-source)
   (protocol-token :initform nil :accessor %surface-protocol-token)
   (output-membership :initform (make-hash-table :test #'eq)
                      :reader %surface-output-membership)
   (preferred-scale :initform nil :accessor %surface-preferred-scale)
   (externally-exposed-p :initform nil :accessor %surface-externally-exposed-p))
  (:documentation "Kernel-private committed state for one wl_surface in an application tree."))

(defclass wayland-application (kernel-object drawable interactable)
  ((toplevel :initarg :toplevel :reader application-toplevel)
   (root-surface :initarg :root-surface :reader application-root-surface)
   (client-identity :initform nil :accessor %application-client-identity)
   (title :initarg :title :initform nil :accessor application-title)
   (app-id :initarg :app-id :initform nil :accessor application-app-id)
   (mapped-p :initarg :mapped-p :initform nil :accessor application-mapped-p)
   (drawable-surfaces :initform #() :accessor %application-drawable-surfaces)
   (drawable-revision :initform 0 :accessor %application-drawable-revision))
  (:documentation
   "World-visible Wayland application; all surface and input resolution remains Kernel-owned."))

(defclass wayland-render-source (render-source)
  ((buffer :initarg :buffer :reader %render-source-buffer)
   (width :initarg :width :reader render-source-width)
   (height :initarg :height :reader render-source-height)
   (gles-target :initarg :gles-target :reader render-source-gles-target)
   (gles-name :initarg :gles-name :reader render-source-gles-name)
   (has-alpha-p :initarg :has-alpha-p :reader render-source-has-alpha-p)
   (generation :initarg :generation :reader render-source-generation)
   (retain-count :initform 1 :accessor %render-source-retain-count))
  (:documentation
   "Ref-counted view of a Runtime-retained client buffer and its GLES texture."))

(defclass wayland-drawable-surface (drawable-surface)
  ((presentation-token
    :initarg :presentation-token
    :reader drawable-surface-presentation-token))
  (:documentation
   "Drawable quad carrying the opaque token needed after presenting a wl_surface."))

(defclass surface-protocol-token ()
  ((surface :initarg :surface :reader %protocol-token-surface)
   (generation :initarg :generation :reader %protocol-token-generation))
  (:documentation "Opaque token Kernel accepts back from a World frame result."))

(defclass output-target-token ()
  ((output :initarg :output :reader %target-token-output)
   (generation :initarg :generation :reader %target-token-generation)
   (native-address :initarg :native-address :reader %target-token-address))
  (:documentation "World-opaque identity for one swapchain buffer generation."))

(defmethod retain-render-source ((source wayland-render-source))
  (unless (plusp (%render-source-retain-count source))
    (error "Cannot retain a released Wayland render source."))
  (incf (%render-source-retain-count source))
  source)

(defmethod release-render-source ((source wayland-render-source))
  (unless (plusp (%render-source-retain-count source))
    (error "Wayland render source released more than it was retained."))
  (when (zerop (decf (%render-source-retain-count source)))
    (ataxia.runtime:release-buffer (%render-source-buffer source)))
  nil)

(defmethod drawable-surfaces ((application wayland-application))
  (values (%application-drawable-surfaces application)
          (%application-drawable-revision application)))

(defmethod drawable-local-bounds ((application wayland-application))
  (multiple-value-bind (x y width height)
      (ataxia.runtime:xdg-surface-geometry
       (application-toplevel application))
    (if (and width height (plusp width) (plusp height))
        (values x y width height)
        (let ((surface (application-root-surface application)))
          (values (surface-local-x surface)
                  (surface-local-y surface)
                  (surface-width surface)
                  (surface-height surface))))))

(defclass client-request ()
  ((seat :initarg :seat :initform nil :reader client-request-seat)
   (serial :initarg :serial :initform nil :reader client-request-serial))
  (:documentation "Stable Kernel copy of a client request requiring World policy."))

(defclass move-client-request (client-request) ())

(defclass resize-client-request (client-request)
  ((edges :initarg :edges :reader resize-client-request-edges)))

(defclass state-client-request (client-request)
  ((name :initarg :name :reader state-client-request-name)
   (value :initarg :value :reader state-client-request-value)))

(defclass fullscreen-client-request (state-client-request)
  ((output :initarg :output :initform nil :reader fullscreen-client-request-output)))

(defclass window-menu-client-request (client-request)
  ((x :initarg :x :reader window-menu-client-request-x)
   (y :initarg :y :reader window-menu-client-request-y)))

(defclass cursor-surface-request ()
  ((seat :initarg :seat :reader cursor-surface-request-seat)
   (surface :initarg :surface :initform nil
            :reader cursor-surface-request-surface)
   (serial :initarg :serial :reader cursor-surface-request-serial)
   (hotspot-x :initarg :hotspot-x :reader cursor-surface-request-hotspot-x)
   (hotspot-y :initarg :hotspot-y :reader cursor-surface-request-hotspot-y))
  (:documentation "Stable client request to replace or hide one seat cursor surface."))
