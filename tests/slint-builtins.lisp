;;;; Run: sbcl --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/slint-builtins.lisp
(require :asdf)
(let ((root (uiop:pathname-parent-directory-pathname
             (uiop:pathname-directory-pathname *load-truename*))))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,root)
     (:tree ,(merge-pathnames "fun/ataxia-deps/common-lisp/" (user-homedir-pathname)))
     :inherit-configuration))
  (asdf:load-system "ataxia-metaworld"))
(in-package #:ataxia.infinite-world)

(defun check-component (path source properties callbacks)
  (let ((component (ataxia.world.slint:make-slint-component
                    :source source :source-path path :width 400d0 :height 100d0)))
    (unwind-protect
         (progn
           (dolist (property properties)
             (ataxia.world.slint:set-slint-property component (car property) (cdr property)))
           (dolist (callback callbacks)
             (ataxia.world.slint:set-slint-callback component callback (lambda (&rest args) (declare (ignore args))))
             (ataxia.world.slint:remove-slint-callback component callback))
           (assert (handler-case
                       (progn (ataxia.world.slint:set-slint-property component "missing-property" t) nil)
                     (error () t))))
      (ataxia.world.slint:destroy-slint-component component))))

(dolist (spec '(("header" (("caption" . "test") ("active" . t)) ("enter"))
                ("toolbar" (("caption" . "test") ("active" . t) ("standalone" . nil) ("workspace" . 2)) ("action"))
                ("group-controls" (("world-name" . "test") ("policy" . "niri") ("confirming" . t) ("standalone" . nil)) ("action" "rename"))
                ("canvas-menu" nil ("action"))
                ("window-controls" (("expanded" . t) ("owned" . t) ("detachable" . nil) ("niri" . t) ("floating" . nil)) ("action"))
                ("note" (("content" . "test")) ("edited" "close"))))
  (let ((start (get-internal-real-time)))
    (dotimes (iteration 5)
      (check-component (format nil "ataxia-builtin:~A" (first spec)) "" (second spec) (third spec)))
    (format t "~A: five create/configure/destroy cycles in ~,2F ms~%"
            (first spec) (* 1000d0 (/ (- (get-internal-real-time) start) internal-time-units-per-second)))))
(check-component "test.slint"
                 "export component Test inherits Window { in property <string> caption; callback action(string); }"
                 '(("caption" . "dynamic")) '("action"))
(format t "Slint built-in interfaces and dynamic fallback passed.~%")
