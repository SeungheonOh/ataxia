(asdf:defsystem "ataxia-computer-use"
  :description "Visible, user-controlled computer-use sessions for any desktop World"
  :depends-on ("ataxia-world/synthetic-input" "ataxia-rmlui" "ataxia-sly-control" "sb-bsd-sockets")
  :serial t
  :components ((:module "src/world/computer-use"
                :serial t
                :components ((:file "packages") (:file "native") (:file "json") (:file "sessions") (:file "view") (:file "input") (:file "ui")
                             (:file "capture") (:file "api") (:file "batch") (:file "desktop")
                             (:file "server") (:file "service")))))

(asdf:defsystem "ataxia-computer-use/infinite-world"
  :description "Infinite World rendering backend for portable computer use"
  :depends-on ("ataxia-computer-use" "ataxia-infinite-world/capture"))

(asdf:defsystem "ataxia-computer-use/metaworld"
  :description "Computer use with Metaworld's desktop, layout and navigation policy"
  :depends-on ("ataxia-computer-use/infinite-world" "ataxia-metaworld"))
