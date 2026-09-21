;;;; Real wl_data_device drag, screen pixels, frame callbacks and grab routing.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-world/synthetic-input")
(in-package #:ataxia.infinite-world)

(defclass drag-test-world (infinite-world)
  ((check :initform nil :accessor drag-test-check)))
(defmethod ataxia.kernel:world-render :after ((world drag-test-world) lease)
  (declare (ignore lease))
  (when (drag-test-check world)
    (funcall (drag-test-check world))
    (setf (drag-test-check world) nil)))
(defun drag-test-pixel (x y)
  (cffi:with-foreign-object (rgba :uint8 4)
    (cffi:foreign-funcall "glReadPixels" :int x :int y
      :int 1 :int 1 :uint #x1908 :uint #x1401 :pointer rgba :void)
    (loop for i below 3 collect (cffi:mem-aref rgba :uint8 i))))
(defun drag-test-green-p (x y)
  (let ((color (drag-test-pixel x y)))
    (format t "Drag pixel ~D ~D = ~S~%" x y color)
    (equal '(72 207 96) color)))

(let* ((world (make-instance 'drag-test-world))
       (kernel (ataxia.kernel:create-kernel world :backend :headless :headless-width 1400 :headless-height 800))
       (runtime (ataxia.kernel:kernel-runtime kernel))
       (pointer nil) (clients nil) (seat nil) (state nil) (human nil)
       (origin nil) (target nil) (phase 0) (last-root nil))
  (labels ((at (x y)
             (ataxia.kernel:world-cursor-motion world seat
               (ataxia.kernel:make-cursor-motion-input
                 :delta-x (- x (%canvas-seat-x human)) :delta-y (- y (%canvas-seat-y human)))))
           (button (state)
             (ataxia.kernel:world-cursor-button world seat
               (ataxia.kernel:make-cursor-button-input :code 272 :state state)))
           (pixels (fn)
             (setf (drag-test-check world) fn)
             (%request-all-frames world)))
    (unwind-protect
         (progn
           (ataxia.kernel:start-kernel kernel)
           (setf seat (first (ataxia.kernel:kernel-seats kernel))
                 human (gethash seat (%world-seats world)) state (%first-output-state world)
                 pointer (ataxia.world.synthetic-input:create-synthetic-input runtime :pointer "Drag fixture pointer"))
           (ataxia.kernel:register-input-device kernel pointer :seat seat)
           (dolist (name '("origin" "target"))
             (push (uiop:launch-program
                     (append (list "env" (format nil "WAYLAND_DISPLAY=~A" (ataxia.runtime:runtime-socket-name runtime))
                                   (format nil "ATAXIA_TEST_TITLE=~A" name))
                             (when (string= name "origin") (list "ATAXIA_TEST_DRAG=1"))
                             (list "build/computer-use-client" (format nil "/tmp/ataxia-drag-~A.log" name)))
                     :output "/tmp/ataxia-drag-client.log" :error-output :output) clients))
           (let ((timer
                   (ataxia.runtime:add-event-loop-timer runtime
                     (lambda (source)
                       (format t "Drag phase ~D~%" phase)
                       (assert (null (drag-test-check world)))
                       (case phase
                         (0
                          (assert (= 2 (length (%world-stacking world))))
                          (setf origin (find "origin" (%world-stacking world)
                                        :key (lambda (w) (ataxia.kernel:application-title (canvas-window-application w))) :test #'equal)
                                target (find "target" (%world-stacking world)
                                        :key (lambda (w) (ataxia.kernel:application-title (canvas-window-application w))) :test #'equal))
                          (setf (canvas-window-x origin) 20d0 (canvas-window-y origin) 20d0
                                (canvas-window-x target) 700d0 (canvas-window-y target) 20d0
                                (%canvas-output-camera-x state) 0d0 (%canvas-output-camera-y state) 0d0
                                (%canvas-output-zoom state) 1d0)
                          (%full-damage world state))
                         (1 (at 100d0 100d0) (button :pressed))
                         (2
                          (assert (ataxia.kernel:seat-pointer-drag-active-p seat))
                          (let* ((icon (ataxia.kernel:seat-drag-icon seat))
                                 (quad (aref (ataxia.kernel:drawable-surfaces icon) 0)))
                            (setf last-root (ataxia.kernel::%drag-icon-root icon))
                            (assert (= -7 (ataxia.kernel:drawable-surface-local-x quad)))
                            (assert (= -5 (ataxia.kernel:drawable-surface-local-y quad)))
                            (assert (= 80 (ataxia.kernel:drawable-surface-width quad))))
                          (assert (= 2 (length (%world-stacking world))))
                          (assert (search "drag-frame-painted" (uiop:read-file-string "/tmp/ataxia-drag-origin.log")))
                          (pixels (lambda () (assert (drag-test-green-p 145 120)))))
                         (3
                          (at 500d0 500d0)
                          (pixels (lambda ()
                                    (assert (not (drag-test-green-p 145 120)))
                                    (assert (drag-test-green-p 545 520)))))
                         (4
                          ;; Pointer-local pixels stay upright and unscaled even
                          ;; when the infinite canvas is zoomed and rotated.
                          (setf (%canvas-output-zoom state) .3d0 (%canvas-output-rotation state) 1d0)
                          (%full-damage world state)
                          (pixels (lambda ()
                                    (assert (drag-test-green-p 545 520))
                                    (assert (not (drag-test-green-p 580 520))))))
                         (5
                          (setf (%canvas-output-zoom state) 1d0 (%canvas-output-rotation state) 0d0)
                          (%full-damage world state)
                          (at 850d0 100d0)
                          (assert (eq target (%canvas-seat-hovered human)))
                          (pixels (lambda () (assert (drag-test-green-p 895 120)))))
                         (6 (button :released))
                         (7
                          (assert (not (ataxia.kernel:seat-pointer-drag-active-p seat)))
                          (assert (null (ataxia.kernel:seat-drag-icon seat)))
                          (assert (search "drag-drop" (uiop:read-file-string "/tmp/ataxia-drag-target.log")))
                          (pixels (lambda () (assert (not (drag-test-green-p 895 120)))))
                          (at 100d0 100d0) (button :pressed))
                         (8
                          (assert (ataxia.kernel:seat-drag-icon seat))
                          (setf last-root (ataxia.kernel::%drag-icon-root (ataxia.kernel:seat-drag-icon seat)))
                          (uiop:terminate-process (second clients)))
                         (9
                          (assert (null (ataxia.kernel:seat-drag-icon seat)))
                          (assert (not (ataxia.kernel:seat-pointer-drag-active-p seat)))
                          (assert (null (ataxia.kernel::%surface-render-source last-root)))
                          (button :released)
                          (uiop:terminate-process (first clients)))
                         (10 (assert (null (%world-stacking world)))))
                       (incf phase)
                       (when (< phase 11) (ataxia.runtime:update-event-loop-timer source 250))
                       0))))
             (ataxia.runtime:update-event-loop-timer timer 600))
           (ataxia.kernel:run-kernel kernel :run-for 3.9d0)
           (assert (= 11 phase))
           (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
           (format t "PASS: drag preview pixels, commit offsets, stationary repaint, movement damage, zoom/rotation, drop routing and disconnect cleanup.~%"))
      (dolist (client clients) (when (uiop:process-alive-p client) (uiop:terminate-process client)))
      (when pointer (ataxia.world.synthetic-input:destroy-synthetic-input pointer))
      (ataxia.kernel:destroy-kernel kernel :test))))
