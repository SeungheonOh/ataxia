;;;; Ataxia Layer 1 system definition.
;;;;
;;;; This system contains only the direct Common Lisp bindings, typed native
;;;; wrappers, callback barrier, and Lisp-owned Wayland runtime.

(asdf:defsystem "ataxia-layer1"
  :description "Direct Common Lisp wlroots and libwayland runtime for Ataxia"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("cffi")
  :serial t
  :components
  ((:module "src/layer1"
    :components
    ((:file "packages")
     (:file "conditions")
     (:file "raw")
     (:file "objects")
     (:file "listeners")
     (:file "runtime")
     (:file "main")))))

(asdf:defsystem "ataxia"
  :description "Ataxia compositor"
  :version "0.1.0"
  :depends-on ("ataxia-layer1"))
