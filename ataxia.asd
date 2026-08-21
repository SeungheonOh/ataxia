;;;; Ataxia aggregate system definition.
;;;;
;;;; This system is the stable project entrypoint. Concrete architectural
;;;; layers retain separate system definitions and dependency boundaries.

(asdf:defsystem "ataxia"
  :description "Ataxia compositor"
  :version "0.1.0"
  :depends-on ("ataxia-runtime"))
