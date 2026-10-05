;;;; Shared launcher setup: find Ataxia's systems in this checkout and its Lisp
;;;; dependencies in ATAXIA_LISP_DEPS, or common-lisp/ under ATAXIA_DEPS
;;;; (~/fun/ataxia-deps by default).
(require :asdf)
(let* ((root (uiop:pathname-parent-directory-pathname
              (uiop:pathname-directory-pathname *load-truename*)))
       (dependencies
         (uiop:ensure-directory-pathname
          (or (uiop:getenv "ATAXIA_LISP_DEPS")
              (merge-pathnames "common-lisp/"
                               (uiop:ensure-directory-pathname
                                (or (uiop:getenv "ATAXIA_DEPS")
                                    (merge-pathnames "fun/ataxia-deps/"
                                                     (user-homedir-pathname)))))))))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,root) (:tree ,dependencies) :inherit-configuration)))
