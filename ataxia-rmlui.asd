;;;; Optional World-owned HTML/CSS UI engine.
(asdf:defsystem "ataxia-rmlui"
  :description "RmlUi native components for Ataxia Worlds"
  :version "0.1.0"
  :depends-on ("ataxia-world" "cffi")
  :serial t
  :components ((:module "src/world/rmlui"
                :components ((:file "packages") (:file "native") (:file "component")
                             (:file "render") (:file "input") (:file "ui")))))
(asdf:defsystem "ataxia-rmlui/infinite"
  :description "RmlUi widgets in Infinite World and Metaworld"
  :depends-on ("ataxia-rmlui" "ataxia-infinite-world")
  :components ((:file "src/world/rmlui/infinite")))
