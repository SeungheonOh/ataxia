#!/usr/bin/env -S sbcl --script
;;;; Run the Ataxia compositor with Metaworld; arguments go to its command line.
(load (merge-pathnames "bootstrap.lisp" *load-truename*))
(asdf:load-system "ataxia-metaworld")
(uiop:quit (ataxia.metaworld:metaworld-main))
