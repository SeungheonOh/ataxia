;;;; Master-stack tiling World system definition.

(asdf:defsystem "ataxia-tiling-world"
  :description "Master-stack tiling World for the Ataxia Kernel"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("ataxia-world" "ataxia-sly-control" "cffi")
  :serial t
  :components
  ((:module "src/worlds/tiling"
    :serial t
    :components
    ((:file "packages")
     (:file "model")
     (:file "layout")
     (:file "renderer")
     (:file "world")
     (:file "main")))))
