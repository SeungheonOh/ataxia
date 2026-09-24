(asdf:defsystem "ataxia-assistant"
  :description "World-owned Codex assistant, native desktop tools and optional talk mode"
  :version "0.1.0"
  :depends-on ("ataxia-computer-use" "ataxia-rmlui/status-bar")
  :serial t
  :components ((:module "src/world/assistant"
                :serial t
                :components ((:file "packages") (:static-file "instructions.md")
                             (:file "model") (:file "models") (:file "protocol") (:file "worker") (:file "layout")
                             (:file "tools") (:file "lisp") (:file "windows") (:file "preview") (:file "voice")
                             (:file "format") (:file "ui") (:file "lifecycle")
                             (:file "service")))))

(asdf:defsystem "ataxia-assistant/infinite-world"
  :description "Attach the portable assistant to Infinite World's desktop backend"
  :depends-on ("ataxia-assistant" "ataxia-computer-use/infinite-world"))
(asdf:defsystem "ataxia-assistant/metaworld"
  :description "Portable assistant with Metaworld layout and navigation capabilities"
  :depends-on ("ataxia-assistant" "ataxia-computer-use/metaworld"))
