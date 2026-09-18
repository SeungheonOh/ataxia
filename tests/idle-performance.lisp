;;;; Run with make benchmark-idle. Measurements are diagnostic, not timing gates.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-assistant/metaworld")
(in-package #:ataxia.infinite-world)

(defun idle-thread-counters (thread)
  "Linux scheduler CPU nanoseconds and voluntary switches for one SBCL thread."
  (let ((directory (format nil "/proc/self/task/~D/" (sb-thread::thread-os-tid thread))))
    (list (with-open-file (stream (concatenate 'string directory "schedstat"))
            (read stream))
          (with-open-file (stream (concatenate 'string directory "status"))
            (loop for line = (read-line stream nil nil) while line
                  when (uiop:string-prefix-p "voluntary_ctxt_switches:" line)
                    return (parse-integer line :start (1+ (position #\: line))))))))

;; Exercise the real mailbox/deadline loop without a model service or audio I/O.
(let* ((controller (ataxia.assistant::%make-assistant-controller))
       (wake (ataxia.assistant::assistant-controller-wake controller))
       (ready (sb-thread:make-semaphore))
       (thread (sb-thread:make-thread
                (lambda ()
                  (sb-thread:signal-semaphore ready)
                  (ataxia.assistant::%assistant-worker-loop controller 0 wake))
                :name "Idle measurement")))
  (unwind-protect
       (progn
         (assert (sb-thread:wait-on-semaphore ready :timeout 2d0))
         (sleep .1d0)
         (let ((before (idle-thread-counters thread)))
           (sleep 5d0)
           (let ((after (idle-thread-counters thread)))
             (format t "WORKER-IDLE: seconds=5 cpu-ms=~,6F voluntary-switches=~D~%"
                     (/ (- (first after) (first before)) 1000000d0)
                     (- (second after) (second before))))))
    (setf (ataxia.assistant::assistant-controller-alive controller) nil)
    (sb-thread:signal-semaphore wake)
    (assert (not (eq :stuck (sb-thread:join-thread thread :timeout 2d0 :default :stuck))))))

;; Include shell chrome and the assistant panel, with no clients or user input.
;; Warm up for one second, then measure five seconds including the stop timer.
(let* ((world (make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                           :headless-width 1100 :headless-height 800))
       (render (symbol-function 'ataxia.kernel::%render-output-frame))
       (dispatch (symbol-function 'ataxia.runtime.raw:%wl-event-loop-dispatch))
       (maintain-bar (symbol-function 'ataxia.world.shell::%bar-maintain))
       (frames 0) (dispatches 0) (bar-updates 0)
       (start-cpu nil) (start-bytes nil) (start-time nil))
  (unwind-protect
       (progn
         (ataxia.kernel:start-kernel kernel)
         (ataxia.world.shell:enable-rmlui-status-bar world)
         (ataxia.assistant::%assistant-enable world :project (namestring (asdf:system-source-directory "ataxia-assistant")))
         (setf (symbol-function 'ataxia.kernel::%render-output-frame)
               (lambda (output)
                 (when start-time (incf frames))
                 (funcall render output))
               (symbol-function 'ataxia.runtime.raw:%wl-event-loop-dispatch)
               (lambda (&rest arguments)
                 (when start-time (incf dispatches))
                 (apply dispatch arguments))
               (symbol-function 'ataxia.world.shell::%bar-maintain)
               (lambda (world source)
                 (when start-time (incf bar-updates))
                 (funcall maintain-bar world source)))
         (let ((timer (ataxia.runtime:add-event-loop-timer
                       (ataxia.kernel:kernel-runtime kernel)
                       (lambda (source)
                         (declare (ignore source))
                         (setf frames 0 dispatches 0 bar-updates 0
                               start-cpu (get-internal-run-time)
                               start-bytes (sb-ext:get-bytes-consed)
                               start-time (%now))
                         0))))
           (ataxia.runtime:update-event-loop-timer timer 1000))
         (ataxia.kernel:run-kernel kernel :run-for 6d0)
         (format t "WORLD-IDLE: seconds=~,3F frames=~D dispatches=~D bar-updates=~D process-cpu-ms=~,3F allocated-bytes=~D~%"
                 (- (%now) start-time) frames dispatches bar-updates
                 (* 1000d0 (/ (- (get-internal-run-time) start-cpu) internal-time-units-per-second))
                 (- (sb-ext:get-bytes-consed) start-bytes)))
    (setf (symbol-function 'ataxia.kernel::%render-output-frame) render
          (symbol-function 'ataxia.runtime.raw:%wl-event-loop-dispatch) dispatch
          (symbol-function 'ataxia.world.shell::%bar-maintain) maintain-bar)
    (ataxia.kernel:destroy-kernel kernel :idle-measurement)))
