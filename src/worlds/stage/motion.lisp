;;;; Retargetable scalar motion.
;;;;
;;;; Every animated property owns a channel holding its displayed value and
;;;; velocity. Retargeting first samples the current state, so springs keep
;;;; their momentum and interrupted tweens continue from what is on screen.
;;;; Springs use the closed-form damped oscillator: sampling is exact and
;;;; independent of the frame rate, and settled channels request no frames.
;;;; Keyframe tracks are pure functions of time that animation layers sample on
;;;; top of a property's value.

(in-package #:ataxia.stage-world)

(defstruct (motion (:constructor make-motion
                       (kind &key stiffness damping mass duration ease points delay repeat rest)))
  "Immutable transition. EASE is a CSS cubic-bezier (X1 Y1 X2 Y2) or NIL for linear.
A :CURVE runs like a tween along POINTS, its progress sampled evenly over DURATION, so
any easing function the director can evaluate works. A :DECAY motion coasts with its
starting velocity and time constant DURATION, settling once less than REST remains.
Tweens and curves may REPEAT a number of extra times or :FOREVER, restarting from
their start."
  (kind :instant :type (member :instant :spring :tween :curve :decay) :read-only t)
  (stiffness 170d0 :type double-float :read-only t)
  (damping 26d0 :type double-float :read-only t)
  (mass 1d0 :type double-float :read-only t)
  (duration 0.25d0 :type double-float :read-only t)
  (ease nil :type list :read-only t)
  (points #() :type simple-vector :read-only t)
  (delay 0d0 :type double-float :read-only t)
  (repeat 0 :type (or (integer 0) (eql :forever)) :read-only t)
  (rest 0d0 :type double-float :read-only t))

(defun motion-loops-p (motion)
  (and motion (eq (motion-repeat motion) :forever)))

(defstruct (channel (:constructor %make-channel))
  (value 0d0 :type double-float)
  (velocity 0d0 :type double-float)
  (target 0d0 :type double-float)
  (motion nil :type (or null motion))
  (start-time 0d0 :type double-float)
  (start-value 0d0 :type double-float)
  (start-velocity 0d0 :type double-float)
  (tolerance 1d-3 :type double-float :read-only t))

(defun make-channel (value &optional (tolerance 1d-3))
  (let ((value (coerce value 'double-float)))
    (%make-channel :value value :target value
                   :tolerance (coerce tolerance 'double-float))))

(defun channel-active-p (channel)
  (not (null (channel-motion channel))))

(defun %spring-state (motion displacement velocity elapsed)
  "Displacement and velocity of a damped spring released ELAPSED seconds ago."
  (let* ((stiffness (motion-stiffness motion))
         (mass (motion-mass motion))
         (natural (sqrt (/ stiffness mass)))
         (ratio (/ (motion-damping motion) (* 2d0 (sqrt (* stiffness mass))))))
    (cond
      ((< (abs (- ratio 1d0)) 1d-6)
       (let ((decay (exp (- (* natural elapsed))))
             (slope (+ velocity (* natural displacement))))
         (values (* decay (+ displacement (* slope elapsed)))
                 (* decay (- velocity (* natural slope elapsed))))))
      ((< ratio 1d0)
       (let* ((attenuation (* ratio natural))
              (frequency (* natural (sqrt (- 1d0 (* ratio ratio)))))
              (decay (exp (- (* attenuation elapsed))))
              (sine-weight (/ (+ velocity (* attenuation displacement)) frequency))
              (cosine (cos (* frequency elapsed)))
              (sine (sin (* frequency elapsed))))
         (values (* decay (+ (* displacement cosine) (* sine-weight sine)))
                 (* decay (- (* (- (* sine-weight frequency) (* attenuation displacement)) cosine)
                             (* (+ (* displacement frequency) (* attenuation sine-weight)) sine))))))
      (t
       (let* ((root (sqrt (- (* ratio ratio) 1d0)))
              (slow (- (* natural (- ratio root))))
              (fast (- (* natural (+ ratio root))))
              (slow-weight (/ (- velocity (* fast displacement)) (- slow fast)))
              (fast-weight (- displacement slow-weight))
              (slow-term (* slow-weight (exp (* slow elapsed))))
              (fast-term (* fast-weight (exp (* fast elapsed)))))
         (values (+ slow-term fast-term)
                 (+ (* slow slow-term) (* fast fast-term))))))))

(defun %bezier (first second parameter)
  (let ((inverse (- 1d0 parameter)))
    (+ (* 3d0 inverse inverse parameter first)
       (* 3d0 inverse parameter parameter second)
       (* parameter parameter parameter))))

(defun %bezier-slope (first second parameter)
  (let ((inverse (- 1d0 parameter)))
    (+ (* 3d0 inverse inverse first)
       (* 6d0 inverse parameter (- second first))
       (* 3d0 parameter parameter (- 1d0 second)))))

(defun %eased-progress (ease progress)
  "Return EASE applied to PROGRESS and its derivative with respect to PROGRESS."
  (if (null ease)
      (values progress 1d0)
      (destructuring-bind (x1 y1 x2 y2) ease
        ;; Newton converges in a few steps for CSS curves; bisection covers
        ;; flat regions where the slope vanishes.
        (let ((parameter progress))
          (loop repeat 8
                for slope = (%bezier-slope x1 x2 parameter)
                until (< (abs slope) 1d-6)
                do (decf parameter (/ (- (%bezier x1 x2 parameter) progress) slope)))
          (unless (and (<= 0d0 parameter 1d0)
                       (< (abs (- (%bezier x1 x2 parameter) progress)) 1d-6))
            (let ((low 0d0) (high 1d0))
              (loop repeat 40
                    do (setf parameter (* 0.5d0 (+ low high)))
                       (if (< (%bezier x1 x2 parameter) progress)
                           (setf low parameter)
                           (setf high parameter)))))
          (let ((slope (%bezier-slope x1 x2 parameter)))
            (values (%bezier y1 y2 parameter)
                    (if (< (abs slope) 1d-9)
                        0d0
                        (/ (%bezier-slope y1 y2 parameter) slope))))))))

(defun %curve-progress (points progress)
  "Value at PROGRESS of POINTS, sampled evenly over 0..1, and its slope."
  (let* ((last (1- (length points)))
         (position (* (max 0d0 (min 1d0 progress)) last))
         (index (min (1- last) (floor position)))
         (low (svref points index))
         (high (svref points (1+ index))))
    (values (+ low (* (- high low) (- position index))) (* (- high low) last))))

(defun %tween-state (motion start target elapsed)
  "Value, velocity and completion of a possibly repeating tween or curve."
  (let* ((duration (motion-duration motion))
         (repeat (motion-repeat motion))
         (iteration (floor elapsed duration))
         (done-p (and (integerp repeat) (> iteration repeat))))
    (if done-p
        (values target 0d0 t)
        (multiple-value-bind (progress slope)
            (let ((fraction (/ (- elapsed (* iteration duration)) duration)))
              (if (eq (motion-kind motion) :curve)
                  (%curve-progress (motion-points motion) fraction)
                  (%eased-progress (motion-ease motion) fraction)))
          (let ((distance (- target start)))
            (values (+ start (* distance progress)) (/ (* distance slope) duration) nil))))))

(defun %motion-state (motion channel elapsed)
  "Value and velocity of CHANNEL's MOTION after ELAPSED seconds, or NIL once settled."
  (let ((target (channel-target channel))
        (start (channel-start-value channel))
        (tolerance (channel-tolerance channel)))
    (ecase (motion-kind motion)
      (:spring
       (multiple-value-bind (displacement velocity)
           (%spring-state motion (- start target) (channel-start-velocity channel) elapsed)
         (unless (and (< (abs displacement) tolerance)
                      (< (abs velocity) (* 20d0 tolerance)))
           (values (+ target displacement) velocity))))
      ((:tween :curve)
       (multiple-value-bind (value velocity done-p) (%tween-state motion start target elapsed)
         (unless done-p (values value velocity))))
      (:decay
       ;; x(t) = x0 + v0·τ·(1 - e^(-t/τ)); the target is the asymptote.
       (let* ((velocity (* (channel-start-velocity channel)
                           (exp (- (/ elapsed (motion-duration motion))))))
              (distance (* velocity (motion-duration motion))))
         (unless (< (abs distance) (max tolerance (motion-rest motion)))
           (values (- target distance) velocity)))))))

(defun channel-sample (channel time)
  "Advance CHANNEL to TIME. Return true while it is still moving."
  (let ((motion (channel-motion channel)))
    (when motion
      (let ((elapsed (- time (channel-start-time channel) (motion-delay motion))))
        (if (minusp elapsed)
            ;; A delayed motion holds its starting state until it begins.
            (setf (channel-value channel) (channel-start-value channel)
                  (channel-velocity channel) 0d0)
            (multiple-value-bind (value velocity) (%motion-state motion channel elapsed)
              (if value
                  (setf (channel-value channel) value
                        (channel-velocity channel) velocity)
                  (setf (channel-value channel) (channel-target channel)
                        (channel-velocity channel) 0d0
                        (channel-motion channel) nil)))))))
  (channel-active-p channel))

(defun channel-retarget (channel target motion time)
  "Move CHANNEL toward TARGET from its state at TIME. NIL or :INSTANT jumps."
  (let ((target (coerce target 'double-float)))
    (channel-sample channel time)
    (cond
      ((or (null motion) (eq (motion-kind motion) :instant))
       (setf (channel-value channel) target
             (channel-velocity channel) 0d0
             (channel-target channel) target
             (channel-motion channel) nil))
      ;; An unchanged destination keeps its current trajectory; restarting a
      ;; tween here would visibly stall every repeated commit.
      ((and (= target (channel-target channel))
            (or (channel-motion channel) (= target (channel-value channel))))
       nil)
      (t
       (setf (channel-target channel) target
             (channel-motion channel) motion
             (channel-start-time channel) time
             (channel-start-value channel) (channel-value channel)
             (channel-start-velocity channel) (channel-velocity channel)))))
  channel)

(defun channel-jump (channel value)
  "Show VALUE immediately and make it the destination, as direct manipulation does."
  (let ((value (coerce value 'double-float)))
    (setf (channel-value channel) value
          (channel-target channel) value
          (channel-velocity channel) 0d0
          (channel-motion channel) nil))
  channel)

(defun channel-fling (channel velocity time-constant rest time)
  "Coast from the displayed value with VELOCITY units per second, decaying with
TIME-CONSTANT until less than REST units remain."
  (channel-sample channel time)
  (let ((velocity (coerce velocity 'double-float))
        (motion (make-motion :decay :duration (coerce time-constant 'double-float)
                                    :rest (coerce rest 'double-float))))
    (setf (channel-start-time channel) time
          (channel-start-value channel) (channel-value channel)
          (channel-start-velocity channel) velocity
          (channel-velocity channel) velocity
          (channel-target channel) (+ (channel-value channel) (* velocity time-constant))
          (channel-motion channel) motion))
  channel)

(defun channel-inherit (channel value velocity motion time)
  "Continue CHANNEL from another channel's displayed VALUE and VELOCITY toward its own target."
  (setf (channel-value channel) (coerce value 'double-float)
        (channel-velocity channel) (coerce velocity 'double-float)
        (channel-motion channel) nil)
  (channel-retarget channel (channel-target channel) motion time))

;;; Keyframe tracks.

(defstruct (track (:constructor make-track
                      (keyframes offsets &key ease (duration 1d0) (delay 0d0) (iterations 1)
                                           (direction :normal))))
  "KEYFRAMES (numbers, or color vectors) at OFFSETS in 0..1 of each iteration,
run ITERATIONS times (or :FOREVER) of DURATION seconds after DELAY. EASE, a CSS
cubic-bezier or NIL, shapes each iteration's progress; values between keyframes are
linear. DIRECTION is :NORMAL, :REVERSE, :ALTERNATE or :ALTERNATE-REVERSE."
  (keyframes #() :type simple-vector :read-only t)
  (offsets #() :type simple-vector :read-only t)
  (ease nil :type list :read-only t)
  (duration 1d0 :type double-float :read-only t)
  (delay 0d0 :type double-float :read-only t)
  (iterations 1 :type (or (integer 0) (eql :forever)) :read-only t)
  (direction :normal :type (member :normal :reverse :alternate :alternate-reverse) :read-only t))

(defun track-endless-p (track)
  (eq (track-iterations track) :forever))

(defun %lerp-value (from to fraction)
  (if (vectorp from)
      (map 'vector (lambda (low high) (+ low (* (- high low) fraction))) from to)
      (+ from (* (- to from) fraction))))

(defun track-sample (track elapsed)
  "TRACK's value ELAPSED seconds after it started: :PENDING during its delay, :DONE
once its iterations have run."
  (let ((elapsed (- elapsed (track-delay track)))
        (duration (track-duration track)))
    (if (minusp elapsed)
        :pending
        (let ((iteration (floor elapsed duration))
              (iterations (track-iterations track)))
          (if (and (integerp iterations) (>= iteration iterations))
              :done
              (let* ((fraction (/ (- elapsed (* iteration duration)) duration))
                     (backward-p (ecase (track-direction track)
                                   (:normal nil)
                                   (:reverse t)
                                   (:alternate (oddp iteration))
                                   (:alternate-reverse (evenp iteration))))
                     (progress (%eased-progress (track-ease track)
                                                (if backward-p (- 1d0 fraction) fraction)))
                     (offsets (track-offsets track))
                     (keyframes (track-keyframes track))
                     (index (or (position-if (lambda (offset) (> offset progress)) offsets :start 1)
                                (1- (length offsets))))
                     (start (svref offsets (1- index)))
                     (span (- (svref offsets index) start)))
                ;; Easing that overshoots extrapolates the first or last segment, as CSS does.
                (%lerp-value (svref keyframes (1- index)) (svref keyframes index)
                             (if (plusp span) (/ (- progress start) span) 1d0))))))))
