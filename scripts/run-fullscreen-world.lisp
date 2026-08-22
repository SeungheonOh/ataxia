#!/usr/bin/env -S sbcl --script

(require :asdf)

(let* ((script-directory
         (uiop:pathname-directory-pathname *load-truename*))
       (root (uiop:pathname-parent-directory-pathname script-directory)))
  (asdf:load-asd (merge-pathnames "ataxia-runtime.asd" root))
  (asdf:load-asd (merge-pathnames "ataxia-kernel.asd" root))
  (asdf:load-asd (merge-pathnames "ataxia-fullscreen-world.asd" root))
  (asdf:load-system "ataxia-fullscreen-world"))

(uiop:quit (ataxia.fullscreen-world:main))
