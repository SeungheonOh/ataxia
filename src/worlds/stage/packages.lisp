;;;; Stage World package boundary.
;;;;
;;;; Stage presents a retained scene graph declared by an external director
;;;; process, normally the @ataxia/stage TypeScript runtime. Kernel sees one
;;;; ordinary World; the director only exchanges copied scene and event values
;;;; over a local socket and never addresses Kernel objects.

(defpackage #:ataxia.stage-world
  (:use #:cl)
  (:export
   #:stage-world
   #:make-stage-world
   #:stage-director-socket
   #:stage-director-connected-p
   #:stage-scene-description
   #:default-director-socket
   #:run-stage-compositor
   #:main))
