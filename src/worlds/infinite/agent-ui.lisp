;;;; Agent-created Infinite World widgets.
;;;;
;;;; Arbitrary Slint components enter the existing overlay tree as ordinary
;;;; drawables and interactables. This module adds stable lookup, bounded input
;;;; events, geometry-safe updates, and a small notification convenience.

(in-package #:ataxia.infinite-world)

(defconstant +agent-widget-event-limit+ 64)

(defparameter +notification-source+
  "export component AtaxiaNotification inherits Window {
    background: transparent;
    in property <string> heading: \"NOTICE\";
    in property <string> message: \"\";
    callback dismiss();

    panel := Rectangle {
        width: parent.width;
        height: parent.height;
        background: #f4f4f1;
        border-width: 1px;
        border-color: #171717;

        Rectangle {
            x: 0px;
            y: 0px;
            width: 6px;
            height: parent.height;
            background: #171717;
        }

        Text {
            x: 22px;
            y: 15px;
            width: parent.width - 64px;
            height: 20px;
            text: root.heading;
            color: #171717;
            font-size: 12px;
            font-weight: 700;
            overflow: elide;
        }

        Text {
            x: 22px;
            y: 40px;
            width: parent.width - 44px;
            height: parent.height - 52px;
            text: root.message;
            color: #40403d;
            font-size: 14px;
            wrap: word-wrap;
            overflow: elide;
        }

        close := Rectangle {
            x: parent.width - 38px;
            y: 10px;
            width: 28px;
            height: 28px;
            background: close-touch.pressed ? #171717 : close-touch.has-hover ? #d4d4d0 : transparent;
            Text {
                width: parent.width;
                height: parent.height;
                text: \"×\";
                color: close-touch.pressed ? #f4f4f1 : #171717;
                font-size: 18px;
                horizontal-alignment: center;
                vertical-alignment: center;
            }
            close-touch := TouchArea { clicked => { root.dismiss(); } }
        }
    }
}")

(defstruct (agent-widget-event
             (:constructor %make-agent-widget-event
                 (sequence name value timestamp)))
  sequence name value timestamp)

(defclass agent-widget (canvas-overlay)
  ((id :initarg :id :reader agent-widget-id)
   (world :initarg :world :reader %agent-widget-world)
   (events :initform nil :accessor %agent-widget-events)
   (next-event-sequence :initform 0 :accessor %agent-widget-next-event-sequence)
   (expiry-source :initform nil :accessor %agent-widget-expiry-source)))

(defclass agent-notification (agent-widget) ())

(defmethod %destroy-overlay ((widget agent-widget))
  (when (%agent-widget-expiry-source widget)
    (ataxia.runtime:remove-event-loop-source
     (%agent-widget-expiry-source widget))
    (setf (%agent-widget-expiry-source widget) nil))
  (let ((component (canvas-overlay-component widget)))
    (ataxia.world.slint:set-slint-component-invalidator component nil)
    (when (ataxia.world.slint:slint-component-graphics-attached-p component)
      (ataxia.kernel:drawable-detach-graphics component))
    (ataxia.world.slint:destroy-slint-component component))
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
           name value (%now))))
    (push event (%agent-widget-events widget))
    (when (> (length (%agent-widget-events widget))
             +agent-widget-event-limit+)
      (setf (%agent-widget-events widget)
            (subseq (%agent-widget-events widget)
                    0 +agent-widget-event-limit+)))
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
  "Record a public Slint callback and optionally invoke a short Lisp handler."
  (check-type widget agent-widget)
  (check-type name string)
  (check-type handler (or null function))
  (ataxia.world.slint:set-slint-callback
   (canvas-overlay-component widget) name
   (lambda (component value)
     (declare (ignore component))
     (let ((event (%record-agent-widget-event widget name value)))
       (when handler (funcall handler widget event)))))
  widget)

(defun %agent-widget-output-state (world output)
  (or (and output (gethash output (%world-outputs world)))
      (and (null output) (%first-output-state world))
      (error "Infinite World has no matching output for an agent widget.")))

(defun %request-agent-widget-frame (widget)
  (let* ((world (%agent-widget-world widget))
         (state (gethash (canvas-overlay-output widget)
                         (%world-outputs world))))
    (unless (%world-quiescing-p world)
      (when (and state (canvas-overlay-visible-p widget))
        (%request-output-state-frame world state))
      (%schedule-component-timer world)))
  widget)

(defun %create-agent-widget
    (class world source
     &key component-name source-path output
       (x 24d0) (y 24d0) (width 320d0) (height 180d0)
       (layer 1100) (visible-p t) (opacity 1d0) callbacks)
  (check-type world infinite-world)
  (check-type source string)
  (let* ((state (%agent-widget-output-state world output))
         (output (%canvas-output-output state))
         (id (incf (%world-next-agent-widget-id world)))
         (component nil)
         (widget nil))
    (handler-case
        (progn
          (setf component
                (ataxia.world.slint:make-slint-component
                 :source source
                 :source-path (or source-path
                                  (format nil "ataxia-agent-widget-~D.slint" id))
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
          (ataxia.world.slint:set-slint-component-invalidator
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
                (ataxia.world.slint:set-slint-component-invalidator
                 component nil)
                (ataxia.world.slint:destroy-slint-component component))
              (error 'ataxia.world:world-operation-rejected :cause cause)))))))

(defun make-agent-widget
    (world source &key component-name source-path output
      (x 24d0) (y 24d0) (width 320d0) (height 180d0)
      (layer 1100) (visible-p t) (opacity 1d0) callbacks)
  "Create an arbitrary Slint widget in the Infinite World overlay tree."
  (%create-agent-widget
   'agent-widget world source
   :component-name component-name :source-path source-path :output output
   :x x :y y :width width :height height :layer layer
   :visible-p visible-p :opacity opacity :callbacks callbacks))

(defun remove-agent-widget (world widget-or-id)
  (let ((widget
          (etypecase widget-or-id
            (agent-widget widget-or-id)
            (integer (find-agent-widget world widget-or-id)))))
    (when widget
      (unless (eq world (%agent-widget-world widget))
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
  (unless (eq world (%agent-widget-world widget))
    (error "Agent widget does not belong to this World."))
  (when (canvas-overlay-visible-p widget)
    (%damage-overlay world widget))
  (when x-p (setf (canvas-overlay-x widget) (coerce x 'double-float)))
  (when y-p (setf (canvas-overlay-y widget) (coerce y 'double-float)))
  (when (or width-p height-p)
    (let ((new-width (if width-p (coerce width 'double-float)
                         (canvas-overlay-width widget)))
          (new-height (if height-p (coerce height 'double-float)
                          (canvas-overlay-height widget))))
      (ataxia.world.slint:resize-slint-component
       (canvas-overlay-component widget) new-width new-height
       :scale (ataxia.kernel:output-scale
               (canvas-overlay-output widget)))
      (setf (canvas-overlay-width widget) new-width
            (canvas-overlay-height widget) new-height)))
  (when opacity-p
    (setf (canvas-overlay-opacity widget) (coerce opacity 'double-float)))
  (when visible-supplied-p
    (if visible-p (show-overlay world widget) (hide-overlay world widget)))
  (when (canvas-overlay-visible-p widget)
    (%damage-overlay world widget))
  (%request-agent-widget-frame widget))

(defun set-agent-widget-property (widget name value)
  "Update one public Slint property on WIDGET."
  (check-type widget agent-widget)
  (ataxia.world.slint:set-slint-property
   (canvas-overlay-component widget) name value)
  widget)

(defun %notifications-on-output (world output)
  (remove-if-not
   (lambda (widget)
     (and (typep widget 'agent-notification)
          (eq output (canvas-overlay-output widget))))
   (list-agent-widgets world)))

(defun %restack-notifications (world output)
  (let ((y 24d0))
    (dolist (widget (%notifications-on-output world output))
      (when (canvas-overlay-visible-p widget)
        (%damage-overlay world widget)
        (setf (canvas-overlay-y widget) y)
        (incf y (+ (canvas-overlay-height widget) 12d0))
        (%damage-overlay world widget)
        (%request-agent-widget-frame widget))))
  world)

(defun %expire-agent-widget (widget duration)
  (when duration
    (check-type duration (real (0) *))
    (let* ((world (%agent-widget-world widget))
           (runtime
             (ataxia.kernel:kernel-runtime
              (ataxia.kernel:world-kernel world)))
           (source
             (ataxia.runtime:add-event-loop-timer
              runtime
              (lambda (ignored)
                (declare (ignore ignored))
                (let ((output (canvas-overlay-output widget)))
                  (remove-agent-widget world widget)
                  (%restack-notifications world output))
                0))))
      (setf (%agent-widget-expiry-source widget) source)
      (ataxia.runtime:update-event-loop-timer
       source (max 1 (round (* duration 1000))))))
  widget)

(defun show-notification
    (world message &key (title "NOTICE") output (duration 5d0))
  "Show a dismissible, optionally expiring notification on one output."
  (check-type message string)
  (check-type title string)
  (let* ((state (%agent-widget-output-state world output))
         (output (%canvas-output-output state))
         (width 360d0)
         (height 104d0))
    (multiple-value-bind (output-width output-height)
        (%output-logical-size state)
      (declare (ignore output-height))
      (let ((widget
              (%create-agent-widget
               'agent-notification world +notification-source+
               :component-name "AtaxiaNotification"
               :source-path "ataxia-agent-notification.slint"
               :output output :x (max 24d0 (- output-width width 24d0))
               :y 24d0 :width width :height height :layer 1200)))
        (set-agent-widget-property widget "heading" title)
        (set-agent-widget-property widget "message" message)
        (bind-agent-widget-event
         widget "dismiss"
         (lambda (subject event)
           (declare (ignore event))
           (let ((subject-output (canvas-overlay-output subject)))
             (remove-agent-widget world subject)
             (%restack-notifications world subject-output))))
        (%restack-notifications world output)
        (%expire-agent-widget widget duration)
        widget))))
