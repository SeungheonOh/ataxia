;;;; SLY control-plane system definition.

(asdf:defsystem "ataxia-sly-control"
  :description "Local SLYNK control plane for a live Ataxia Kernel"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("ataxia-kernel" "slynk" "cffi" "sb-posix")
  :serial t
  :components
  ((:module "src/control"
    :components
    ((:file "packages")
     (:file "sly")))))
