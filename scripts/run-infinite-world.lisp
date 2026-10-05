#!/usr/bin/env -S sbcl --script
;;;; Run the Ataxia compositor with Infinite World; arguments go to its command line.
(load (merge-pathnames "bootstrap.lisp" *load-truename*))
(asdf:load-system "ataxia-infinite-world")
(uiop:quit (ataxia.infinite-world:main))
