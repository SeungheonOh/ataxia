;;;; Standalone SBCL launcher for Ataxia Compositor.
;;;;
;;;; This file configures local ASDF trees, loads Layer 2, and forwards command
;;;; line arguments without embedding compositor policy in the shell wrapper.

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
  (asdf:load-system "ataxia-compositor")
  (uiop:quit
   (uiop:symbol-call
    :ataxia.compositor :main (uiop:command-line-arguments))))
