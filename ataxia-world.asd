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
    ((:file "wire")
     (:file "packages")
     (:file "command-line")
     (:file "ui")
     (:file "geometry")
     (:file "application")
     (:file "agent-events")
     (:file "overlays")
     (:file "widgets")
     (:file "desktop")
     (:file "services")
     (:file "shortcuts")
     (:file "animation")
     (:file "damage")
     (:file "gles")
     (:file "rescue")))))

(asdf:defsystem "ataxia-world/synthetic-input"
  :description "Optional World-owned native input devices"
  :depends-on ("ataxia-world")
  :serial t
  :components ((:module "src/world/synthetic-input"
                :serial t
                :components ((:file "packages") (:file "input")))))
