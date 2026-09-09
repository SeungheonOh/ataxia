;;;; Run: sbcl --script tests/metaworld-idle.lisp
(load (merge-pathnames "support.lisp" *load-truename*))
(in-package #:ataxia.infinite-world)

;;;; Deadline scheduling must not poll idle UI or disabled persistence.
(let* ((world (make-metaworld :state-file nil))
       (state (%make-canvas-output nil))
       (seat (%make-canvas-seat :test))
       (view (%meta-view-for-state world state))
       (chrome (%meta-chrome-for-state world state))
       (clock 10d0) (original (symbol-function '%now)))
  (unwind-protect
       (progn
         (setf (symbol-function '%now) (lambda () clock)
               (gethash :test (%world-outputs world)) state
               (gethash :test (%world-seats world)) seat
               (%canvas-seat-output seat) state)
         (assert (zerop (%meta-maintenance-delay world)))
         (setf (%meta-save-needed-p world) t)
         (assert (zerop (%meta-maintenance-delay world)))
         (setf (%meta-chrome-edge-since chrome) clock)
         (assert (<= 350 (%meta-maintenance-delay world) 351))
         (setf clock 11d0 (%meta-view-panel-until view) 11.6d0)
         (assert (zerop (%meta-maintenance-delay world)))
         (setf (%meta-chrome-edge-since chrome) nil)
         (assert (<= 600 (%meta-maintenance-delay world) 601))
         (setf clock 12d0)
         (assert (zerop (%meta-maintenance-delay world)))
         (setf (%meta-chrome-window-since chrome) clock)
         (assert (<= 450 (%meta-maintenance-delay world) 451))
         (setf clock 13d0 (%meta-view-window-controls-until view) 13.55d0)
         (assert (zerop (%meta-maintenance-delay world)))
         (setf (%meta-chrome-window-since chrome) nil)
         (assert (<= 550 (%meta-maintenance-delay world) 551))
         (setf (slot-value world 'state-file) #P"/tmp/ataxia-idle-test.sexp"
               (%meta-last-save world) 12.8d0)
         (assert (<= 300 (%meta-maintenance-delay world) 301))
         (setf clock 14d0)
         (assert (<= 1 (%meta-maintenance-delay world) 2))
         (setf (%meta-save-needed-p world) nil)
         (assert (zerop (%meta-maintenance-delay world)))
         (format t "PASS: idle disarm, hover dwell/expiry/hold and deferred save deadlines.~%"))
    (setf (symbol-function '%now) original)))
(let* ((world (make-metaworld :state-file nil))
       (names '(%visible-component-p %component-animation-active-p
                ataxia.world.slint:slint-next-timer-milliseconds
                ataxia.runtime:update-event-loop-timer %request-all-frames))
       (originals (mapcar #'symbol-function names))
       (visible t) (active nil) (deadline #xffffffffffffffff) (delay nil) (frames 0))
  (unwind-protect
       (progn
         (setf (%world-component-timer world) :timer
               (symbol-function '%visible-component-p) (lambda (w) (declare (ignore w)) visible)
               (symbol-function '%component-animation-active-p) (lambda (w) (declare (ignore w)) active)
               (symbol-function 'ataxia.world.slint:slint-next-timer-milliseconds) (lambda () deadline)
               (symbol-function 'ataxia.runtime:update-event-loop-timer)
               (lambda (source milliseconds) (declare (ignore source)) (setf delay milliseconds))
               (symbol-function '%request-all-frames)
               (lambda (w) (declare (ignore w)) (incf frames)))
         (%schedule-component-timer world) (assert (zerop delay))
         (setf active t) (%schedule-component-timer world)
         (assert (zerop delay)) (assert (= frames 1))
         (setf active nil deadline 250) (%schedule-component-timer world) (assert (= delay 250))
         (setf visible nil) (%schedule-component-timer world) (assert (zerop delay))
         (format t "PASS: component timer disarms while idle and retains animation and application deadlines.~%"))
    (loop for name in names for original in originals do (setf (symbol-function name) original))))
(in-package #:ataxia.runtime)
(let* ((runtime (make-instance 'runtime))
       (names '(%object-pointer ataxia.runtime.raw:%wl-display-flush-clients
                ataxia.runtime.raw:%wl-event-loop-dispatch))
       (originals (mapcar #'symbol-function names)) (events nil))
  (unwind-protect
       (progn
         (setf (%runtime-state runtime) :running
               (symbol-function '%object-pointer) #'identity
               (symbol-function 'ataxia.runtime.raw:%wl-display-flush-clients)
               (lambda (display) (declare (ignore display)) (push :flush events))
               (symbol-function 'ataxia.runtime.raw:%wl-event-loop-dispatch)
               (lambda (loop timeout)
                 (declare (ignore loop))
                 (assert (= -1 timeout))
                 (assert (eq :flush (first events)))
                 (push :dispatch events)
                 (%defer-runtime-action runtime (lambda () (push :safe-point events)))
                 (request-runtime-stop runtime :test)
                 0))
         (run-runtime runtime)
         (assert (equal '(:safe-point :dispatch :flush) events))
         (format t "PASS: runtime flushes before blocking, drains deferred actions and stops without polling.~%"))
    (loop for name in names for original in originals do (setf (symbol-function name) original))))
