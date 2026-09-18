;;;; Exercise both UI engines in a real headless World and measure settled frames.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-rmlui/infinite")
(in-package #:ataxia.infinite-world)
(let* ((world (make-infinite-world))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                            :headless-width 800 :headless-height 500))
       (original (symbol-function 'ataxia.kernel::%render-output-frame))
       (rml nil) (slint nil) (clicks 0) (frames 0) (baseline 0) (phase 0)
       (start-cpu 0) (start-time 0d0) (result nil))
  (unwind-protect
       (progn
         (setf (symbol-function 'ataxia.kernel::%render-output-frame)
               (lambda (output) (incf frames) (funcall original output)))
         (ataxia.kernel:start-kernel kernel)
         (setf rml (ataxia.world.rmlui:make-rmlui-widget
                    world "<rml><head><style>body { margin:0; width:100%; height:100%; font-family:DejaVu Sans; font-size:16dp; } #apply { position:absolute; left:10dp; top:10dp; width:100dp; height:60dp; background:#ee7744; } #apply.animate { animation:0.1s linear 1 fade; } @keyframes fade { from { opacity:0.1; } to { opacity:1; } }</style></head><body><button id='apply'>RmlUi</button></body></rml>"
                    :x 30d0 :y 30d0 :width 300d0 :height 180d0)
               slint (make-agent-widget
                      world "export component Test inherits Window { background:#335577; Text { text:\"Slint alongside RmlUi\"; color:white; } }"
                      :x 360d0 :y 30d0 :width 300d0 :height 180d0))
         (bind-agent-widget-event rml "apply"
                                  (lambda (widget event) (declare (ignore widget event)) (incf clicks)))
         (let ((timer
                 (ataxia.runtime:add-event-loop-timer
                  (ataxia.kernel:kernel-runtime kernel)
                  (lambda (source)
                    (case phase
                      (0
                       (assert (plusp frames))
                       (assert (= 2 (length (list-agent-widgets world))))
                       (let ((component (canvas-overlay-component rml)))
                         (dolist (state '(:pressed :released))
                           (ataxia.kernel:interactable-pointer-button
                            component world nil 40d0 30d0
                            (ataxia.kernel:make-cursor-button-input :code 272 :state state)))
                         (assert (= clicks 1))
                         ;; Exercise the reverse toolkit preparation/composition order too.
                         (setf (world-overlays world) (reverse (world-overlays world)))
                         (ataxia.world.rmlui:set-rmlui-class component "apply" "animate" t))
                       (incf phase)
                       (ataxia.runtime:update-event-loop-timer source 400))
                      (1
                       (assert (not (ataxia.kernel:drawable-active-p (canvas-overlay-component rml))))
                       ;; A settled widget reused by unrelated client frames must
                       ;; not capture GLES state, allocate, or enter native rendering.
                       (let* ((component (canvas-overlay-component rml))
                              (saved (symbol-function 'ataxia.world.rmlui::call-with-preserved-graphics-state))
                              (revision (ataxia.world.rmlui::%component-revision component)))
                         (unwind-protect
                              (progn
                                (setf (symbol-function 'ataxia.world.rmlui::call-with-preserved-graphics-state)
                                      (lambda (function) (declare (ignore function))
                                        (error "A clean RmlUi component touched GLES state.")))
                                (dotimes (index 100)
                                  (multiple-value-bind (damage active)
                                      (ataxia.world.rmlui:render-rmlui-component component)
                                    (assert (not damage)) (assert (not active))))
                                (assert (= revision (ataxia.world.rmlui::%component-revision component))))
                           (setf (symbol-function 'ataxia.world.rmlui::call-with-preserved-graphics-state) saved)))
                       (setf baseline frames start-cpu (get-internal-run-time) start-time (%now))
                       (incf phase)
                       (ataxia.runtime:update-event-loop-timer source 400))
                      (2
                       (let ((elapsed (- (%now) start-time)))
                         (setf result (list :frames (- frames baseline) :clicks clicks
                                            :cpu-percent (* 100d0 (/ (- (get-internal-run-time) start-cpu)
                                                                    internal-time-units-per-second elapsed)))))
                       (assert (zerop (- frames baseline)))
                       (configure-agent-widget world rml :width 320d0 :height 200d0)
                       (incf phase)
                       (ataxia.runtime:update-event-loop-timer source 100))
                      (3
                       ;; A resize after the clean fast path still redraws and
                       ;; reallocates the texture before the widget is retired.
                       (let ((component (canvas-overlay-component rml)))
                         (assert (> frames baseline))
                         (let ((scale (ataxia.world.rmlui:rmlui-component-scale component)))
                           (assert (= (round (* 320 scale)) (ataxia.world.rmlui::%component-texture-width component)))
                           (assert (= (round (* 200 scale)) (ataxia.world.rmlui::%component-texture-height component)))))
                       (remove-agent-widget world rml)
                       (incf phase)
                       (ataxia.runtime:update-event-loop-timer source 100))
                      (4
                       (assert (= 1 (length (list-agent-widgets world))))
                       (assert (eq slint (first (list-agent-widgets world))))
                       (ataxia.runtime:update-event-loop-timer source 0)))
                    0))))
           (ataxia.runtime:update-event-loop-timer timer 500))
         (ataxia.kernel:run-kernel kernel :run-for 1.8d0)
         (assert result)
         (assert (eq (ataxia.kernel:kernel-world-status kernel) :running))
         (format t "PASS: real World mixed Slint/RmlUi render, input, resize/removal, animation and idle: ~S~%" result))
    (setf (symbol-function 'ataxia.kernel::%render-output-frame) original)
    (ataxia.kernel:destroy-kernel kernel :rmlui-test-complete)))
