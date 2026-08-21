;;;; Ataxia compositor system definition.
;;;;
;;;; The compositor is the policy and presentation layer above Runtime. Its
;;;; components share one owner thread and communicate through direct CLOS calls.

(asdf:defsystem "ataxia-compositor"
  :description "Extensible Common Lisp Wayland compositor built on Ataxia Runtime"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("ataxia-runtime" "cffi")
  :serial t
  :components
  ((:module "src/compositor"
    :components
    ((:file "packages")
     (:file "conditions")
     (:file "core")
     (:file "hooks")
     (:file "model")
     (:file "policy")
     (:file "animation")
     (:file "graphics")
     (:file "presentation")
     (:file "behavior")
     (:file "spherical")
     (:file "interaction")
     (:file "control")
     (:file "compositor")
     (:file "main")))))
