;;;; Engine-independent output-local content and the World hosting contract.
(in-package #:ataxia.world)

(defclass ui-overlay ()
  ((component :initarg :component :reader overlay-component)
   (output :initarg :output :accessor overlay-output)
   (x :initarg :x :accessor overlay-x)
   (y :initarg :y :accessor overlay-y)
   (width :initarg :width :accessor overlay-width)
   (height :initarg :height :accessor overlay-height)
   (layer :initarg :layer :initform 0 :accessor overlay-layer)
   (visible-p :initarg :visible-p :initform nil
              :accessor overlay-visible-p)
   (opacity :initarg :opacity :initform 1d0
            :accessor overlay-opacity))
  (:documentation
   "Output-local drawable content composited above the World scene and below cursors. Interactable components also participate in input picking."))

(defmethod initialize-instance :after ((overlay ui-overlay) &key)
  (unless (typep (overlay-component overlay) 'ataxia.kernel:drawable)
    (error "UI-OVERLAY requires a drawable component.")))

(defun make-overlay
    (component output x y width height &key (layer 0) visible-p (opacity 1d0))
  (make-instance
   'ui-overlay :component component :output output
   :x (coerce x 'double-float) :y (coerce y 'double-float)
   :width (coerce width 'double-float) :height (coerce height 'double-float)
   :layer layer :visible-p visible-p :opacity (coerce opacity 'double-float)))

(defgeneric overlay-visibility-changed (overlay visible-p))

(defmethod overlay-visibility-changed ((overlay ui-overlay) visible-p)
  (declare (ignore visible-p))
  overlay)

(defgeneric overlay-output-changed (overlay output))

(defmethod overlay-output-changed
    ((overlay ui-overlay) output)
  (declare (ignore output))
  overlay)

(defgeneric destroy-overlay (overlay))

(defmethod destroy-overlay ((overlay ui-overlay))
  (ataxia.kernel:drawable-detach-graphics
   (overlay-component overlay))
  nil)

(defgeneric overlay-input-enabled-p (overlay)
  (:method ((overlay ui-overlay)) t))

(defclass ui-host ()
  ((next-widget-id :initform 0 :accessor %next-widget-id)
   (agent-events :initform (make-agent-event-stream)
                 :reader world-agent-event-stream))
  (:documentation "Optional per-World UI identity and event storage. Scheduling and scene ownership remain in the World."))

(defmethod ataxia.kernel:world-detached :before ((world ui-host) kernel)
  (when (eq kernel (ataxia.kernel:world-kernel world))
    (close-agent-event-stream (world-agent-event-stream world) :world-replaced)))

(defgeneric world-outputs (world)
  (:documentation "Connected Kernel outputs in the World's stable presentation order."))
(defgeneric world-overlays (world))
(defgeneric (setf world-overlays) (overlays world))
(defgeneric add-overlay (world overlay)
  (:documentation "Attach an overlay, invalidate its coverage, and schedule its UI work."))
(defgeneric remove-overlay (world overlay)
  (:documentation "Detach an overlay and its input references; call DESTROY-OVERLAY when graphics retirement is safe."))
(defgeneric show-overlay (world overlay))
(defgeneric hide-overlay (world overlay)
  (:documentation "Hide the overlay, release its input references, and restore displaced focus."))
(defgeneric damage-overlay (world overlay)
  (:documentation "Invalidate current output-local coverage without rendering immediately."))
(defgeneric request-overlay-update (world overlay)
  (:documentation "Schedule a frame or the next component deadline. Must do nothing after quiescing."))

(defun monotonic-time ()
  (/ (get-internal-real-time)
     (coerce internal-time-units-per-second 'double-float)))

(defun output-logical-size (output)
  "Output-local dimensions, accounting for scale and all quarter-turn transforms."
  (let* ((scale (max .01d0 (coerce (ataxia.kernel:output-scale output) 'double-float)))
         (width (/ (ataxia.kernel:output-width output) scale))
         (height (/ (ataxia.kernel:output-height output) scale)))
    (if (member (ataxia.kernel:output-transform output) '(1 3 5 7))
        (values height width)
        (values width height))))

(defun require-world-output (world output)
  (or (if output (find output (world-outputs world)) (first (world-outputs world)))
      (error "World has no matching connected output.")))
