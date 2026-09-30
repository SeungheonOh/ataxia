;;;; Real browser/framework/input/animation integration, mixed with existing engines.
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-infinite-world")
(asdf:load-system "ataxia-rmlui")
(asdf:load-system "ataxia-web")
(in-package #:cl-user)
(let* ((world (ataxia.infinite-world:make-infinite-world))
       (kernel (ataxia.kernel:create-kernel world :backend :headless :headless-width 900 :headless-height 600))
       (original (symbol-function 'ataxia.kernel::%render-output-frame))
       (frames 0) (baseline 0) (paints 0) (phase 0) (attempts 0) (done nil)
       (web nil) (second nil) (events (make-hash-table :test #'equal)) (cpu 0) (started 0))
  (labels ((component () (ataxia.world:overlay-component web))
           (stats () (ataxia.world.web:web-component-stats (component)))
           (paint-count () (getf (stats) :paints))
           (script (code) (ataxia.world.web:evaluate-web-javascript (component) code))
           (click (x y)
             (ataxia.kernel:interactable-pointer-motion (component) world nil x y nil)
             (dolist (state '(:pressed :released))
               (ataxia.kernel:interactable-pointer-button (component) world nil x y
                 (ataxia.kernel:make-cursor-button-input :code 272 :state state))))
           (step-test (source)
             (format t "WEB phase ~D~%" phase)
             (when web (assert (null (ataxia.world.web:web-component-error (component)))))
             (let ((delay 400))
               (case phase
                 (0
                  (incf attempts) (assert (< attempts 100))
                  (if (and (gethash "react-ready" events) (gethash "svelte-ready" events)
                           (plusp (length (ataxia.kernel:drawable-surfaces (component)))))
                      (progn
                        (assert (search "\"grid\":true" (gethash "features" events)))
                        (assert (typep (component) 'ataxia.kernel:drawable))
                        (assert (typep (component) 'ataxia.kernel:interactable))
                        (assert (= 4 (length (ataxia.world:list-agent-widgets world))))
                        (ataxia.kernel:interactable-key-event (component) world nil
                          (ataxia.kernel:make-modifiers-input :names '(:control)))
                        (click 50d0 72d0)
                        (ataxia.kernel:interactable-key-event (component) world nil
                          (ataxia.kernel:make-modifiers-input :names nil))
                        (click 365d0 72d0)
                        (ataxia.kernel:interactable-focus (component) world nil :keyboard)
                        (click 50d0 104d0)
                        (loop for ch across "Hello" do
                          (dolist (state '(:pressed :released))
                            (ataxia.kernel:interactable-key-event (component) world nil
                              (ataxia.kernel:make-key-input :keycode 35 :keysyms (vector (string ch)) :state state))))
                        (incf phase))
                      (setf delay 100)))
                 (1
                  (format t "INPUT events: ~S~%" (loop for k being the hash-keys of events using (hash-value v) collect (cons k v)))
                  (assert (equal "1" (gethash "react-count" events)))
                  (assert (equal "true" (gethash "react-modifiers" events)))
                  (assert (equal "1" (gethash "svelte-count" events)))
                  (assert (equal "\"Hello\"" (gethash "text" events)))
                  (setf paints (paint-count))
                  (script "document.body.classList.add('animate'); document.getElementById('animation').addEventListener('animationend',()=>ataxia.postMessage('animation-end',true),{once:true});")
                  (incf phase) (setf delay 250))
                 (2 (assert (> (paint-count) paints))
                    (script "document.activeElement.blur()")
                    (ataxia.kernel:interactable-focus (component) world nil nil)
                    (incf phase) (setf delay 1000))
                 (3
                  (assert (gethash "animation-end" events))
                  (setf paints (paint-count) baseline frames cpu (get-internal-run-time) started (get-internal-real-time))
                  (incf phase) (setf delay 3000))
                 (4
                  (assert (= paints (paint-count))) (assert (= frames baseline))
                  (format t "WEB-IDLE: frames=~D paints=~D cpu-ms=~,3F seconds=~,3F~%"
                          (- frames baseline) (- (paint-count) paints)
                          (* 1000d0 (/ (- (get-internal-run-time) cpu) internal-time-units-per-second))
                          (/ (- (get-internal-real-time) started) (float internal-time-units-per-second 1d0)))
                  (script "document.getElementById('animation').style.animation='grow .4s linear infinite'") (incf phase))
                 (5
                  (assert (> (paint-count) paints))
                  (ataxia.world:configure-agent-widget world web :visible-p nil) (incf phase))
                 (6
                  (setf paints (paint-count) baseline frames) (incf phase) (setf delay 1500))
                 (7
                  (assert (= paints (paint-count))) (assert (= baseline frames))
                  (script "ataxia.postMessage('hidden',document.hidden)")
                  (incf phase))
                 (8
                  (assert (equal "true" (gethash "hidden" events)))
                  (ataxia.world:configure-agent-widget world web :x 1500d0 :visible-p t) (incf phase))
                 (9
                  (assert (not (getf (stats) :visible)))
                  (setf paints (paint-count))
                  (ataxia.world:configure-agent-widget world web :x 10d0) (incf phase))
                 (10
                  (assert (getf (stats) :visible)) (assert (> (paint-count) paints))
                  (script "document.getElementById('animation').style.animation='none'")
                  (ataxia.world:configure-agent-widget world web :width 520d0 :height 240d0) (incf phase))
                 (11
                  (assert (= (round (* 520 (ataxia.world.web:web-component-scale (component))))
                             (ataxia.world.web.raw::%width (ataxia.world.web::%native (component)))))
                  (ataxia.world:remove-agent-widget world web) (setf web nil)
                  (assert (= 3 (length (ataxia.world:list-agent-widgets world))))
                  (assert (ataxia.world.web:web-engine-pid world)) (incf phase))
                 (12
                  (ataxia.world:remove-agent-widget world second)
                  (incf phase))
                 (13
                  (assert (= 2 (length (ataxia.world:list-agent-widgets world))))
                  ;; The default launcher now owns a browser view too.
                  (let ((launcher (find-if (lambda (overlay) (typep overlay 'ataxia.infinite-world::launcher-overlay))
                                          (ataxia.world:world-overlays world))))
                    (assert launcher) (ataxia.world:remove-overlay world launcher))
                  (incf phase))
                 (14
                  (assert (null (ataxia.world:world-service world :web-ui)))
                  (setf done t delay 0)))
               (ataxia.runtime:update-event-loop-timer source delay)) 0))
    (unwind-protect
         (progn
           (setf (symbol-function 'ataxia.kernel::%render-output-frame)
                 (lambda (output) (incf frames) (funcall original output)))
           (ataxia.kernel:start-kernel kernel)
           (setf web (ataxia.world.web:make-web-widget world
                      :asset-root (asdf:system-relative-pathname "ataxia-web" "examples/web-ui/dist/")
                      :x 10d0 :y 10d0 :width 640d0 :height 220d0)
                 second (ataxia.world.web:make-web-widget world :source "<body style='margin:0;background:#234;color:white'>Second independent web view</body>"
                         :x 10d0 :y 250d0 :width 400d0 :height 50d0))
           (dolist (name '("react-ready" "svelte-ready" "react-modifiers" "react-count" "svelte-count" "text" "features" "animation-end" "hidden"))
             (let ((key name))
               (ataxia.world:bind-agent-widget-event web name
                 (lambda (widget event) (declare (ignore widget))
                   (setf (gethash key events) (ataxia.world:agent-widget-event-value event))))))
           (ataxia.world.rmlui:make-rmlui-widget world
             "<rml><body style='font-family:DejaVu Sans;color:white;background:#123'>RmlUi unchanged</body></rml>"
             :x 10d0 :y 330d0 :width 220d0 :height 70d0)
           (ataxia.world.slint:make-agent-widget world
             "export component Demo inherits Window {background:#213; Text {text:\"Slint unchanged\";color:white;} }"
             :x 280d0 :y 330d0 :width 220d0 :height 70d0)
           (let ((timer (ataxia.runtime:add-event-loop-timer (ataxia.kernel:kernel-runtime kernel) #'step-test)))
             (ataxia.runtime:update-event-loop-timer timer 100))
           (ataxia.kernel:run-kernel kernel :run-for 18d0)
           (assert done)
           (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
           (format t "PASS: React and Svelte, real input, CSS animation, zero idle frames, hidden/offscreen suspension, resize, shared process, cleanup, mixed Slint/RmlUi.~%"))
      (setf (symbol-function 'ataxia.kernel::%render-output-frame) original)
      (ataxia.kernel:destroy-kernel kernel :web-test))))
