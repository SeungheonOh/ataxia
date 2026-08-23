#!/usr/bin/env -S sbcl --script

(require :asdf)

(let* ((script-directory
         (uiop:pathname-directory-pathname *load-truename*))
       (root (uiop:pathname-parent-directory-pathname script-directory))
       (dependencies
         (uiop:ensure-directory-pathname
          (or (uiop:getenv "ATAXIA_LISP_DEPS")
              (merge-pathnames
               "common-lisp/"
               (uiop:ensure-directory-pathname
                (or (uiop:getenv "ATAXIA_DEPS")
                    (merge-pathnames "fun/ataxia-deps/"
                                     (user-homedir-pathname)))))))))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,root) (:tree ,dependencies)
     :inherit-configuration))
  (dolist (system '("ataxia-runtime.asd" "ataxia-kernel.asd"
                    "ataxia-fullscreen-world.asd"))
    (asdf:load-asd (merge-pathnames system root)))
  (asdf:load-system "ataxia-fullscreen-world"))

(uiop:quit (ataxia.fullscreen-world:main))
