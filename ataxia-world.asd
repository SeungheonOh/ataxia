;;;; Reusable World implementation support.

(asdf:defsystem "ataxia-world"
  :description "Small reusable mechanisms for Ataxia World implementations"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("ataxia-kernel" "cffi")
  :serial t
  :components
  ((:module "src/world"
    :components
    ((:file "packages")
     (:file "geometry")
     (:file "application")
     (:file "animation")
     (:file "damage")
     (:file "gles")))))
