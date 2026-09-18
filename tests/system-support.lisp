;;;; Shared system loading for standalone regression scripts.
(require :asdf)
(let* ((root (uiop:pathname-parent-directory-pathname
              (uiop:pathname-directory-pathname *load-truename*)))
       (dependencies (or (uiop:getenv "ATAXIA_LISP_DEPS")
                         (merge-pathnames "common-lisp/"
                                          (uiop:ensure-directory-pathname
                                           (or (uiop:getenv "ATAXIA_DEPS")
                                               (merge-pathnames "fun/ataxia-deps/" (user-homedir-pathname))))))))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,root) (:tree ,dependencies) :inherit-configuration)))
