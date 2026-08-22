;;;; Packed atlas World system definition.

(asdf:defsystem "ataxia-atlas-world"
  :description "Coordinate-free packed-plane World for the Ataxia Kernel"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("ataxia-world" "ataxia-slint" "ataxia-sly-control" "cffi")
  :serial t
  :components
  ((:module "src/worlds/atlas"
    :components
    ((:file "packages")
     (:file "model")
     (:file "packing")
     (:file "renderer")
     (:file "slint")
     (:file "world")
     (:file "main")))))
