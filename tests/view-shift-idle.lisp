;;;; The stationary pan HUD must not schedule decorative animation frames.
(load (merge-pathnames "support.lisp" *load-truename*))
(in-package #:ataxia.infinite-world)
(let* ((world (make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                           :headless-width 800 :headless-height 600))
       (original (symbol-function 'ataxia.kernel::%render-output-frame))
       (frames 0) (baseline nil) (verified nil))
  (unwind-protect
       (progn
         (setf (symbol-function 'ataxia.kernel::%render-output-frame)
               (lambda (output) (incf frames) (funcall original output)))
         (ataxia.kernel:start-kernel kernel)
         (let* ((hud (ataxia.world:create-agent-widget 'ataxia.world:agent-widget
                       world +view-shift-ui-source+
                       :component-factory #'ataxia.world.slint:make-slint-component
                       :width 240d0 :height 240d0))
                (timer (ataxia.runtime:add-event-loop-timer
                        (ataxia.kernel:kernel-runtime kernel)
                        (lambda (source)
                          (assert (plusp frames))
                          (assert (not (ataxia.kernel:drawable-active-p (overlay-component hud))))
                          (if baseline
                              (progn (assert (= frames baseline)) (setf verified t))
                              (progn (setf baseline frames)
                                     (ataxia.runtime:update-event-loop-timer source 300)))
                          0))))
           (ataxia.runtime:update-event-loop-timer timer 400))
         (ataxia.kernel:run-kernel kernel :run-for 0.9d0)
         (assert verified)
         (format t "PASS: visible stationary pan HUD returns to zero-frame idle.~%"))
    (setf (symbol-function 'ataxia.kernel::%render-output-frame) original)
    (ataxia.kernel:destroy-kernel kernel :pan-hud-idle-test)))
