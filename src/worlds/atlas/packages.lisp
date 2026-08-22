;;;; Packed atlas World package.

(defpackage #:ataxia.atlas-world
  (:use #:cl)
  (:export
   #:atlas-world
   #:make-atlas-world
   #:run-atlas-compositor
   #:main
   #:atlas-object
   #:atlas-object-component
   #:atlas-object-width
   #:atlas-object-height
   #:find-atlas-object
   #:set-output-camera
   #:fit-output-camera))
