;;;; Native document and mixed toolkit contract checks, without a graphics context.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-rmlui/infinite")
(let* ((source "<rml><head><style>body { --accent: #ee8844; }</style></head><body><div id='text'>Initial</div><button id='apply'>Apply</button></body></rml>")
       (component (ataxia.world.rmlui:make-rmlui-component :source source :width 320 :height 180))
       (slint (ataxia.world.slint:make-slint-component
               :source "export component Test inherits Window { in property <string> text; callback apply(); }"
               :width 320 :height 180))
       (changes 0))
  (unwind-protect
       (progn
         (dolist (ui (list component slint))
           (assert (typep ui 'ataxia.kernel:drawable))
           (assert (typep ui 'ataxia.kernel:interactable))
           (ataxia.world:ui-set-invalidator ui (lambda (c) (declare (ignore c)) (incf changes)))
           (ataxia.world:ui-set-property ui "text" "A < B & C")
           (ataxia.world:ui-set-callback ui "apply" (lambda (&rest args) (declare (ignore args))))
           (ataxia.world:ui-resize ui 480 260 :scale 1.5d0)
           (assert (= (ataxia.world:ui-raster-scale ui) 1.5d0))
           (assert (= (nth-value 2 (ataxia.kernel:drawable-local-bounds ui)) 480d0)))
         (assert (= changes 4))
         (ataxia.world.rmlui:set-rmlui-class component "text" "muted" t)
         (ataxia.world.rmlui:set-rmlui-style component "" "--accent" "#55bbdd")
         (ataxia.world.rmlui:set-rmlui-model component "title" "Persistent model")
         (ataxia.world.rmlui:set-rmlui-model component "count" 7)
         (ataxia.world.rmlui:set-rmlui-model component "enabled" t)
         (ataxia.world.rmlui:reload-rmlui-component component source)
         (assert (equal (ataxia.world.rmlui:rmlui-model-value component "title") "Persistent model"))
         (assert (handler-case
                     (progn (ataxia.world.rmlui:reload-rmlui-component
                             component "<rml><head/><body><div/></body></rml>") nil)
                   (error () t)))
         (ataxia.world:ui-set-property component "text" "Old document survived")
         (assert (handler-case
                     (progn (ataxia.world:ui-set-property component "missing" "value") nil)
                   (error () t)))
         (let* ((world (ataxia.metaworld:make-metaworld :state-file nil))
                (widget (make-instance 'ataxia.infinite-world:agent-widget
                                      :id 1 :world world :component component :output nil
                                      :x 0d0 :y 0d0 :width 480d0 :height 260d0))
                (ataxia.infinite-world::*meta-layout-motion* nil))
           (ataxia.infinite-world::%meta-place world widget 10d0 20d0 420d0 220d0)
           (assert (= (ataxia.world.rmlui:rmlui-component-width component) 420d0))
           (assert (= (ataxia.world.rmlui:rmlui-component-height component) 220d0)))
         (format t "PASS: Slint and RmlUi share lifecycle, sizing, invalidation, property/event contracts; RML edits and failed reload preserve a usable component.~%"))
    (ataxia.world:ui-destroy component)
    (ataxia.world:ui-destroy slint)))
