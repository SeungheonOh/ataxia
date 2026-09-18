;;;; Run against either native build, including one without compiled World UI.
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-slint")
(assert (not (find-package :ataxia.infinite-world)))

(let ((component
        (ataxia.world.slint:make-slint-component
         :source "export component Prompt inherits Window {
                    in property <string> caption;
                    callback answer(string);
                    Text { text: root.caption; }
                  }"
         :source-path "portable-prompt.slint" :width 200d0 :height 100d0)))
  (unwind-protect
       (progn
         (ataxia.world.slint:set-slint-property component "caption" "Choose a World")
         (ataxia.world.slint:set-slint-callback
          component "answer" (lambda (subject value) (declare (ignore subject value))))
         (ataxia.world:ui-resize component 240d0 120d0 :scale 1d0)
         (assert (handler-case
                     (progn (ataxia.world.slint:set-slint-property component "unknown" t) nil)
                   (error () t)))
         (ataxia.world.slint:remove-slint-callback component "answer"))
    (ataxia.world:ui-destroy component)))

(format t "PASS: native Slint components work without loading a concrete World.~%")
