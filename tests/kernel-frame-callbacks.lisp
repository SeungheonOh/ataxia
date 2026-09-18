(load (merge-pathnames "support.lisp" *load-truename*))
(in-package #:ataxia.kernel)
(let* ((kernel (make-instance 'kernel :world (make-instance 'world)))
       (output (make-instance 'kernel-output :kernel kernel :runtime-object :output))
       (surfaces (loop for id in '(1 2) collect
                  (make-instance 'surface-node :kernel kernel :id id :state :live :commit-sequence 7 :runtime-object id)))
       (tokens (mapcar (lambda (surface) (make-instance 'surface-protocol-token :surface surface :generation 7)) surfaces))
       (result (make-instance 'world-frame-result :target-token :target :complete-p t :damage nil
                              :presentation-tokens (vector (first tokens) (first tokens))
                              :callback-tokens (coerce (append tokens tokens) 'vector)))
       (lease (make-instance 'frame-lease :target-token :target :width 100 :height 100))
       (names '(ataxia.runtime:mark-surface-textured-on-output ataxia.runtime:surface-send-frame-done))
       (originals (mapcar #'symbol-function names)) (textured nil) (callbacks nil))
  (unwind-protect
       (progn
         (setf (symbol-function (first names)) (lambda (surface output) (assert (eq output :output)) (push surface textured))
               (symbol-function (second names)) (lambda (surface) (push surface callbacks)))
         (%validate-frame-result kernel lease result)
         (%notify-presented-surfaces output result)
         (assert (equal textured '(1)))
         (assert (equal (sort callbacks #'<) '(1 2)))
         ;; Callback-only tokens obey exactly the same generation/owner contract.
         (incf (surface-commit-sequence (second surfaces)))
         (assert (handler-case (progn (%validate-frame-result kernel lease result) nil) (error () t)))
         (setf (surface-commit-sequence (second surfaces)) 7 (object-state (second surfaces)) :destroyed)
         (assert (handler-case (progn (%validate-frame-result kernel lease result) nil) (error () t)))
         (format t "PASS: visible callback-only clients progress without claiming presentation; duplicates and stale tokens handled.~%"))
    (loop for name in names for original in originals do (setf (symbol-function name) original))))
