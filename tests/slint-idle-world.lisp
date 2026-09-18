;;;; Real Slint timers on two outputs: repaint only changed UI, preserve callbacks.
(load (merge-pathnames "support.lisp" *load-truename*))
(in-package #:ataxia.infinite-world)

(let* ((world (make-infinite-world))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                           :headless-width 640 :headless-height 480))
       (render (symbol-function 'ataxia.kernel::%render-output-frame))
       (native-render (symbol-function 'ataxia.world.slint.raw::%component-render))
       (frames (make-hash-table :test #'eq)) (callbacks 0) (callback-baseline 0)
       (phase 0) (active nil) (quiet nil) (widget nil) (component nil)
       (start-cpu 0) (results nil) (clean-native-calls 0))
  (unwind-protect
       (progn
         (ataxia.kernel:start-kernel kernel)
         (ataxia.runtime.raw:%wlr-headless-add-output
          (ataxia.runtime::%object-pointer
           (ataxia.runtime:runtime-backend (ataxia.kernel:kernel-runtime kernel))) 640 480)
         (setf active (first (world-outputs world)) quiet (second (world-outputs world)))
         (assert (and active quiet))
         (setf widget
               (make-agent-widget world
                "export component Clock inherits Window {
                   in property <bool> paint: true;
                   in property <bool> running: true;
                   property <int> ticks: 0;
                   callback tick();
                   Timer { interval: 80ms; running: root.running;
                           triggered => { root.ticks += 1; root.tick(); } }
                   Text { text: root.paint ? root.ticks : 0; }
                 }" :output active :width 200d0 :height 100d0)
               component (overlay-component widget))
         (bind-agent-widget-event widget "tick"
           (lambda (widget event) (declare (ignore widget event)) (incf callbacks)))
         (make-agent-widget world "export component Quiet inherits Window { background: #335577; }"
                            :output quiet :width 200d0 :height 100d0)
         (setf (symbol-function 'ataxia.kernel::%render-output-frame)
               (lambda (output) (incf (gethash output frames 0)) (funcall render output)))
         (labels ((begin-sample ()
                    (clrhash frames)
                    (setf start-cpu (get-internal-run-time) callback-baseline callbacks))
                  (sample (name)
                    (let ((row (list name :active-frames (gethash active frames 0)
                                     :quiet-frames (gethash quiet frames 0)
                                     :callbacks (- callbacks callback-baseline)
                                     :cpu-ms (* 1000d0 (/ (- (get-internal-run-time) start-cpu)
                                                         internal-time-units-per-second)))))
                      (push row results)
                      (format t "SLINT-IDLE: ~S~%" row))))
           (let ((timer
                   (ataxia.runtime:add-event-loop-timer
                    (ataxia.kernel:kernel-runtime kernel)
                    (lambda (source)
                      (case phase
                        (0 (begin-sample) (ataxia.runtime:update-event-loop-timer source 600))
                        (1 (sample :visible-timer)
                           (set-agent-widget-property widget "paint" nil)
                           (ataxia.runtime:update-event-loop-timer source 150))
                        (2 (begin-sample) (ataxia.runtime:update-event-loop-timer source 600))
                        (3 (sample :callback-only-timer)
                           (set-agent-widget-property widget "running" nil)
                           (ataxia.runtime:update-event-loop-timer source 150))
                        (4
                         (setf (symbol-function 'ataxia.world.slint.raw::%component-render)
                               (lambda (pointer) (incf clean-native-calls) (funcall native-render pointer)))
                         (let ((before (get-internal-run-time)))
                           (ataxia.runtime:call-with-egl-context
                            (ataxia.runtime:runtime-egl (ataxia.kernel:kernel-runtime kernel))
                            (lambda ()
                              (dotimes (i 10000) (ataxia.world.slint:render-slint-component component))))
                           (format t "SLINT-CLEAN: calls=10000 native-calls=~D cpu-ms=~,3F~%"
                                   clean-native-calls
                                   (* 1000d0 (/ (- (get-internal-run-time) before)
                                               internal-time-units-per-second))))
                         (setf (symbol-function 'ataxia.world.slint.raw::%component-render) native-render)
                         (configure-agent-widget world widget :width 240d0 :height 120d0)
                         (ataxia.runtime:update-event-loop-timer source 150))
                        (5
                         (let ((scale (ataxia.world.slint:slint-component-scale component)))
                           (assert (= (round (* 240 scale)) (ataxia.world.slint::%component-texture-width component)))
                           (assert (= (round (* 120 scale)) (ataxia.world.slint::%component-texture-height component))))
                         (ataxia.kernel:request-kernel-stop kernel :test-complete)))
                      (incf phase) 0))))
             (ataxia.runtime:update-event-loop-timer timer 300))
           (ataxia.kernel:run-kernel kernel :run-for 4d0))
         (assert (= phase 6))
         (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
         (unless (uiop:getenv "ATAXIA_IDLE_MEASURE_ONLY")
           (dolist (row results)
             (assert (zerop (getf (cdr row) :quiet-frames)))
             (assert (plusp (getf (cdr row) :callbacks)))
             (if (eq (car row) :visible-timer)
                 (assert (plusp (getf (cdr row) :active-frames)))
                 (assert (zerop (getf (cdr row) :active-frames)))))
           (assert (zerop clean-native-calls)))
         (format t "PASS: Slint timer callbacks, per-output repainting, clean texture reuse and resize.~%"))
    (setf (symbol-function 'ataxia.kernel::%render-output-frame) render
          (symbol-function 'ataxia.world.slint.raw::%component-render) native-render)
    (ataxia.kernel:destroy-kernel kernel :test-complete)))

;;;; Atlas advances animations on output frames and delivers timers without drawing.
(asdf:load-system "ataxia-atlas-world")
(in-package #:ataxia.atlas-world)
(let* ((+atlas-panel-source+
         "export component AtaxiaPanel inherits Window {
            in property <bool> lit: false;
            in property <bool> running: false;
            callback tick();
            Rectangle {
              background: root.lit ? #ffffff : #111111;
              animate background { duration: 120ms; }
            }
            Timer { interval: 80ms; running: root.running; triggered => { root.tick(); } }
          }")
       (world (make-atlas-world))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                           :headless-width 640 :headless-height 480))
       (render (symbol-function 'ataxia.kernel::%render-output-frame))
       (component nil) (phase 0) (frames 0) (callbacks 0) (revision 0))
  (unwind-protect
       (progn
         (ataxia.kernel:start-kernel kernel)
         (ataxia.runtime.raw:%wlr-headless-add-output
          (ataxia.runtime::%object-pointer
           (ataxia.runtime:runtime-backend (ataxia.kernel:kernel-runtime kernel))) 640 480)
         (setf component (atlas-object-component
                          (gethash (%atlas-output-output (%first-output-state world))
                                   (%world-output-components world)))
               (symbol-function 'ataxia.kernel::%render-output-frame)
               (lambda (output) (incf frames) (funcall render output)))
         (ataxia.world.slint:set-slint-callback
          component "tick" (lambda (component value) (declare (ignore component value)) (incf callbacks)))
         (let ((timer
                 (ataxia.runtime:add-event-loop-timer
                  (ataxia.kernel:kernel-runtime kernel)
                  (lambda (source)
                    (case phase
                      (0 (setf revision (ataxia.world.slint::%component-revision component))
                         (ataxia.world.slint:set-slint-property component "lit" t)
                         (ataxia.runtime:update-event-loop-timer source 300))
                      (1 (assert (> (- (ataxia.world.slint::%component-revision component) revision) 1))
                         (assert (not (ataxia.world.slint:slint-component-active-p component)))
                         (ataxia.world.slint:set-slint-property component "running" t)
                         (ataxia.runtime:update-event-loop-timer source 150))
                      (2 (setf frames 0 callbacks 0)
                         (ataxia.runtime:update-event-loop-timer source 400))
                      (3 (assert (plusp callbacks)) (assert (zerop frames))
                         (ataxia.kernel:request-kernel-stop kernel :test-complete)))
                    (incf phase) 0))))
           (ataxia.runtime:update-event-loop-timer timer 300))
         (ataxia.kernel:run-kernel kernel :run-for 3d0)
         (assert (= phase 4))
         (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
         (format t "PASS: real Atlas animation finishes and ~D timer callbacks require zero frames across two outputs.~%"
                 callbacks))
    (setf (symbol-function 'ataxia.kernel::%render-output-frame) render)
    (ataxia.kernel:destroy-kernel kernel :test-complete)))
