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

;;;; Offscreen commits must not wake outputs; visible changes retain repainting.
(in-package #:ataxia.infinite-world)
(defclass idle-test-application (ataxia.kernel:wayland-application) ())
(defmethod ataxia.kernel:drawable-local-bounds ((app idle-test-application))
  (values 0 0 100 100))
(let* ((world (make-infinite-world))
       (app (make-instance 'idle-test-application))
       (window (make-instance 'canvas-window :application app :x 100d0 :y 20d0 :width 100d0 :height 100d0))
       (states (loop for camera in '(0d0 400d0)
                     for output = (make-instance 'ataxia.kernel:kernel-output :width 320 :height 200 :scale 1d0 :transform 0)
                     for state = (%make-canvas-output output)
                     do (setf (%canvas-output-buffer-width state) 320 (%canvas-output-buffer-height state) 200
                              (%canvas-output-camera-x state) camera
                              (gethash output (%world-outputs world)) state)
                     collect state))
       (names '(%update-window-membership %request-output-state-frame))
       (originals (mapcar #'symbol-function names)) (requested nil))
  (unwind-protect
       (progn
         (setf (%canvas-window-mapped-p window) t (gethash app (%world-windows world)) window
               (symbol-function '%update-window-membership) (lambda (&rest args) (declare (ignore args)))
               (symbol-function '%request-output-state-frame)
               (lambda (w state) (assert (eq w world)) (push state requested)))
         (labels ((commit (&optional (damage (list (ataxia.kernel:make-frame-damage-rectangle 0 0 100 100))))
                    (setf requested nil (slot-value world 'damage) (ataxia.world:make-damage-tracker))
                    (ataxia.kernel:world-object-invalidated world app (ataxia.kernel:make-drawable-invalidation 1 damage))))
           (commit)
           (assert (equal requested (list (first states))))
           (setf (canvas-window-x window) 500d0) (commit)
           (assert (equal requested (list (second states))))
           (setf (canvas-window-x window) 900d0) (commit)
           (assert (null requested))
           (assert (every (lambda (state) (not (ataxia.world:damage-pending-p (%world-damage world) (%canvas-output-output state)))) states))
           (setf (canvas-window-x window) 100d0 (%canvas-window-hidden-p window) t) (commit)
           (assert (null requested))
           (setf (%canvas-window-hidden-p window) nil) (commit nil)
           (assert (equal requested (list (first states))))
           ;; A partially visible window's damage can still be fully offscreen.
           (setf (canvas-window-x window) 300d0)
           (commit (list (ataxia.kernel:make-frame-damage-rectangle 50 0 50 100)))
           (assert (null requested)))
         (format t "PASS: client damage wakes only affected outputs; hidden/offscreen commits sleep; visible callback-only commits remain scheduled.~%"))
    (loop for name in names for original in originals do (setf (symbol-function name) original))))

;;;; Buffer-only commits avoid a duplicate atomic test; failures still propagate.
(in-package #:ataxia.kernel)
(let* ((kernel (make-instance 'kernel :world (make-instance 'world)))
       (output (make-instance 'kernel-output :kernel kernel :runtime-object :output))
       (result (make-instance 'world-frame-result :damage nil))
       (names '(ataxia.runtime:create-output-state ataxia.runtime:output-state-set-buffer
                ataxia.runtime:output-state-set-damage ataxia.runtime:output-test-state
                ataxia.runtime:output-commit-state ataxia.runtime:destroy-output-state
                %refresh-output-object %notify-presented-surfaces %guard-kernel-operation))
       (originals (mapcar #'symbol-function names)) (success t) (events nil))
  (unwind-protect
       (progn
         (dolist (name names)
           (setf (symbol-function name) (lambda (&rest args) (declare (ignore args)))))
         (setf (symbol-function 'ataxia.runtime:create-output-state)
               (lambda (out) (assert (eq out :output)) :state)
               (symbol-function 'ataxia.runtime:output-test-state)
               (lambda (&rest args) (declare (ignore args)) (error "Buffer commit must not issue a duplicate test."))
               (symbol-function 'ataxia.runtime:output-commit-state)
               (lambda (out state) (assert (eq out :output)) (assert (eq state :state)) (push :commit events) success)
               (symbol-function 'ataxia.runtime:destroy-output-state)
               (lambda (state) (assert (eq state :state)) (push :destroy events))
               (symbol-function '%notify-presented-surfaces)
               (lambda (&rest args) (declare (ignore args)) (push :presented events))
               (symbol-function '%guard-kernel-operation)
               (lambda (k world operation thunk)
                 (declare (ignore world thunk)) (assert (eq k kernel)) (push operation events)))
         (assert (%commit-world-frame output :buffer result))
         (assert (equal (reverse events) '(:commit world-frame-committed :presented :destroy)))
         (setf success nil events nil)
         (assert (null (%commit-world-frame output :buffer result)))
         (assert (equal (reverse events) '(:commit world-frame-failed :destroy)))
         (format t "PASS: one native commit per frame; failure notification and native-state cleanup remain intact.~%"))
    (loop for name in names for original in originals do (setf (symbol-function name) original))))
