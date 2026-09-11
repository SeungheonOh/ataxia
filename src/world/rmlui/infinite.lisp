(in-package #:ataxia.world.rmlui)

(defun make-rmlui-widget (world source &rest options)
  "Create an RML widget alongside existing Slint widgets in WORLD."
  (apply #'ataxia.infinite-world::%create-agent-widget
         'ataxia.infinite-world:agent-widget world source
         :component-factory #'make-rmlui-component
         (append options (unless (getf options :source-path)
                           (list :source-path "ataxia-widget.rml")))))
