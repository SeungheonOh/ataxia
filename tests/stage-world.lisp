;;;; Stage World: motion, scene commits and a headless director session.
;;;; Run: make test-stage (needs the test client and synthetic input library)
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-stage-world")
(asdf:load-system "ataxia-world/synthetic-input")
(in-package #:ataxia.stage-world)

(defun near (a b &optional (tolerance 1d-6))
  (assert (< (abs (- a b)) tolerance) () "~F is not near ~F" a b))

(defun object (&rest fields)
  (let ((table (make-hash-table :test #'equal)))
    (loop for (key value) on fields by #'cddr do (setf (gethash key table) value))
    table))

;;; Springs settle exactly, and retargeting keeps position and velocity continuous.
(let ((channel (make-channel 0d0 1d-2))
      (spring (make-motion :spring :stiffness 170d0 :damping 26d0)))
  (channel-retarget channel 100d0 spring 0d0)
  (channel-sample channel 0.1d0)
  (let ((value (channel-value channel)) (velocity (channel-velocity channel)))
    (assert (< 0d0 value 100d0))
    (channel-retarget channel -50d0 spring 0.1d0)
    (near value (channel-value channel))
    (near velocity (channel-velocity channel))
    (channel-sample channel 0.1001d0)
    (assert (< (abs (- (channel-value channel) value)) 0.1d0)))
  (assert (not (channel-sample channel 5d0)))
  (assert (= -50d0 (channel-value channel)))
  (let ((tween (make-motion :tween :duration 0.5d0 :ease '(0.42d0 0d0 0.58d0 1d0))))
    (channel-retarget channel 0d0 tween 5d0)
    (channel-sample channel 5.25d0)
    (near -25d0 (channel-value channel) 1d-3)
    (assert (not (channel-sample channel 5.5d0)))
    (assert (zerop (channel-value channel)))))
(format t "PASS: closed-form springs, continuous retargeting and eased tweens.~%")

;;; A remount hands displayed motion to its replacement; unclaimed exits play out.
(let ((scene (make-scene))
      (spring (object "default" (object "type" "spring"))))
  (scene-create scene 1 "rect" (object "layoutId" "card" "x" 0 "width" 10 "height" 10
                                       "transition" spring) 0d0)
  (scene-insert scene 0 1 nil)
  (scene-create scene 2 "group" (object) 0d0)
  (scene-insert scene 0 2 nil)
  (scene-create scene 3 "rect" (object "width" 10 "height" 10 "opacity" 1 "transition" spring
                                       "exit" (object "opacity" 0)) 0d0)
  (scene-insert scene 2 3 nil)
  (scene-finish-commit scene 0d0)
  (scene-update scene 1 (object "x" 100) 0d0)
  (scene-advance scene 0.1d0)
  (let ((shown (node-number (scene-node scene 1) :x)))
    ;; Hot reload: the old tree goes, a new card with the same identity arrives.
    (scene-remove scene 0 1)
    (scene-create scene 4 "rect" (object "layoutId" "card" "x" 300 "width" 10 "height" 10
                                         "transition" spring) 0.1d0)
    (scene-insert scene 0 4 nil)
    (scene-remove scene 2 3)
    (scene-finish-commit scene 0.1d0)
    (near shown (node-number (scene-node scene 4) :x))
    (assert (scene-moving-p scene))
    (let ((ghost (first (scene-exiting scene))))
      (assert (and ghost (= 3 (stage-node-id ghost)) (eq :exiting (stage-node-state ghost))))
      (assert (scene-advance scene 0.2d0))
      (scene-advance scene 10d0)
      (assert (eq :dead (stage-node-state ghost))))
    (assert (= 300d0 (node-number (scene-node scene 4) :x)))
    (assert (equal '(2 4) (mapcar #'stage-node-id (stage-node-children (scene-root scene))))))
  (dolist (bad (list (lambda () (scene-create scene 9 "rect" (object "zoom" 2) 0d0))
                     (lambda () (scene-create scene 9 "sprite" (object) 0d0))
                     (lambda () (scene-update scene 4 (object "x" 50 "color" #(1 0)) 0d0))
                     (lambda () (scene-insert scene 4 2 nil) (scene-insert scene 2 4 nil))))
    (assert (handler-case (progn (funcall bad) nil) (stage-protocol-error () t))))
  ;; A rejected op changes nothing, not even the values it named before the bad one.
  (assert (= 300d0 (node-prop (scene-node scene 4) :x))))
;; Under another parent, the new node continues from where the old one was shown.
(let ((scene (make-scene))
      (card (lambda (x) (object "layoutId" "card" "x" x "y" 20 "width" 10 "height" 10
                                "transition" (object "default" (object "type" "spring"))))))
  (scene-create scene 1 "group" (object "x" 500 "y" 40) 0d0)
  (scene-insert scene 0 1 nil)
  (scene-create scene 2 "rect" (funcall card 10) 0d0)
  (scene-insert scene 1 2 nil)
  (scene-finish-commit scene 0d0)
  (scene-remove scene 1 2)
  (scene-create scene 3 "rect" (funcall card 900) 0d0)
  (scene-insert scene 0 3 nil)
  (scene-finish-commit scene 0d0)
  (near 510d0 (node-number (scene-node scene 3) :x))
  (near 60d0 (node-number (scene-node scene 3) :y)))
(format t "PASS: layout identity survives remounts, even under another parent; exits animate, ~
invalid ops change nothing.~%")

;;; Keyframe layers compose over values; curves and effect uniforms animate like props.
(let ((scene (make-scene))
      (shake (object "id" "shake" "property" "x" "keyframes" #(0 10 -10 0) "duration" 1
                     "composite" "add")))
  (scene-create scene 1 "rect" (object "x" 100 "animate" (vector shake)) 0d0)
  (scene-create scene 2 "group" (object "shader" "" "uniforms" (object "progress" 1)
                                         "initial" (object "uniforms" (object "progress" 0))
                                         "exit" (object "uniforms" (object "progress" 0))
                                         "transition" (object "uniforms" (object "type" "curve"
                                                                                 "duration" 1
                                                                                 "points" #(0 1.5 1))))
                0d0)
  (scene-insert scene 0 1 nil)
  (scene-insert scene 0 2 nil)
  (scene-finish-commit scene 0d0)
  (flet ((progress () (channel-value (svref (cdr (first (stage-node-uniforms (scene-node scene 2)))) 0))))
    (scene-advance scene 0.25d0)
    (near 107.5d0 (node-number (scene-node scene 1) :x))
    (near 0.75d0 (progress))
    (assert (scene-settling-p scene))
    (scene-advance scene 2d0)
    (near 100d0 (node-number (scene-node scene 1) :x))
    (near 1d0 (progress))
    ;; Declared again beside a new animation, the finished one does not replay.
    (scene-update scene 1 (object "animate"
                                  (vector shake (object "id" "spin" "property" "transform"
                                                        "keyframes" #(#(#("rotate" 0 0 1 0))
                                                                      #(#("rotate" 0 0 1 1)))
                                                        "duration" 1 "iterations" "forever")))
                  2d0)
    (scene-advance scene 2.5d0)
    (near 100d0 (node-number (scene-node scene 1) :x))
    (near 0.5d0 (svref (transform-list-parameters (node-transform-list (scene-node scene 1))) 3))
    (assert (not (scene-settling-p scene)))
    (let ((effect (scene-node scene 2)))
      (scene-remove scene 0 2)
      (scene-finish-commit scene 3d0)
      (assert (eq :exiting (stage-node-state effect)))
      (scene-advance scene 5d0)
      (assert (eq :dead (stage-node-state effect)))))
  (assert (handler-case (scene-update scene 1 (object "uniforms" (object "x" 1)) 0d0)
            (stage-protocol-error () t))))
(format t "PASS: keyframe layers, curve transitions and animated effect uniforms.~%")

;;; Transforms animate function by function, CSS padding the shorter list with
;;; functions doing nothing; other lists apply at once. They compose in 3D.
(let ((scene (make-scene))
      (tween (object "type" "tween" "duration" 1 "ease" #(0 0 1 1))))
  (flet ((transform (&rest functions) (coerce functions 'vector))
         (angle () (svref (transform-list-parameters (node-transform-list (scene-node scene 1))) 4)))
    (scene-create scene 1 "rect" (object "width" 100 "height" 100 "transition" (object "default" tween))
                  0d0)
    (scene-insert scene 0 1 nil)
    (scene-finish-commit scene 0d0)
    (scene-update scene 1 (object "transform" (transform #("perspective" 500) #("rotate" 0 1 0 1)))
                  0d0)
    (scene-advance scene 0.5d0)
    ;; Half way; a perspective moves through its strength, 1/1000, not its distance.
    (near 0.5d0 (angle))
    (near 0.001d0 (svref (transform-list-parameters (node-transform-list (scene-node scene 1))) 0))
    (scene-update scene 1 (object "transform" (transform #("scale" 2 2 1))) 1d0)
    (assert (equal '(:scale) (transform-list-kinds (node-transform-list (scene-node scene 1)))))
    ;; Turned 69 degrees about y and seen from 500 away, the right edge recedes.
    (scene-update scene 1 (object "transform" (transform #("perspective" 500) #("rotate" 0 1 0 1.2))
                                  "transition" (object "default" (object "type" "instant")))
                  2d0)
    (multiple-value-bind (x) (transform-apply (matrix-plane (node-local-matrix (scene-node scene 1) 100 100))
                                              100 50)
      (assert (< 50d0 x 100d0)))
    ;; Still facing the viewer; turned past a right angle it shows its back.
    (assert (plusp (transform-determinant (matrix-plane (node-local-matrix (scene-node scene 1) 100 100)))))
    (scene-update scene 1 (object "transform" (transform #("perspective" 500) #("rotate" 0 1 0 2.5))) 2d0)
    (assert (minusp (transform-determinant (matrix-plane (node-local-matrix (scene-node scene 1) 100 100)))))
    (assert (handler-case (scene-update scene 1 (object "transform" (transform #("spin" 1))) 3d0)
              (stage-protocol-error () t)))))
(format t "PASS: transforms animate function by function, compose in 3D and show their backs.~%")

;;; Damage: a reorder damages only what moved; a blur area is repainted whole, in one pass.
(assert (equal '(:a) (%reordered (list (list 1 :b) (list 2 :c) (list 0 :a) (list 3 :d)))))
(flet ((rectangle (x y width height) (ataxia.world:make-rectangle x y width height)))
  (let* ((glass (%make-item '(:glass) (rectangle 0 0 100 20) nil nil))
         (items (list glass))
         (cursor (rectangle 50 10 10 30)))
    (setf (item-blur-area glass) (item-bounds glass))
    (let ((passes (%blur-passes (list cursor) items 200 200)))
      (assert (member (rectangle 0 0 100 20) passes :test #'equalp))
      (assert (= (+ (* 100 20) (* 10 20)) (reduce #'+ passes :key #'ataxia.world:rectangle-area))))
    (assert (equalp (list (rectangle 0 0 200 200))
                    (%blur-passes (list (rectangle 0 0 200 200)) items 200 200)))
    (assert (equalp (list cursor) (%blur-passes (list cursor) nil 200 200))))
  ;; Opaque items above cut bands out of a large one; one covering no whole pixel cuts nothing.
  (assert (null (%covered-box (rectangle 10.2d0 10.2d0 0.5d0 0.5d0))))
  (let ((parts (%visible-boxes '(0 0 100 100) (list (cons 1 (%covered-box (rectangle 20 30 50 40)))) 0)))
    (assert (= (- (* 100 100) (* 50 40))
               (reduce #'+ parts :key (lambda (part) (* (- (third part) (first part)) (- (fourth part) (second part)))))))
    (assert (every (lambda (part) (and (< (first part) (third part)) (< (second part) (fourth part)))) parts))))
(format t "PASS: damage reorders, blur passes and occlusion cuts.~%")

;;; A director session against real Wayland clients on the headless backend.
(defclass stage-test-world (stage-world)
  ((frames :initform 0 :accessor test-frames)))

(defmethod ataxia.kernel:world-render :after ((world stage-test-world) lease)
  (declare (ignore lease))
  (incf (test-frames world)))

(let* ((root (uiop:ensure-directory-pathname
              (format nil "/tmp/ataxia-stage-test-~D" (sb-posix:getpid))))
       (socket (namestring (merge-pathnames "stage.sock" (ensure-directories-exist root))))
       (log (namestring (merge-pathnames "client.log" root)))
       (world (make-instance 'stage-test-world :socket-path socket))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                                  :headless-width 1000 :headless-height 700))
       (runtime (ataxia.kernel:kernel-runtime kernel))
       (director (make-instance 'sb-bsd-sockets:local-socket :type :stream))
       (received "") (client nil) (window nil) (phase 0) (frames 0))
  (labels ((send (&rest message)
             (let ((octets (sb-ext:string-to-octets
                            (format nil "~A~%" (ataxia.world.wire:encode message)))))
               (sb-bsd-sockets:socket-send director octets nil)))
           (receive ()
             (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8))))
               (loop for count = (nth-value 1 (sb-bsd-sockets:socket-receive director buffer nil))
                     while (and count (plusp count))
                     do (setf received (concatenate 'string received
                                                    (sb-ext:octets-to-string buffer :end count))))))
           (received-p (text) (search text received))
           (pointer (x y)
             (let ((seat-state (%default-seat-state world)))
               (ataxia.kernel:world-cursor-motion
                world (stage-seat-seat seat-state)
                (ataxia.kernel:make-cursor-motion-input
                 :delta-x (- x (stage-seat-x seat-state)) :delta-y (- y (stage-seat-y seat-state))))))
           (button (state)
             (ataxia.kernel:world-cursor-button
              world (stage-seat-seat (%default-seat-state world))
              (ataxia.kernel:make-cursor-button-input :code 272 :state state)))
           (step-session ()
             (receive)
             (ecase (incf phase)
               (1 (assert (received-p "\"type\":\"welcome\""))
                  (assert (received-p "\"name\":\"HEADLESS-1\"")))
               ((2 3 4 5 6 7 8)
                (when (received-p "\"mapped\":true")
                  (setf window (loop for candidate being the hash-values of (%windows world)
                                     return candidate))
                  ;; Before the director's first commit the window is still reachable.
                  (assert (stage-window-fallback window))
                  (send :type "commit"
                        :ops (vector (object "op" "reset")
                                     (object "op" "create" "id" 1 "type" "background"
                                             "props" (object "color" #(0.9 0.9 0.9 1)
                                                             "handlers" #("pointerdown" "pointerup")))
                                     (object "op" "insert" "parent" 0 "id" 1)
                                     ;; The window draws through an effect of its own.
                                     (object "op" "create" "id" 2 "type" "window"
                                             "props" (object "window" (stage-window-id window)
                                                             "x" 100 "y" 100 "width" 480 "height" 300
                                                             "originX" 0 "originY" 0 "local" t
                                                             "shader" "vec4 effect(vec2 p) { return content(p); }"))
                                     (object "op" "insert" "parent" 0 "id" 2)
                                     (object "op" "create" "id" 5 "type" "group"
                                             "props" (object "x" 600 "y" 400 "width" 100 "height" 100
                                                             "shader" "vec4 effect(vec2 p) { return tint * content(p).a; }"
                                                             "uniforms" (object "tint" #(0 1 0 1))))
                                     (object "op" "insert" "parent" 0 "id" 5)
                                     (object "op" "create" "id" 7 "type" "rect"
                                             "props" (object "width" 100 "height" 100
                                                             "color" #(1 1 1 1)))
                                     (object "op" "insert" "parent" 5 "id" 7)
                                     (object "op" "create" "id" 3 "type" "text"
                                             "props" (object "text" "Stage" "fontSize" 20
                                                             "handlers" #("measure")))
                                     (object "op" "insert" "parent" 0 "id" 3)
                                     (object "op" "create" "id" 4 "type" "reserve"
                                             "props" (object "top" 40))
                                     (object "op" "insert" "parent" 0 "id" 4)))
                  (setf phase 8)))
               (9 (assert window () "The test client never mapped.")
                  (assert (null (stage-window-fallback window)))
                  (assert (equal '(480 . 300) (stage-window-configured window)))
                  ;; Pango measured the label as soon as it was declared.
                  (assert (received-p "\"node\":3,\"name\":\"measure\",\"width\":"))
                  ;; The reserved strip leaves the work area, and the director hears of it.
                  (assert (= 40 (nth-value 1 (ataxia.world:world-output-work-area
                                               world (first (ataxia.world:world-outputs world))))))
                  (assert (received-p "\"work-area\":{\"x\":0.000000,\"y\":40.000000"))
                  ;; The window's center in its 600x360 buffer, drawn at 480x300.
                  (pointer 340d0 250d0)
                  (button :pressed) (button :released))
               ;; The pointer may have been over the window as it appeared, entering it then.
               (10 (assert (or (search "pointer-enter seat0 300.0 180.0" (uiop:read-file-string log))
                               (search "motion seat0 300.0 180.0" (uiop:read-file-string log))))
                   (assert (received-p (format nil "\"type\":\"focus\",\"seat\":\"seat0\",\"window\":~D"
                                               (stage-window-id window))))
                   (pointer 900d0 650d0)
                   (button :pressed) (button :released))
               (11 (assert (received-p "\"name\":\"pointerdown\",\"button\":272,\"output\":\"HEADLESS-1\""))
                   (assert (received-p "\"world-x\":900.000000"))
                   (assert (received-p "\"name\":\"pointerup\""))
                   (send :type "capture" :id 9 :region (object "x" 620 "y" 420 "width" 8 "height" 8)))
               ;; The effect turned its white content into its green uniform.
               (12 (let* ((start (+ (search "\"path\":\"" received) 8))
                          (path (subseq received start (position #\" received :start start)))
                          (pixels (with-open-file (in path :element-type '(unsigned-byte 8))
                                    (let ((octets (make-array 4 :element-type '(unsigned-byte 8))))
                                      (read-sequence octets in)
                                      octets))))
                     (delete-file path)
                     (assert (equalp pixels #(0 255 0 255)) () "Effect pixel ~A" pixels))
                   ;; Tilted in perspective, the window still takes input where it shows.
                   (send :type "commit"
                         :ops (vector (object "op" "set" "id" 2
                                              "props" (object "transform"
                                                              #(#("perspective" 900)
                                                                #("rotate" 0 1 0 0.5)
                                                                #("rotate" 1 0 0 -0.3)
                                                                #("rotate" 0 0 1 0.2))
                                                              "originX" 0.5 "originY" 0.5)))))
               (13 (let ((to-screen (first (gethash window (stage-output-window-transforms
                                                            (first (%outputs world)))))))
                     (assert (plusp (abs (transform-g to-screen))))
                     (multiple-value-call #'pointer (transform-apply to-screen 450 90))
                     (multiple-value-call #'pointer (transform-apply to-screen 120 300))))
               (14 (let ((log (uiop:read-file-string log)))
                     (assert (search "pointer-enter seat0 450.0 90.0" log))
                     (assert (search "motion seat0 120.0 300.0" log)))
                   (setf frames (test-frames world)))
               ((15))
               ;; Settled scenes with static clients schedule no frames at all.
               (16 (assert (= frames (test-frames world)) () "~D idle frames"
                           (- (test-frames world) frames))
                   (ataxia.kernel:request-kernel-stop kernel)))))
    (unwind-protect
         (progn
           (ataxia.kernel:start-kernel kernel)
           ;; Headless seats have no pointer until a device is registered.
           (ataxia.kernel:register-input-device
            kernel (ataxia.world.synthetic-input:create-synthetic-input runtime :pointer "Stage pointer")
            :seat (first (ataxia.kernel:kernel-seats kernel)))
           (sb-bsd-sockets:socket-connect director socket)
           (setf (sb-bsd-sockets:non-blocking-mode director) t)
           (send :type "hello" :protocol 1)
           (setf client (uiop:launch-program
                         (list "env" (format nil "WAYLAND_DISPLAY=~A"
                                             (ataxia.runtime:runtime-socket-name runtime))
                               "ATAXIA_TEST_TITLE=stage" "ATAXIA_TEST_SECONDS=20"
                               "build/computer-use-client" log)))
           (let ((timer (ataxia.runtime:add-event-loop-timer
                         runtime (lambda (source)
                                   (step-session)
                                   (ataxia.runtime:update-event-loop-timer source 200)
                                   0))))
             (ataxia.runtime:update-event-loop-timer timer 200))
           (ataxia.kernel:run-kernel kernel :run-for 15)
           (assert (= phase 16) () "The session stopped in phase ~D." phase))
      (when client (ignore-errors (uiop:terminate-process client)))
      (ignore-errors (sb-bsd-sockets:socket-close director))
      (ataxia.kernel:destroy-kernel kernel :test)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
(format t "PASS: handshake, fallback placement, configure, picking through transforms, ~
perspective and effects, effect shaders, director events, text measurement, reservations and an ~
idle settled scene.~%")
