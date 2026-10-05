;;;; Standalone SBCL launcher for Ataxia Runtime: load it, forward the
;;;; command-line arguments and exit with its status code.
(load (merge-pathnames "bootstrap.lisp" *load-truename*))
(asdf:load-system "ataxia-runtime")
(uiop:quit (uiop:symbol-call :ataxia.runtime :main (uiop:command-line-arguments)))
