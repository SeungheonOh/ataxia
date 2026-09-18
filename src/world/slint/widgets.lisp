;;;; Slint widget and notification conveniences for any UI host.
(in-package #:ataxia.world.slint)

(defun make-agent-widget
    (world source &key component-name source-path output
      (x 24d0) (y 24d0) (width 320d0) (height 180d0)
      (layer 1100) (visible-p t) (opacity 1d0) callbacks)
  "Create an arbitrary Slint widget in the World overlay tree."
  (create-agent-widget
   'agent-widget world source :component-factory #'make-slint-component
   :component-name component-name :source-path source-path :output output
   :x x :y y :width width :height height :layer layer
   :visible-p visible-p :opacity opacity :callbacks callbacks))

(defclass agent-notification (ataxia.world:agent-widget) ())

(defparameter +notification-source+
  "export component AtaxiaNotification inherits Window {
    background: transparent;
    in property <string> heading: \"NOTICE\";
    in property <string> message: \"\";
    callback dismiss();

    panel := Rectangle {
        width: parent.width;
        height: parent.height;
        background: #ffffff;
        border-width: 1px;
        border-color: #d4d8dc;

        Text {
            x: 16px;
            y: 12px;
            width: parent.width - 64px;
            height: 20px;
            text: root.heading;
            color: #24282d;
            font-size: 12px;
            font-weight: 600;
            overflow: elide;
        }

        Text {
            x: 16px;
            y: 40px;
            width: parent.width - 32px;
            height: parent.height - 52px;
            text: root.message;
            color: #424950;
            font-size: 13px;
            wrap: word-wrap;
            overflow: elide;
        }

        close := Rectangle {
            x: parent.width - 38px;
            y: 10px;
            width: 28px;
            height: 28px;
            background: close-touch.pressed ? #24282d : close-touch.has-hover ? #f0f2f4 : transparent;
            Text {
                width: parent.width;
                height: parent.height;
                text: \"×\";
                color: close-touch.pressed ? #f4f4f1 : #24282d;
                font-size: 18px;
                horizontal-alignment: center;
                vertical-alignment: center;
            }
            close-touch := TouchArea { clicked => { root.dismiss(); } }
        }
    }
}")

(defun %notifications-on-output (world output)
  (remove-if-not
   (lambda (widget)
     (and (typep widget 'agent-notification)
          (eq output (overlay-output widget))))
   (list-agent-widgets world)))

(defun %restack-notifications (world output)
  (let ((y 24d0))
    (dolist (widget (%notifications-on-output world output))
      (when (overlay-visible-p widget)
        (damage-overlay world widget)
        (setf (overlay-y widget) y)
        (incf y (+ (overlay-height widget) 12d0))
        (damage-overlay world widget)
        (request-overlay-update world widget))))
  world)

(defun show-notification
    (world message &key (title "NOTICE") output (duration 5d0))
  "Show a dismissible, optionally expiring notification on one output."
  (check-type message string)
  (check-type title string)
  (let* ((output (require-world-output world output))
         (width 360d0)
         (height 104d0))
    (multiple-value-bind (output-width output-height)
        (output-logical-size output)
      (declare (ignore output-height))
      (let ((widget
              (create-agent-widget
               'agent-notification world +notification-source+ :component-factory #'make-slint-component
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
           (let ((subject-output (overlay-output subject)))
             (remove-agent-widget world subject)
             (%restack-notifications world subject-output))))
        (%restack-notifications world output)
        (expire-agent-widget widget duration
                             (lambda () (%restack-notifications world output)))
        widget))))
