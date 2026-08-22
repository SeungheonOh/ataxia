;;;; Infinite canvas World package.

(defpackage #:ataxia.infinite-world
  (:use #:cl)
  (:export
   #:infinite-world
   #:make-infinite-world
   #:run-infinite-compositor
   #:main
   #:canvas-window
   #:canvas-window-application
   #:canvas-window-x
   #:canvas-window-y
   #:canvas-window-width
   #:canvas-window-height
   #:canvas-window-opacity
   #:canvas-window-scale
   #:canvas-window-elevation
   #:canvas-window-effect
   #:canvas-window-animation-hooks
   #:find-canvas-window
   #:set-window-animation-hook
   #:remove-window-animation-hook
   #:run-window-animation-hook
   #:animate-window
   #:set-output-camera
   #:pan-output-camera
   #:zoom-output-camera))
