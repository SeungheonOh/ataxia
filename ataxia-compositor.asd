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
  ((:module "compositor-foundation"
    :pathname "src/compositor"
    :components
    ((:file "packages")
     (:file "conditions")
     (:file "core")
     (:file "hooks")
     (:file "model")
     (:file "behavior-protocol")))
   (:module "behavior-base-implementation"
    :pathname "src/behavior"
    :components
    ((:file "standard-policy")))
   (:module "compositor-presentation"
   :pathname "src/compositor"
   :components
    ((:file "animation")
     (:file "graphics")
     (:file "presentation")))
   (:module "compositor-interaction"
    :pathname "src/compositor"
    :components
    ((:file "interaction")))
   (:module "behavior-implementations"
    :pathname "src/behavior"
    :components
    ((:file "effects")
     (:file "reveal")
     (:file "animation")
     (:file "interaction")
     (:file "scene")
     (:file "planar")
     (:file "spherical")))
   (:module "compositor-services"
   :pathname "src/compositor"
   :components
    ((:file "control")
     (:file "control-transport")
     (:file "compositor")
     (:file "main")))))
