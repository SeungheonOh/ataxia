;;;; Optional World-owned HTML/CSS UI engine.
(asdf:defsystem "ataxia-rmlui"
  :description "RmlUi native components for Ataxia Worlds"
  :version "0.1.0"
  :depends-on ("ataxia-world" "cffi")
  :serial t
  :components ((:module "src/world/rmlui"
                :components ((:file "packages") (:file "native") (:file "component") (:file "theme")
                             (:static-file "theme.rcss")
                             (:file "render") (:file "input") (:file "ui") (:file "widgets") (:file "widget-cache")))))
(asdf:defsystem "ataxia-rmlui/infinite"
  :description "RmlUi widgets in Infinite World and Metaworld"
  :depends-on ("ataxia-rmlui" "ataxia-infinite-world")
  :components ())

(asdf:defsystem "ataxia-rmlui/status-bar"
  :description "RmlUi presentation for the shared World shell"
  :depends-on ("ataxia-rmlui" "ataxia-shell")
  :components ((:file "src/world/rmlui/status-bar/presentation")))

(asdf:defsystem "ataxia-rmlui/status-bar/infinite-world"
  :description "Compatibility names for Infinite World shell callers"
  :depends-on ("ataxia-rmlui/status-bar" "ataxia-infinite-world")
  :components ((:file "src/worlds/infinite/shell-compat")))
