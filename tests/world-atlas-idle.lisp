(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-atlas-world")
(in-package #:ataxia.atlas-world)

(defclass idle-ui (ataxia.kernel:drawable ataxia.kernel:interactable)
  ((delay :initform nil :accessor idle-delay)
   (active :initform nil :accessor idle-active)
   (callbacks :initform 0 :accessor idle-callbacks)))
(defvar *idle-services* 0)
(defmethod ataxia.world:ui-service-key ((component idle-ui)) :test-engine)
(defmethod ataxia.world:ui-service ((component idle-ui)) (incf *idle-services*))
(defmethod ataxia.world:ui-dispatch-callbacks ((component idle-ui)) (incf (idle-callbacks component)))
(defmethod ataxia.world:ui-next-update-delay ((component idle-ui)) (idle-delay component))
(defmethod ataxia.kernel:drawable-active-p ((component idle-ui)) (idle-active component))

(let* ((world (make-atlas-world))
       (first (make-instance 'idle-ui)) (second (make-instance 'idle-ui))
       (states (loop repeat 2
                     for output = (make-instance 'ataxia.kernel:kernel-output
                                                  :width 640 :height 480 :scale 1d0 :transform 0)
                     for state = (%make-atlas-output output)
                     do (setf (gethash output (%world-outputs world)) state)
                     collect state))
       (objects (loop for component in (list first second) for state in states
                      collect (%insert-scene-object world
                               (make-instance 'atlas-object :component component :width 100d0 :height 80d0
                                 :mapping (make-instance 'atlas-output-mapping :output-state state :x 0d0 :y 0d0)))))
       (names '(ataxia.runtime:update-event-loop-timer %request-output-state-frame))
       (originals (mapcar #'symbol-function names)) (delay nil) (frames nil))
  (unwind-protect
       (progn
         (setf (%world-component-timer world) :timer
               (symbol-function 'ataxia.runtime:update-event-loop-timer)
               (lambda (timer milliseconds) (assert (eq timer :timer)) (setf delay milliseconds))
               (symbol-function '%request-output-state-frame)
               (lambda (w state) (assert (eq world w)) (push state frames)))
         (%schedule-component-timer world)
         (assert (zerop delay)) (assert (null frames))
         (setf (idle-delay first) 250)
         (%schedule-component-timer world) (assert (= delay 250))
         (setf (idle-active first) t)
         (%schedule-component-timer world)
         ;; The output paces the animation; no extra 16 ms timer.
         (assert (= delay 250)) (assert (equal frames (list (first states))))
         (setf (idle-active first) nil (idle-delay first) 0 (idle-delay second) 80 frames nil)
         (%component-timer-fired world :timer)
         (assert (= *idle-services* 1))
         (assert (= (idle-callbacks first) (idle-callbacks second) 1))
         (assert (= delay 80)) (assert (equal frames (list (first states))))
         (setf (idle-delay first) nil (idle-delay second) nil frames nil)
         (%component-timer-fired world :timer)
         (assert (= *idle-services* 2))
         (assert (= (idle-callbacks first) (idle-callbacks second) 2))
         (assert (zerop delay)) (assert (null frames))
         (setf (idle-active first) t (%atlas-object-hidden-p (first objects)) t)
         (%schedule-component-timer world)
         (assert (zerop delay)) (assert (null frames))
         (format t "PASS: Atlas idle disarm, output-paced animation, per-output deadlines and callbacks without repaint.~%"))
    (loop for name in names for original in originals
          do (setf (symbol-function name) original))))
