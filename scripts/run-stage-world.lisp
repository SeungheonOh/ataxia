#!/usr/bin/env -S sbcl --script
;;;; Run the Ataxia compositor with Stage World; arguments go to its command line.
(load (merge-pathnames "bootstrap.lisp" *load-truename*))
(asdf:load-system "ataxia-stage-world")
(uiop:quit (ataxia.stage-world:main))
