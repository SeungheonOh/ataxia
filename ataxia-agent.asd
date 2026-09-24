(asdf:defsystem "ataxia-agent"
  :description "Direct Lisp application input and capture for desktop Worlds"
  :depends-on ("ataxia-computer-use")
  :serial t
  :components ((:file "src/world/agent")))
