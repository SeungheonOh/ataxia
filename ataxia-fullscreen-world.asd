;;;; Fullscreen World system definition.

(asdf:defsystem "ataxia-fullscreen-world"
  :description "Single-client fullscreen World for the Ataxia Kernel"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("ataxia-world" "cffi")
  :serial t
  :components
  ((:module "src/worlds/fullscreen"
    :components
    ((:file "packages")
     (:file "renderer")
     (:file "world")
     (:file "main")))))
