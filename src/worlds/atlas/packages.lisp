;;;; Packed atlas World package.

(defpackage #:ataxia.atlas-world
  (:use #:cl)
  (:export
   #:atlas-world
   #:make-atlas-world
   #:run-atlas-compositor
   #:main
   #:atlas-window
   #:atlas-window-application
   #:atlas-window-width
   #:atlas-window-height
   #:find-atlas-window
   #:set-output-camera
   #:fit-output-camera))
