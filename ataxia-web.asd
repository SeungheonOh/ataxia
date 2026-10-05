;;;; Optional browser UI adapter; no dependency from Kernel or concrete Worlds.
(asdf:defsystem "ataxia-web"
  :description "Chromium HTML/CSS/JavaScript drawable and interactable components"
  :version "0.1.0"
  :depends-on ("ataxia-world" "cffi")
  :serial t
  :components ((:module "src/world/web"
                :components ((:file "packages") (:file "native") (:file "component")
                             (:file "render") (:file "input") (:file "widgets")))))

(asdf:defsystem "ataxia-web/ui"
  :description "Reusable HTML document models, events and cached presentation"
  :depends-on ("ataxia-web")
  :serial t
  :components ((:file "src/world/web/ui/document") (:file "src/world/web/ui/notifications")))

(asdf:defsystem "ataxia-web/status-bar"
  :description "HTML/CSS presentation for the shared World shell"
  :depends-on ("ataxia-web/ui" "ataxia-shell")
  :components ((:file "src/world/web/status-bar/presentation")))
