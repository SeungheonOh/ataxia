(asdf:defsystem "ataxia-metaworld"
  :description "Canvas subworlds with scrolling-column and dynamic tiling policies"
  :version "0.1.0"
  :depends-on ("ataxia-infinite-world")
  :serial t
  :components
  ((:module "src/worlds/metaworld"
    :serial t
    :components
    ((:file "model")
     (:file "renderer")
     (:file "layout")
     (:file "persistence")
     (:file "ui")
     (:file "world")
     (:file "main")))))
