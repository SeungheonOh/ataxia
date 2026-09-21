;;;; Ataxia Kernel system definition.
;;;;
;;;; Kernel contains only stable Wayland objects, the World boundary, Runtime
;;;; event handling, protocol mutation, seats, outputs, and frame transactions.

(asdf:defsystem "ataxia-kernel"
  :description "Minimal Common Lisp compositor Kernel above Ataxia Runtime"
  :version "0.1.0"
  :author "Ataxia contributors"
  :license "Unspecified"
  :depends-on ("ataxia-runtime" "cffi")
  :serial t
  :components
  ((:module "src/kernel"
    :components
    ((:file "packages")
     (:file "object-protocols")
     (:file "world-protocol")
     (:file "frames")
     (:file "objects")
     (:file "kernel")
     (:file "clients")
     (:file "world-watchdog")
     (:file "seats")
     (:file "wayland-objects")
     (:file "outputs")
     (:file "runtime-sink")
     (:file "drag")
     (:file "gestures")))))
