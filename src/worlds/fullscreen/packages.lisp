;;;; Fullscreen World package boundary.
;;;;
;;;; This package owns a minimal compositor policy and its direct GLES drawing
;;;; implementation. It depends only on the public Kernel/World contract.

(defpackage #:ataxia.fullscreen-world
  (:use #:cl)
  (:export
   #:fullscreen-world
   #:make-fullscreen-world
   #:run-fullscreen-compositor
   #:main))
