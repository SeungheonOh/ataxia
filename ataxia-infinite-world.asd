;;;; Infinite canvas World system definition.

(asdf:defsystem "ataxia-infinite-world"
  :description "Animated infinite-canvas World for the Ataxia Kernel"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("ataxia-world" "ataxia-slint" "ataxia-sly-control" "cffi")
  :serial t
  :components
  ((:module "src/worlds/infinite"
    :components
    ((:file "packages")
     (:file "model")
     (:file "renderer")
     (:file "world")
     (:file "view-shift")
     (:file "agent-ui")
     (:file "launcher")
     (:file "main")))))
