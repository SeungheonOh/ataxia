;;;; Run: sbcl --script tests/metaworld-animation.lisp
(load (merge-pathnames "support.lisp" *load-truename*))
(in-package #:ataxia.infinite-world)

(defun animation-near (a b &optional (tolerance 1d-6))
  (assert (< (abs (- a b)) tolerance)))

;; A completion callback can chain the same channel. A replacement from an
;; update callback must survive, and suppress the replaced finish callback.
(let ((animator (ataxia.world:make-animator)) (subject (gensym)) (events nil))
  (flet ((next (target)
           (ataxia.world:start-animation
            animator target :test 1d0 1d0
            (lambda (object p) (declare (ignore object)) (push p events)))))
    (ataxia.world:start-animation
     animator subject :test 0d0 1d0
     (lambda (object p) (declare (ignore object p))) :finish #'next)
    (ataxia.world:advance-animations animator 1d0)
    (assert (ataxia.world:animations-active-p animator))
    (ataxia.world:advance-animations animator 1.5d0)
    (assert (equal events '(0.5d0)))
    (ataxia.world:advance-animations animator 2d0)
    (assert (not (ataxia.world:animations-active-p animator)))
    (setf events nil)
    (ataxia.world:start-animation
     animator subject :test 0d0 1d0
     (lambda (object p) (declare (ignore p)) (next object))
     :finish (lambda (object) (declare (ignore object)) (error "Replaced callback ran.")))
    (ataxia.world:advance-animations animator 1d0)
    (ataxia.world:advance-animations animator 1.5d0)
    (assert (equal events '(0.5d0)))))
(let ((animator (ataxia.world:make-animator)) (subject (gensym)))
  (ataxia.world:start-animation
   animator subject :cancelled 0d0 1d0
   (lambda (&rest args) (declare (ignore args)) (error "Cancelled callback ran.")))
  (ataxia.world:start-animation
   animator subject :first 0d0 1d0
   (lambda (object p)
     (declare (ignore p))
     (ataxia.world:cancel-subject-animations animator object)))
  (ataxia.world:advance-animations animator .5d0)
  (assert (not (ataxia.world:animations-active-p animator))))
(let ((animator (ataxia.world:make-animator)) (value nil))
  (ataxia.world:start-animation
   animator :test :repeat 0d0 1d0
   (lambda (object p) (declare (ignore object)) (setf value p))
   :delay .2d0 :repeat 1 :alternate-p t)
  (ataxia.world:advance-animations animator .1d0)
  (assert (null value))
  (ataxia.world:advance-animations animator .7d0)
  (animation-near value .5d0)
  (ataxia.world:advance-animations animator 1.7d0)
  (animation-near value .5d0)
  (ataxia.world:advance-animations animator 4d0)
  (assert (zerop value))
  (assert (not (ataxia.world:animations-active-p animator))))
(format t "PASS: animation chaining, replacement, callback cancellation, delay and skipped repeat cycles.~%")

(let* ((world (make-metaworld :state-file nil)) (clock 0d0)
       (names '(%now %request-all-frames))
       (saved (mapcar #'symbol-function names)))
  (unwind-protect
       (progn
         (setf (symbol-function '%now) (lambda () clock)
               (symbol-function '%request-all-frames) #'identity)
         ;; A reversal carries both derivatives; settling is exact and finite.
         (let ((subject (gensym)) (value '(0d0)))
           (flet ((update (object geometry) (declare (ignore object)) (setf value geometry)))
             (%meta-animate-to world subject :position value '(100d0) .22d0 #'update)
             (setf clock .08d0)
             (ataxia.world:advance-animations (%world-animator world) clock)
             (let* ((old (%meta-motion world subject :position))
                    (velocity (first (%meta-trajectory-velocity old)))
                    (acceleration (first (%meta-trajectory-acceleration old)))
                    (position (first value)))
               (%meta-animate-to world subject :position value '(-50d0) .22d0 #'update)
               (let ((new (%meta-motion world subject :position)))
                 (animation-near velocity (first (%meta-trajectory-velocity new)))
                 (animation-near acceleration (first (%meta-trajectory-acceleration new))))
               ;; Finite differences of the actual displayed path agree with
               ;; the old derivatives immediately after the reversal.
               (ataxia.world:advance-animations (%world-animator world) (+ clock 1d-6))
               (animation-near velocity (/ (- (first value) position) 1d-6) .02d0))
             (ataxia.world:advance-animations (%world-animator world) 1d0)
             (assert (equal value '(-50d0)))
             (assert (null (%meta-motion world subject :position)))))
         ;; Layout and material transitions on one object have independent
         ;; targets, derivatives and cancellation lifetimes.
         (let ((subject (gensym)) (position nil) (opacity nil))
           (setf clock 2d0)
           (%meta-animate-to world subject :position '(0d0) '(100d0) .22d0
                             (lambda (s v) (declare (ignore s)) (setf position v)))
           (%meta-animate-to world subject :opacity '(0d0) '(1d0) .16d0
                             (lambda (s v) (declare (ignore s)) (setf opacity v))
                             :bounds '((0d0 1d0)))
           (assert (= 1 (length (ataxia.world:animation-subjects (%world-animator world)))))
           (ataxia.world:advance-animations (%world-animator world) 2.08d0)
           (assert (and (plusp (first position)) (plusp (first opacity))))
           (%meta-cancel-motion world subject :opacity)
           (let ((shown opacity))
             (ataxia.world:advance-animations (%world-animator world) 3d0)
             (assert (equal position '(100d0)))
             (assert (equal shown opacity)))
           (assert (zerop (hash-table-count (%meta-motions world)))))
         ;; Repeated bounded reversals never produce invalid material values.
         (let ((subject (gensym)) (value '(0d0)))
           (loop for i below 80 do
             (setf clock (+ 4d0 (* i .013d0)))
             (ataxia.world:advance-animations (%world-animator world) clock)
             (assert (<= -1d-9 (first value) (+ 1d0 1d-9)))
             (%meta-animate-to world subject :opacity value (list (if (evenp i) 1d0 0d0)) .16d0
                               (lambda (s v) (declare (ignore s)) (setf value v))
                               :bounds '((0d0 1d0))))
           (ataxia.world:advance-animations (%world-animator world) 8d0)
           (assert (zerop (first value))))
         ;; Absolute-time sampling gives identical paths at different refresh
         ;; rates, including a missed frame. Endpoints do not drift with cadence.
         (let ((reference nil))
           (dolist (hz '(60 90 120 144 240))
             (let ((subject (gensym)) (value '(0d0 100d0)))
               (setf clock 10d0)
               (%meta-animate-to world subject :position value '(900d0 -80d0) .28d0
                                 (lambda (s v) (declare (ignore s)) (setf value v)))
               (loop for i from 1 below (ceiling (* hz .1d0))
                     do (ataxia.world:advance-animations (%world-animator world) (+ clock (/ i (float hz 1d0)))))
               (ataxia.world:advance-animations (%world-animator world) 10.1d0)
               (if reference (mapc #'animation-near reference value) (setf reference value))
               (ataxia.world:advance-animations (%world-animator world) 11d0)
               (assert (equal value '(900d0 -80d0))))))
         (format t "PASS: reversal derivative continuity, independent channels, bounded fades, and 60–240 Hz/missed-frame equivalence.~%"))
    (loop for name in names for original in saved do (setf (symbol-function name) original))))

;; An ordinary transition starts and ends without a velocity/acceleration step.
(multiple-value-bind (p v a) (%meta-motion-sample '(0d0) '(100d0) '(0d0) .22d0 0d0)
  (assert (equal p '(0d0))) (assert (equal v '(0d0))) (assert (equal a '(0d0))))
(multiple-value-bind (p v a) (%meta-motion-sample '(0d0) '(100d0) '(0d0) .22d0 1d0)
  (assert (equal p '(100d0))) (assert (equal v '(0d0))) (assert (equal a '(0d0))))
(format t "PASS: exact endpoints with zero speed and acceleration.~%")

;; Animation damage scales with animated windows, not every open application.
(let* ((world (make-infinite-world)) (state (%make-canvas-output :output))
       (windows (loop repeat 1000 collect
                 (make-instance 'canvas-window :application (make-instance 'ataxia.kernel:wayland-application))))
       (names '(%window-buffer-coverage %update-window-membership %request-all-frames))
       (saved (mapcar #'symbol-function names)) (queries 0))
  (unwind-protect
       (progn
         (setf (%world-stacking world) windows
               (gethash :output (%world-outputs world)) state
               (symbol-function '%window-buffer-coverage)
               (lambda (output window)
                 (declare (ignore output))
                 (assert (member window (subseq windows 0 10)))
                 (incf queries)
                 (ataxia.world:make-rectangle 0 0 100 100))
               (symbol-function '%update-window-membership)
               (lambda (&rest args) (declare (ignore args)))
               (symbol-function '%request-all-frames) #'identity)
         (%advance-world-animations world 0d0)
         (assert (zerop queries))
         (dolist (window (subseq windows 0 10))
           (ataxia.world:start-animation
            (%world-animator world) window :opacity 0d0 .2d0
            (lambda (target p) (setf (canvas-window-opacity target) p))))
         (%advance-world-animations world .1d0)
         (assert (= queries 20))
         (%advance-world-animations world .1d0)
         (assert (= queries 20))
         (%advance-world-animations world 1d0)
         (assert (= queries 40))
         (%advance-world-animations world 2d0)
         (assert (= queries 40))
         (format t "PASS: only 10 animated windows need coverage sampling among 1,000 windows; duplicate and idle frames skip it.~%"))
    (loop for name in names for original in saved do (setf (symbol-function name) original))))
