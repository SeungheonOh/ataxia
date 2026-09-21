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
  :description "Portable RmlUi status bar and application menu"
  :depends-on ("ataxia-rmlui")
  :serial t
  :components ((:file "src/world/rmlui/status-bar/packages")
               (:file "src/world/rmlui/status-bar/status-bar")
               (:file "src/world/rmlui/status-bar/controls")
               (:file "src/world/rmlui/status-bar/audio")
               (:file "src/world/rmlui/status-bar/media")
               (:file "src/world/rmlui/status-bar/power")
               (:file "src/world/rmlui/status-bar/brightness")
               (:file "src/world/rmlui/status-bar/power-control")
               (:file "src/world/rmlui/status-bar/menu")
               (:file "src/world/rmlui/status-bar/workspaces")
               (:file "src/world/rmlui/status-bar/power-ui")
               (:file "src/world/rmlui/status-bar/clipboard")
               (:file "src/world/rmlui/status-bar/controls-ui")))

(asdf:defsystem "ataxia-rmlui/status-bar/infinite-world"
  :description "Compatibility names for Infinite World shell callers"
  :depends-on ("ataxia-rmlui/status-bar" "ataxia-infinite-world")
  :components ((:file "src/worlds/infinite/shell-compat")))
