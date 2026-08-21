;;;; Ataxia Runtime system definition.
;;;;
;;;; This system contains only direct Common Lisp bindings, typed native
;;;; wrappers, callback containment, and the Lisp-owned Wayland runtime.

(asdf:defsystem "ataxia-runtime"
  :description "Direct Common Lisp wlroots and libwayland runtime for Ataxia"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("cffi")
  :serial t
  :components
  ((:module "src/runtime"
    :components
    ((:file "packages")
     (:file "conditions")
     (:file "raw")
     (:file "objects")
     (:file "listeners")
     (:file "runtime")
     (:file "event-loop")
     (:file "subsurface")
     (:file "input")
     (:file "render")
     (:file "output")
     (:file "presentation-protocols")
     (:file "xdg-shell")
     (:file "desktop-shell-protocols")
     (:file "main")))))
