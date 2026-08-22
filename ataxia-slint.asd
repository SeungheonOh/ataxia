;;;; World-owned Slint component system definition.

(asdf:defsystem "ataxia-slint"
  :description "Slint native-component engine for Ataxia Worlds"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("ataxia-world" "cffi-libffi")
  :serial t
  :components
  ((:module "src/world/slint"
    :components
    ((:file "packages")
     (:file "native")
     (:file "component")
     (:file "render")
     (:file "input")))))
