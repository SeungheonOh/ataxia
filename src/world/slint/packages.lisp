;;;; Slint World-component package boundaries.
;;;;
;;;; The public package exposes native objects that implement Kernel's generic
;;;; drawable and interactable contracts. Kernel has no Slint specialization.

(defpackage #:ataxia.world.slint.raw
  (:use #:cl #:cffi))

(defpackage #:ataxia.world.slint
  (:use #:cl)
  (:export
   #:slint-component
   #:make-slint-component
   #:destroy-slint-component
   #:slint-component-width
   #:slint-component-height
   #:slint-component-scale
   #:resize-slint-component
   #:set-slint-component-invalidator
   #:slint-component-graphics-attached-p
   #:attach-slint-component-graphics
   #:detach-slint-component-graphics
   #:render-slint-component
   #:slint-component-active-p
   #:slint-component-pointer-exit
   #:set-slint-property
   #:update-slint-timers
   #:slint-next-timer-milliseconds))
