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
                     (lambda () (scene-update scene 4 (object "color" #(1 0)) 0d0))
                     (lambda () (scene-insert scene 4 2 nil) (scene-insert scene 2 4 nil))))
    (assert (handler-case (progn (funcall bad) nil) (stage-protocol-error () t)))))
(format t "PASS: layout identity survives remounts, exits animate, invalid ops are rejected.~%")

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
                                     (object "op" "create" "id" 2 "type" "window"
                                             "props" (object "window" (stage-window-id window)
                                                             "x" 100 "y" 100 "width" 480 "height" 300
                                                             "originX" 0 "originY" 0))
                                     (object "op" "insert" "parent" 0 "id" 2)
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
               (10 (assert (search "pointer-enter seat0 300.0 180.0" (uiop:read-file-string log)))
                   (assert (received-p (format nil "\"type\":\"focus\",\"seat\":\"seat0\",\"window\":~D"
                                               (stage-window-id window))))
                   (pointer 900d0 650d0)
                   (button :pressed) (button :released))
               (11 (assert (received-p "\"name\":\"pointerdown\",\"button\":272,\"output\":\"HEADLESS-1\""))
                   (assert (received-p "\"world-x\":900.000000"))
                   (assert (received-p "\"name\":\"pointerup\""))
                   (setf frames (test-frames world)))
               ((12 13))
               ;; Settled scenes with static clients schedule no frames at all.
               (14 (assert (= frames (test-frames world)) () "~D idle frames"
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
           (assert (= phase 14) () "The session stopped in phase ~D." phase))
      (when client (ignore-errors (uiop:terminate-process client)))
      (ignore-errors (sb-bsd-sockets:socket-close director))
      (ataxia.kernel:destroy-kernel kernel :test)
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
(format t "PASS: handshake, fallback placement, configure, picking through transforms, ~
director events, text measurement, reservations and an idle settled scene.~%")
