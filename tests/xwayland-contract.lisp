;;;; X11 content must work through the ordinary drawable/interactable path.
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-infinite-world")
(asdf:load-system "ataxia-xwayland")
(asdf:load-system "ataxia-world/synthetic-input")
(in-package #:ataxia.infinite-world)

(defclass x11-contract-world (infinite-world)
  ((pixel-check :initform nil :accessor x11-pixel-check)))
(defmethod ataxia.kernel:world-render :after ((world x11-contract-world) lease)
  (declare (ignore lease))
  (when (x11-pixel-check world)
    (funcall (x11-pixel-check world))
    (setf (x11-pixel-check world) nil)))

(let* ((world (make-instance 'x11-contract-world))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                                  :headless-width 1000 :headless-height 700))
       (runtime (ataxia.kernel:kernel-runtime kernel))
       (client nil) (devices nil) (seat nil) (human nil) (output nil)
       (window nil) (app nil) (phase 0)
       (log #P"/tmp/ataxia-x11-contract.log"))
  (labels ((events () (uiop:read-file-string log))
           (screen-point (x y)
             (multiple-value-bind (cx cy)
                 (%world-to-canvas output (+ (canvas-window-x window) x)
                                          (+ (canvas-window-y window) y))
               (%canvas-to-screen output cx cy)))
           (at (x y)
             (multiple-value-bind (sx sy) (screen-point x y)
               (ataxia.kernel:world-cursor-motion world seat
                 (ataxia.kernel:make-cursor-motion-input
                   :absolute-p t :x (/ sx 1000d0) :y (/ sy 700d0))))
             (ataxia.runtime:seat-pointer-notify-frame (ataxia.kernel:seat-runtime-object seat)))
           (button (state)
             (ataxia.kernel:world-cursor-button world seat
               (ataxia.kernel:make-cursor-button-input :code 272 :state state))
             (ataxia.runtime:seat-pointer-notify-frame (ataxia.kernel:seat-runtime-object seat)))
           (pixel (x y expected)
             (multiple-value-bind (sx sy) (screen-point x y)
               (multiple-value-bind (bx by) (%screen-point-to-buffer output sx sy)
                 (cffi:with-foreign-object (rgba :uint8 4)
                   (cffi:foreign-funcall "glReadPixels" :int (floor bx) :int (floor by)
                     :int 1 :int 1 :uint #x1908 :uint #x1401 :pointer rgba :void)
                   (let ((actual (loop for i below 3 collect (cffi:mem-aref rgba :uint8 i))))
                     (assert (equal expected actual) () "Pixel ~S: wanted ~S, got ~S" (list x y) expected actual))))))
           (pixels ()
             (setf (x11-pixel-check world)
                   (lambda ()
                     (pixel 20 20 '(51 102 204))
                     ;; The popup extends outside the application's root bounds.
                     (pixel 510 80 '(204 102 51))))
             (%full-damage world output)))
    (unwind-protect
         (progn
           (ataxia.kernel:start-kernel kernel)
           (setf seat (first (ataxia.kernel:kernel-seats kernel))
                 human (gethash seat (%world-seats world))
                 output (%first-output-state world))
           (dolist (kind '(:pointer :keyboard))
             (let ((device (ataxia.world.synthetic-input:create-synthetic-input runtime kind "X11 contract fixture")))
               (push device devices)
               (ataxia.kernel:register-input-device kernel device :seat seat)))
           ;; Startup is the only X11-specific World-facing operation.
           (ataxia.kernel:enable-xwayland kernel)
           (setf client
                 (uiop:launch-program
                  (list "env" (format nil "DISPLAY=~A" (ataxia.kernel:xwayland-display-name kernel))
                        "ATAXIA_TEST_X11_CONTRACT=1" "build/xwayland-client")
                  :output log :error-output :output))
           (let ((timer
                   (ataxia.runtime:add-event-loop-timer runtime
                     (lambda (source)
                       (format t "X11 contract phase ~D~%" phase)
                       (assert (null (x11-pixel-check world)))
                       (case phase
                         (0
                          (assert (= 1 (length (%world-stacking world))))
                          (setf window (first (%world-stacking world))
                                app (canvas-window-application window))
                          (assert (typep app 'ataxia.kernel:drawable))
                          (assert (typep app 'ataxia.kernel:interactable))
                          (assert (= 2 (length (ataxia.kernel:drawable-surfaces app))))
                          (assert (ataxia.kernel:interactable-hit-test app world 510 80))
                          (assert (not (ataxia.kernel:interactable-hit-test app world 700 500)))
                          (setf (canvas-window-x window) 80d0 (canvas-window-y window) 100d0
                                (%canvas-output-camera-x output) 0d0 (%canvas-output-camera-y output) 0d0
                                (%canvas-output-zoom output) 1d0)
                          (pixels))
                         (1 (at 20d0 20d0) (button :pressed) (button :released))
                         (2
                          (assert (search "button root 1 1 20 20" (events)))
                          (assert (search "button root 1 0 20 20" (events)))
                          (assert (eq window (%canvas-seat-focused human)))
                          (ataxia.kernel:world-cursor-axis world seat
                            (ataxia.kernel:make-cursor-axis-input :delta 15d0 :discrete-delta 120))
                          (ataxia.runtime:seat-pointer-notify-frame (ataxia.kernel:seat-runtime-object seat))
                          (dolist (state '(:pressed :released))
                            (ataxia.kernel:world-key-event world seat
                              (ataxia.kernel:make-key-input :keycode 30 :keysyms #("a") :state state)))
                          (at 510d0 80d0) (button :pressed))
                         (3
                          (assert (search "key root 38 1" (events)))
                          (assert (search "key root 38 0" (events)))
                          (assert (search "button root 5 1" (events)))
                          (assert (search "button root 5 0" (events)))
                          (assert (search "button popup 1 1 90 30" (events)))
                          ;; Keep the pressed popup, even after leaving its bounds.
                          (at 20d0 20d0) (button :released))
                         (4
                          (assert (search "button popup 1 0 -400 -30" (events)))
                          (setf (%canvas-output-zoom output) .75d0
                                (%canvas-output-rotation output) .2d0)
                          (pixels)
                          (at 510d0 80d0)
                          (assert (eq window (%canvas-seat-hovered human)))
                          (button :pressed) (button :released))
                         (5
                          (assert (= 2 (loop for start = 0 then (+ found 1)
                                           for found = (search "button popup 1 1" (events) :start2 start)
                                           while found count t)))
                          ;; Advisory suspension must not become X11 minimization.
                          (ataxia.kernel:request-object-state app world :suspended t)
                          (ataxia.kernel:request-object-state app world :resizing t)
                          (ataxia.kernel:request-object-state app world :constrained '(:left :right))
                          (ataxia.kernel:request-object-state app world :activated nil)
                          (assert (null (ataxia.kernel::%xserver-focused
                                         (gethash kernel ataxia.kernel::*xwayland-servers*))))
                          (ataxia.kernel:request-object-state app world :activated t))
                         (6
                          (assert (not (search "state hidden 1" (events))))
                          (assert (ataxia.kernel:application-mapped-p app))
                          (ataxia.kernel:request-object-state app world :suspended nil)
                          (ataxia.kernel:request-object-configuration app world
                            (make-instance 'ataxia.kernel:toplevel-configuration
                              :width 600 :height 400 :activated t :tiled-edges '(:left :right)
                              :bounds-width 1000 :bounds-height 700 :resizing t))
                          (ataxia.kernel:request-object-state app world :fullscreen t))
                         (7
                          (assert (search "size 600 400" (events)))
                          (assert (search "state hidden 0 fullscreen 1" (events)))
                          (assert (= 600 (nth-value 2 (ataxia.kernel:drawable-local-bounds app))))
                          (ataxia.kernel:request-object-state app world :fullscreen nil)
                          (ataxia.kernel:world-cursor-motion world seat
                            (ataxia.kernel:make-cursor-motion-input :absolute-p t :x 0d0 :y 0d0))
                          (ataxia.kernel:request-object-state app world :close t))
                         (8
                          (assert (search "close" (events)))
                          (assert (null (%world-stacking world)))))
                       (incf phase)
                       (when (< phase 9) (ataxia.runtime:update-event-loop-timer source 300))
                       0))))
             (ataxia.runtime:update-event-loop-timer timer 1600))
           (ataxia.kernel:run-kernel kernel :run-for 4.6d0)
           (assert (= 9 phase))
           (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
           (format t "PASS: X11 generic rendering, outside-root popup hit testing, transformed input, implicit grab, keyboard focus, state, resize and close.~%"))
      (when (and client (uiop:process-alive-p client)) (uiop:terminate-process client))
      (dolist (device devices) (ataxia.world.synthetic-input:destroy-synthetic-input device))
      (ataxia.kernel:destroy-kernel kernel :test))))
