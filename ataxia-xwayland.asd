(asdf:defsystem "ataxia-xwayland"
  :description "Optional XWayland protocol adapter; placement belongs to the World"
  :depends-on ("ataxia-kernel" "ataxia-runtime/xwayland")
  :serial t
  :components ((:file "src/kernel/xwayland")))
