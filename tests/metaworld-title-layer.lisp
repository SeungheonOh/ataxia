;;;; Run: sbcl --script tests/metaworld-motion.lisp
(require :asdf)
(let ((root (uiop:pathname-parent-directory-pathname
             (uiop:pathname-directory-pathname *load-truename*))))
  (asdf:initialize-source-registry
   `(:source-registry (:tree ,root)
     (:tree ,(merge-pathnames "fun/ataxia-deps/common-lisp/" (user-homedir-pathname)))
     :inherit-configuration))
  (asdf:load-system "ataxia-metaworld"))
(in-package #:ataxia.infinite-world)

(defclass title-test-component (ataxia.kernel:drawable ataxia.kernel:interactable) ())
(let* ((world (make-metaworld :state-file nil)) (state (%make-canvas-output nil))
       (component (make-instance 'title-test-component))
       (title (make-instance 'meta-title-widget :world world :component component :output nil
                            :x 0d0 :y 0d0 :width 100d0 :height 30d0 :visible-p t))
       (controls (make-instance 'meta-chrome-widget :world world :component component :output nil
                               :x 0d0 :y 0d0 :width 100d0 :height 30d0 :visible-p t))
       (window (make-instance 'canvas-window :application (make-instance 'ataxia.kernel:wayland-application)))
       (region (ataxia.world:make-rectangle 0d0 0d0 100d0 100d0))
       (order nil)
       (names '(%window-buffer-coverage %overlay-buffer-coverage %windows-at-screen-point
                %draw-grid %draw-world-background %draw-window %draw-overlay
                ataxia.world.gles:gles-reset-state ataxia.world.gles:gles-set-scissor-enabled
                ataxia.world.gles:gles-set-scissor ataxia.world.gles:gles-clear
                ataxia.world.gles:gles-disable-attribute ataxia.world.gles:gles-flush ataxia.world.gles:gles-check-error))
       (originals (mapcar #'symbol-function names)))
  (unwind-protect
       (progn
         (dolist (name names) (setf (symbol-function name) (lambda (&rest args) (declare (ignore args)))))
         (setf (%canvas-output-buffer-width state) 100 (%canvas-output-buffer-height state) 100
               (%canvas-window-mapped-p window) t
               (%meta-chrome-present-p title) t (%meta-chrome-present-p controls) t
               (world-overlays world) (list title controls)
               (symbol-function '%window-buffer-coverage) (lambda (&rest args) (declare (ignore args)) region)
               (symbol-function '%overlay-buffer-coverage) (lambda (&rest args) (declare (ignore args)) region)
               (symbol-function '%windows-at-screen-point) (lambda (&rest args) (declare (ignore args)) (list window))
               (symbol-function '%draw-grid) (lambda (&rest args) (declare (ignore args)) (push :grid order))
               (symbol-function '%draw-world-background) (lambda (&rest args) (declare (ignore args)) (push :background order))
               (symbol-function '%draw-window)
               (lambda (renderer state object tokens) (declare (ignore renderer state object)) (push :window order) tokens)
               (symbol-function '%draw-overlay)
               (lambda (renderer state object tokens)
                 (declare (ignore renderer state)) (push (if (eq object title) :title :controls) order) tokens))
         (assert (equal (list controls window title) (%targets-at-screen-point world state 20d0 15d0)))
         (%render-canvas nil state (list window) (list title controls) nil (list region) nil world)
         (assert (equal '(:grid :background :title :window :controls) (reverse order)))
         (setf (world-overlays world) (list title))
         (assert (eq window (%target-at-screen-point world state 20d0 15d0)))
         (setf (symbol-function '%windows-at-screen-point) (lambda (&rest args) (declare (ignore args)) nil))
         (assert (eq title (%target-at-screen-point world state 20d0 15d0)))
         (format t "PASS: windows paint over titles and receive covered-title clicks; exposed titles and top controls remain interactive.~%"))
    (loop for name in names for original in originals do (setf (symbol-function name) original))))
