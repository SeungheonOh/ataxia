;;;; Infinite canvas World system definition.

(asdf:defsystem "ataxia-infinite-world"
  :description "Animated infinite-canvas World for the Ataxia Kernel"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on
  ("ataxia-world" "ataxia-slint" "ataxia-sly-control" "cffi")
  :serial t
  :components
  ((:module "src/worlds/infinite"
    :components
    ((:file "packages")
     (:file "ui-compat")
     (:file "model")
     (:file "occlusion")
     (:file "renderer")
     (:file "resolution")
     (:file "world")
     (:file "outputs")
     (:file "view-shift")
     (:file "gestures")
     (:file "agent-ui")
     (:file "services")
     (:file "launcher")
     (:file "desktop")
     (:file "viewport")
     (:file "main")))))

(asdf:defsystem "ataxia-infinite-world/capture"
  :description "Offscreen application and fixed canvas-region capture"
  :depends-on ("ataxia-infinite-world" "ataxia-rmlui")
  :components ((:file "src/worlds/infinite/capture")))
