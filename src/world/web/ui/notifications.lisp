(in-package #:ataxia.world.web.ui)
(defclass agent-notification (document-widget) ())
(defun %notifications-on-output (world output)
  (remove-if-not
   (lambda (widget)
     (and (typep widget 'agent-notification)
          (eq output (ataxia.world:overlay-output widget))))
   (ataxia.world:list-agent-widgets world)))

(defun %restack-notifications (world output)
  (let ((y 24d0))
    (dolist (widget (%notifications-on-output world output))
      (when (ataxia.world:overlay-visible-p widget)
        (ataxia.world:damage-overlay world widget)
        (setf (ataxia.world:overlay-y widget) y)
        (incf y (+ (ataxia.world:overlay-height widget) 12d0))
        (ataxia.world:damage-overlay world widget)
        (ataxia.world:request-overlay-update world widget))))
  world)

(defun show-notification
    (world message &key (title "NOTICE") output (duration 5d0))
  "Show a dismissible, optionally expiring notification on one output."
  (check-type message string)
  (check-type title string)
  (let* ((output (ataxia.world:require-world-output world output))
         (width 360d0)
         (height 104d0))
    (multiple-value-bind (output-width output-height)
        (ataxia.world:output-logical-size output)
      (declare (ignore output-height))
      (let ((widget
              (ataxia.world:create-agent-widget
               'agent-notification world ""
               :component-factory (lambda (&rest args) (apply #'make-ui-component :world world args))
               :source-path (namestring (asdf:system-relative-pathname "ataxia-web" "src/world/web/ui/notification.html"))
               :output output :x (max 24d0 (- output-width width 24d0))
               :y 24d0 :width width :height height :layer 1200)))
        (ataxia.world:set-agent-widget-property widget "heading" title)
        (ataxia.world:set-agent-widget-property widget "message" message)
        (ataxia.world:bind-agent-widget-event
         widget "dismiss"
         (lambda (subject event)
           (declare (ignore event))
           (let ((subject-output (ataxia.world:overlay-output subject)))
             (ataxia.world:remove-agent-widget world subject)
             (%restack-notifications world subject-output))))
        (%restack-notifications world output)
        (ataxia.world:expire-agent-widget widget duration
                             (lambda () (%restack-notifications world output)))
        widget))))
