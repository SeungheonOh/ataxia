;;;; Run: sbcl --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/slint-builtins.lisp
(load (merge-pathnames "support.lisp" *load-truename*))
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
                ("note" (("content" . "test")) ("edited" "close"))))
  (let ((start (get-internal-real-time)))
    (dotimes (iteration 5)
      (check-component (format nil "ataxia-builtin:~A" (first spec)) "" (second spec) (third spec)))
    (format t "~A: five create/configure/destroy cycles in ~,2F ms~%"
            (first spec) (* 1000d0 (/ (- (get-internal-real-time) start) internal-time-units-per-second)))))
(check-component "test.slint"
                 "export component Test inherits Window { in property <string> caption; callback action(string); }"
                 '(("caption" . "dynamic")) '("action"))
(dolist (name '("header" "toolbar" "group-controls" "canvas-menu" "note"))
  ;; Source interpretation is also used for live visual updates while existing
  ;; component pointers retain their original native library instance.
  (let ((path (asdf:system-relative-pathname "ataxia-metaworld"
                 (format nil "src/worlds/metaworld/~A.slint" name))))
    (check-component (namestring path) (uiop:read-file-string path) nil nil)))
(check-component "ataxia-view-shift.slint" +view-shift-ui-source+ nil nil)
(format t "Slint built-in interfaces and dynamic fallback passed.~%")
