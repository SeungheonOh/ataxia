(asdf:defsystem "ataxia-xwayland"
  :description "Optional XWayland protocol adapter; placement belongs to the World"
  :depends-on ("ataxia-kernel")
  :serial t
  :components ((:file "src/kernel/xwayland")))
