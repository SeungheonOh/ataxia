;;;; Stage World system definition.

(asdf:defsystem "ataxia-stage-world"
  :description "World presenting a scene graph declared by a TypeScript director"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("ataxia-world" "ataxia-web" "ataxia-xwayland" "ataxia-sly-control" "cffi"
               "sb-bsd-sockets" "sb-posix")
  :serial t
  :components
  ((:module "src/worlds/stage"
    :serial t
    :components
    ((:file "packages")
     (:file "motion")
     (:file "affine")
     (:file "model")
     (:file "scene")
     (:file "world")
     (:file "camera")
     (:file "gl")
     (:file "media")
     (:file "renderer")
     (:file "display")
     (:file "content")
     (:file "web")
     (:file "link")
     (:file "clipboard")
     (:file "manipulation")
     (:file "input")
     (:file "desktop")
     (:file "applications")
     (:file "main")))))
