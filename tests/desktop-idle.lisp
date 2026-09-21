;;;; Real desktop integrations must sleep without input or an active share.
;;;; Run on a disposable session bus via make benchmark-desktop-idle.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-screencast")
(asdf:load-system "ataxia-rmlui/status-bar")
(in-package #:ataxia.infinite-world)

(let* ((world (make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                           :headless-width 1200 :headless-height 800))
       (runtime (ataxia.kernel:kernel-runtime kernel))
       (names '(ataxia.kernel::%render-output-frame ataxia.runtime.raw:%wl-event-loop-dispatch
                %share-tick %render-capture-pixels))
       (originals (mapcar #'symbol-function names))
       (counts (make-array 4 :initial-element 0))
       (clients nil) (start-time nil) (start-cpu nil) (start-bytes nil))
  (unwind-protect
       (progn
         (ataxia.kernel:start-kernel kernel)
         (ataxia.runtime.raw:%wlr-headless-add-output
          (ataxia.runtime::%object-pointer (ataxia.runtime:runtime-backend runtime)) 800 1000)
         (ataxia.kernel:enable-xwayland kernel)
         (ataxia.world.shell:enable-rmlui-status-bar world)
         (enable-screen-sharing world)
         (push (uiop:launch-program
                (list "env" (format nil "WAYLAND_DISPLAY=~A" (ataxia.runtime:runtime-socket-name runtime))
                      "build/computer-use-client" "/tmp/ataxia-desktop-idle-wayland.log")
                :output "/tmp/ataxia-desktop-idle-client.log" :error-output :output) clients)
         (push (uiop:launch-program
                (list "env" (format nil "DISPLAY=~A" (ataxia.kernel:xwayland-display-name kernel))
                      "build/xwayland-client")
                :output "/tmp/ataxia-desktop-idle-x11.log" :error-output :output) clients)
         (loop for name in names for original in originals for index from 0 do
           (let ((original original) (index index))
             (setf (symbol-function name)
                   (lambda (&rest arguments)
                     (when start-time (incf (aref counts index)))
                     (apply original arguments)))))
         (let ((timer (ataxia.runtime:add-event-loop-timer runtime
                        (lambda (source)
                          (declare (ignore source))
                          (assert (= 2 (length (ataxia.kernel:kernel-outputs kernel))))
                          (assert (= 2 (count-if #'%window-visible-p (%world-stacking world))))
                          (assert (= 2 (length (ataxia.world.shell:status-bars world))))
                          (assert (null (share-controller-sessions
                                         (ataxia.world:world-service world :screen-sharing))))
                          (setf start-cpu (get-internal-run-time)
                                start-bytes (sb-ext:get-bytes-consed) start-time (%now))
                          0))))
           (ataxia.runtime:update-event-loop-timer timer 1800))
         (ataxia.kernel:run-kernel kernel :run-for 4.8d0)
         (assert start-time)
         (let* ((seconds (- (%now) start-time))
                (cpu-ms (* 1000d0 (/ (- (get-internal-run-time) start-cpu) internal-time-units-per-second))))
           (format t "DESKTOP-IDLE: seconds=~,3F process-cpu-ms=~,3F one-core-percent=~,4F frames=~D dispatches=~D share-ticks=~D captures=~D allocated-bytes=~D~%"
                   seconds cpu-ms (/ cpu-ms seconds 10d0)
                   (aref counts 0) (aref counts 1) (aref counts 2) (aref counts 3)
                   (- (sb-ext:get-bytes-consed) start-bytes)))
         ;; A wall-clock minute boundary may repaint each status bar once.
         ;; Timing/CPU numbers are diagnostic; repeated rendering and capture
         ;; are deterministic regressions regardless of machine speed.
         (assert (<= (aref counts 0) 2))
         (assert (zerop (aref counts 2)))
         (assert (zerop (aref counts 3)))
         (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
         (format t "PASS: two outputs, RmlUi bars, real Wayland/X11 windows and the portal remain idle.~%"))
    (loop for name in names for original in originals do (setf (symbol-function name) original))
    (dolist (client clients) (when (uiop:process-alive-p client) (uiop:terminate-process client)))
    (ataxia.kernel:destroy-kernel kernel :idle-measurement)))
