;;;; Load ataxia-rmlui, then call SHOW-RMLUI-DEMO on a UI host's owner thread.
(in-package #:ataxia.world.rmlui)

(defun show-rmlui-demo (world &key (x 64d0) (y 100d0))
  (let* ((path (asdf:system-relative-pathname "ataxia-rmlui" "examples/rmlui-panel.rml"))
         (widget (make-rmlui-widget world (uiop:read-file-string path)
                                   :source-path (namestring path)
                                   :x x :y y :width 570d0 :height 395d0))
         (component (ataxia.world:overlay-component widget))
         (alternate nil))
    (ataxia.world:bind-agent-widget-event
     widget "theme"
     (lambda (subject event)
       (declare (ignore subject event))
       (setf alternate (not alternate))
       (set-rmlui-style component "" "--accent" (if alternate "#a9bbff" "#85e6bd"))
       (set-rmlui-property component "status" "Theme updated from Lisp.")))
    (ataxia.world:bind-agent-widget-event
     widget "animate"
     (lambda (subject event)
       (declare (ignore subject event))
       (set-rmlui-class component "status" "pulse" t)))
    (ataxia.world:bind-agent-widget-event
     widget "status:animationend"
     (lambda (subject event)
       (declare (ignore subject event))
       (set-rmlui-class component "status" "pulse" nil)))
    (ataxia.world:bind-agent-widget-event
     widget "close"
     (lambda (subject event)
       (declare (ignore event))
       (ataxia.world:remove-agent-widget world subject)))
    widget))
