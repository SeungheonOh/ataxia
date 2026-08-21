;;;; Standalone SBCL launcher for Ataxia Runtime.
;;;;
;;;; This module configures the local ASDF source trees, loads the Runtime
;;;; system, forwards command-line arguments, and exits with its status code.

(require :asdf)

(let* ((script-directory
         (uiop:pathname-directory-pathname *load-truename*))
       (repository-root
         (uiop:pathname-parent-directory-pathname script-directory))
       (dependency-root
         (uiop:ensure-directory-pathname
          (or (uiop:getenv "ATAXIA_LISP_DEPS")
              (merge-pathnames "common-lisp/"
                               (uiop:ensure-directory-pathname
                                (or (uiop:getenv "ATAXIA_DEPS")
                                    (merge-pathnames "ataxia-deps/"
                                                     (user-homedir-pathname)))))))))
  (asdf:initialize-source-registry
   `(:source-registry
     (:tree ,repository-root)
     (:tree ,dependency-root)
     :inherit-configuration))
  (asdf:load-system "ataxia-runtime")
  (uiop:quit
   (uiop:symbol-call
    :ataxia.runtime :main (uiop:command-line-arguments))))
