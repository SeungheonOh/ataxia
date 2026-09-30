;;;; Reusable shell controllers, independent of the selected UI renderer.
(asdf:defsystem "ataxia-shell"
  :description "World-owned status bar, menus and system control services"
  :depends-on ("ataxia-world")
  :serial t
  :components ((:module "src/world/shell" :components
                ((:file "packages") (:file "presentation")
                 (:file "status-bar")
                 (:file "controls")
                 (:file "audio")
                 (:file "media")
                 (:file "power")
                 (:file "brightness")
                 (:file "power-control")
                 (:file "menu")
                 (:file "workspaces")
                 (:file "power-ui")
                 (:file "clipboard")
                 (:file "controls-ui")
))))
