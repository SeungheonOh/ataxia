#!/usr/bin/env -S sbcl --script

(require :asdf)

(let* ((scripts (uiop:pathname-directory-pathname *load-truename*))
       (root (uiop:pathname-parent-directory-pathname scripts))
       (dependencies
         (uiop:ensure-directory-pathname
          (or (uiop:getenv "ATAXIA_LISP_DEPS")
              (merge-pathnames "common-lisp/"
                               (uiop:ensure-directory-pathname
                                (or (uiop:getenv "ATAXIA_DEPS")
                                    (merge-pathnames "ataxia-deps/"
                                                     (user-homedir-pathname)))))))))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,root) (:tree ,dependencies)
     :inherit-configuration))
  (dolist (system '("ataxia-runtime.asd" "ataxia-kernel.asd"
                    "ataxia-world.asd" "ataxia-sly-control.asd"
                    "ataxia-atlas-world.asd"))
    (asdf:load-asd (merge-pathnames system root)))
  (asdf:load-system "ataxia-atlas-world"))

(uiop:quit (ataxia.atlas-world:main))
