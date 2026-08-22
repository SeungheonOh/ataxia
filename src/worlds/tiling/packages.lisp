;;;; Tiling World package.

(defpackage #:ataxia.tiling-world
  (:use #:cl)
  (:export
   #:tiling-world
   #:make-tiling-world
   #:run-tiling-compositor
   #:main
   #:tile-node
   #:tile-node-component
   #:find-tile-node))
