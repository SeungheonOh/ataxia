;;;; Stable widget identity, bounded events, and engine-independent lifetime.
(in-package #:ataxia.world)

(defconstant +agent-widget-event-limit+ 64)

(defstruct (agent-widget-event
             (:constructor %make-agent-widget-event
                 (sequence name value timestamp)))
  sequence name value timestamp)

(defclass agent-widget (ui-overlay)
  ((id :initarg :id :reader agent-widget-id)
   (world :initarg :world :reader agent-widget-world)
   (events :initform nil :accessor %agent-widget-events)
   (next-event-sequence :initform 0 :accessor %agent-widget-next-event-sequence)
   (expiry-source :initform nil :accessor %agent-widget-expiry-source)))

(defmethod destroy-overlay ((widget agent-widget))
  (when (%agent-widget-expiry-source widget)
    (ataxia.runtime:remove-event-loop-source
     (%agent-widget-expiry-source widget))
    (setf (%agent-widget-expiry-source widget) nil))
  (let ((component (overlay-component widget)))
    (ataxia.world:ui-set-invalidator component nil)
    (ataxia.kernel:drawable-detach-graphics component)
    (ataxia.world:ui-destroy component))
  nil)

(defun list-agent-widgets (world)
  (remove-if-not (lambda (overlay) (typep overlay 'agent-widget))
                 (world-overlays world)))

(defun find-agent-widget (world id)
  (find id (list-agent-widgets world) :key #'agent-widget-id :test #'eql))

(defun %record-agent-widget-event (widget name value)
  (let ((event
          (%make-agent-widget-event
           (incf (%agent-widget-next-event-sequence widget))
           name value (monotonic-time))))
    (push event (%agent-widget-events widget))
    (when (> (length (%agent-widget-events widget))
             +agent-widget-event-limit+)
      (setf (%agent-widget-events widget)
            (subseq (%agent-widget-events widget)
                    0 +agent-widget-event-limit+)))
    (ataxia.world:publish-agent-event
     (ataxia.world:world-agent-event-stream (agent-widget-world widget))
     (agent-widget-id widget) name value :timestamp (monotonic-time))
    event))

(defun agent-widget-events (widget &key (after 0))
  "Return recorded callback events newer than AFTER in delivery order."
  (check-type widget agent-widget)
  (check-type after (integer 0 *))
  (nreverse
   (remove-if-not
    (lambda (event) (> (agent-widget-event-sequence event) after))
    (copy-list (%agent-widget-events widget)))))

(defun bind-agent-widget-event (widget name &optional handler)
  "Record a named UI callback and optionally invoke a short Lisp handler."
  (check-type widget agent-widget)
  (check-type name string)
  (check-type handler (or null function))
  (ataxia.world:ui-set-callback
   (overlay-component widget) name
   (lambda (component value)
     (declare (ignore component))
     (let ((event (%record-agent-widget-event widget name value)))
       (when handler (funcall handler widget event)))))
  widget)

(defun %request-agent-widget-frame (widget)
  (request-overlay-update (agent-widget-world widget) widget)
  widget)

(defun create-agent-widget
    (class world source
     &key component-name source-path output component-factory
       (x 24d0) (y 24d0) (width 320d0) (height 180d0)
       (layer 1100) (visible-p t) (opacity 1d0) callbacks)
  (check-type world ui-host)
  (check-type source string)
  (let* ((output (require-world-output world output))
         (id (incf (%next-widget-id world)))
         (component nil)
         (widget nil))
    (handler-case
        (progn
          (setf component
                (funcall (or component-factory (error "Supply a UI component factory."))
                 :source source
                 :source-path (or source-path
                                  (format nil "ataxia-agent-widget-~D" id))
                 :component-name component-name
                 :width width :height height
                 :scale (ataxia.kernel:output-scale output))
                widget
                (make-instance
                 class :id id :world world :component component :output output
                 :x (coerce x 'double-float) :y (coerce y 'double-float)
                 :width (coerce width 'double-float)
                 :height (coerce height 'double-float)
                 :layer layer :visible-p visible-p
                 :opacity (coerce opacity 'double-float)))
          (ataxia.world:ui-set-invalidator
           component (lambda (ignored)
                       (declare (ignore ignored))
                       (%request-agent-widget-frame widget)))
          (dolist (name callbacks)
            (bind-agent-widget-event widget name))
          (add-overlay world widget))
      (serious-condition (cause)
        (if (and widget (member widget (world-overlays world) :test #'eq))
            (error cause)
            (progn
              (when component
                (ataxia.world:ui-set-invalidator
                 component nil)
                (ataxia.world:ui-destroy component))
              (error 'ataxia.world:world-operation-rejected :cause cause)))))))

(defun remove-agent-widget (world widget-or-id)
  (let ((widget
          (etypecase widget-or-id
            (agent-widget widget-or-id)
            (integer (find-agent-widget world widget-or-id)))))
    (when widget
      (unless (eq world (agent-widget-world widget))
        (error "Agent widget does not belong to this World."))
      (remove-overlay world widget)))
  nil)

(defun configure-agent-widget
    (world widget
     &key (x nil x-p) (y nil y-p)
       (width nil width-p) (height nil height-p)
       (opacity nil opacity-p) (visible-p nil visible-supplied-p))
  "Update widget presentation while damaging both old and new coverage."
  (check-type widget agent-widget)
  (unless (eq world (agent-widget-world widget))
    (error "Agent widget does not belong to this World."))
  (when (overlay-visible-p widget)
    (damage-overlay world widget))
  (when x-p (setf (overlay-x widget) (coerce x 'double-float)))
  (when y-p (setf (overlay-y widget) (coerce y 'double-float)))
  (when (or width-p height-p)
    (let ((new-width (if width-p (coerce width 'double-float)
                         (overlay-width widget)))
          (new-height (if height-p (coerce height 'double-float)
                          (overlay-height widget))))
      (ataxia.world:ui-resize
       (overlay-component widget) new-width new-height
       :scale (ataxia.world:ui-raster-scale
               (overlay-component widget)))
      (setf (overlay-width widget) new-width
            (overlay-height widget) new-height)))
  (when opacity-p
    (setf (overlay-opacity widget) (coerce opacity 'double-float)))
  (when visible-supplied-p
    (if visible-p (show-overlay world widget) (hide-overlay world widget)))
  (when (overlay-visible-p widget)
    (damage-overlay world widget))
  (%request-agent-widget-frame widget))

(defun set-agent-widget-property (widget name value)
  "Update one public UI property on WIDGET."
  (check-type widget agent-widget)
  (ataxia.world:ui-set-property
   (overlay-component widget) name value)
  widget)


(defun expire-agent-widget (widget duration &optional after-removal)
  "Remove WIDGET after DURATION seconds, then call AFTER-REMOVAL on the owner."
  (when duration
    (check-type duration (real (0) *))
    (when (%agent-widget-expiry-source widget)
      (ataxia.runtime:remove-event-loop-source (%agent-widget-expiry-source widget)))
    (let* ((world (agent-widget-world widget))
           (runtime (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world)))
           (source (ataxia.runtime:add-event-loop-timer
                    runtime
                    (lambda (ignored)
                      (declare (ignore ignored))
                      (remove-agent-widget world widget)
                      (when after-removal (funcall after-removal))
                      0))))
      (setf (%agent-widget-expiry-source widget) source)
      (ataxia.runtime:update-event-loop-timer source (max 1 (round (* duration 1000))))))
  widget)

(defun position-widget (world widget x y width height)
  ;; Chrome remains aligned to device pixels, including fractional output scale.
  (let* ((scale (ataxia.kernel:output-scale (overlay-output widget)))
         (x (/ (round (* x scale)) scale))
         (y (/ (round (* y scale)) scale))
         (width (/ (max 1 (round (* width scale))) scale))
         (height (/ (max 1 (round (* height scale))) scale)))
    (unless (and (= x (overlay-x widget)) (= y (overlay-y widget))
                 (= width (overlay-width widget)) (= height (overlay-height widget)))
      (let ((resize (or (/= width (overlay-width widget))
                        (/= height (overlay-height widget)))))
        (if resize
            (configure-agent-widget world widget :x x :y y :width width :height height)
            (configure-agent-widget world widget :x x :y y))))))
