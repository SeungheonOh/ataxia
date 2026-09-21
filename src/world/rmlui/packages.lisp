;;;; RmlUi World-component package boundaries.
;;;;
;;;; The public package exposes native objects that implement Kernel's generic
;;;; drawable and interactable contracts. Kernel has no RmlUi specialization.

(defpackage #:ataxia.world.rmlui.raw
  (:use #:cl #:cffi))

(defpackage #:ataxia.world.rmlui
  (:use #:cl #:ataxia.world)
  (:export
   #:call-with-preserved-graphics-state
   #:rmlui-widget #:widget-cache #:cache-widget-value #:set-widget-text #:set-widget-style #:short-ui-text
   #:rmlui-component
   #:make-rmlui-widget
   #:make-rmlui-component
   #:make-shell-rmlui-component #:ensure-shell-fonts
   #:destroy-rmlui-component
   #:rmlui-component-width
   #:rmlui-component-height
   #:rmlui-component-scale
   #:resize-rmlui-component
   #:set-rmlui-component-invalidator
   #:rmlui-component-graphics-attached-p
   #:attach-rmlui-component-graphics
   #:detach-rmlui-component-graphics
   #:render-rmlui-component
   #:rmlui-component-active-p
   #:set-rmlui-property
   #:set-rmlui-callback
   #:remove-rmlui-callback
   #:poll-rmlui-callbacks
   #:set-rmlui-model
   #:rmlui-model-value
   #:load-rmlui-font
   #:set-rmlui-class
   #:set-rmlui-style
   #:set-rmlui-attribute
   #:reload-rmlui-component))
