;;;; Exercise real World input, GLES capture and output hotplug.
(load (merge-pathnames "support.lisp" *load-truename*))
(in-package #:ataxia.infinite-world)

(defclass qol-test-world (metaworld)
  ((capture :initform nil :accessor test-capture)
   (frames :initform (make-hash-table) :reader test-frames)))
(defmethod ataxia.kernel:world-render :after ((world qol-test-world) lease)
  (incf (gethash (ataxia.kernel:frame-output lease) (test-frames world) 0))
  (when (test-capture world)
    (funcall (test-capture world))
    (setf (test-capture world) nil)))

(let* ((world (make-instance 'qol-test-world :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless :headless-width 1200 :headless-height 800))
       (runtime (ataxia.kernel:kernel-runtime kernel)) (clients nil) (phase 0)
       (left nil) (right nil) (human nil) (windows nil))
  (labels ((button (code state)
             (ataxia.kernel:world-cursor-button world (%canvas-seat-seat human)
               (ataxia.kernel:make-cursor-button-input :code code :state state)))
           (at (x y)
             (ataxia.kernel:world-cursor-motion world (%canvas-seat-seat human)
               (ataxia.kernel:make-cursor-motion-input :delta-x (- x (%canvas-seat-x human))
                                                     :delta-y (- y (%canvas-seat-y human)))))
           (modifiers (&rest names) (setf (gethash (%canvas-seat-seat human) (%meta-modifiers world)) names)))
    (unwind-protect
         (progn
           (ataxia.kernel:start-kernel kernel)
           (setf left (%first-output-state world) human (first (%seat-states world)))
           (ataxia.runtime.raw:%wlr-headless-add-output
             (ataxia.runtime::%object-pointer (ataxia.runtime::%runtime-backend runtime)) 800 1000)
           (setf right (find-if (lambda (s) (not (eq s left))) (%output-states world)))
           (assert right)
           (setf (%canvas-output-camera-x left) 0d0 (%canvas-output-camera-y left) 0d0
                 (%canvas-output-zoom left) 1d0
                 (%canvas-output-camera-x right) 1200d0 (%canvas-output-camera-y right) 0d0
                 (%canvas-output-zoom right) 1d0)
           (dotimes (i 3)
             (push (uiop:launch-program
                     (list "env" (format nil "WAYLAND_DISPLAY=~A" (ataxia.runtime:runtime-socket-name runtime))
                           (format nil "ATAXIA_TEST_TITLE=QoL ~D" i)
                           "build/computer-use-client" (format nil "/tmp/ataxia-qol-client-~D.log" i))
                     :output "/tmp/ataxia-qol-client.log" :error-output :output) clients))
           (let ((timer (ataxia.runtime:add-event-loop-timer runtime
                          (lambda (source)
                            (format t "QoL native phase ~D~%" phase)
                            (case phase
                              (0
                               (assert (= 3 (length (%world-stacking world))))
                               (setf windows (copy-list (%world-stacking world)))
                               (loop for w in windows for x in '(60d0 720d0 1500d0) do
                                 (move-object-to-subworld world w nil)
                                 (%meta-cancel-motion world w :metaworld-layout)
                                 (%meta-place world w x 120d0 600d0 360d0))
                               (%meta-cancel-motion world left :metaworld-camera)
                               (%meta-set-camera world left '(0d0 0d0 1d0 0d0))
                               (setf (%canvas-seat-output human) left))
                              (1
                               ;; Native monitor sizes and relative input route
                               ;; through the physical layout, not the cameras.
                               (setf (%canvas-seat-output human) left)
                               (at 1195d0 250d0)
                               (ataxia.kernel:world-cursor-motion world (%canvas-seat-seat human)
                                 (ataxia.kernel:make-cursor-motion-input :delta-x 30d0))
                               (assert (eq right (%canvas-seat-output human)))
                               (assert (= 25d0 (%canvas-seat-x human)))
                               (setf (%canvas-output-camera-x right) 9000d0)
                               (assert (= 0d0 (%canvas-output-camera-x left)))
                               (setf (%canvas-seat-output human) left)
                               (%request-all-frames world))
                              (2
                               ;; A 90-degree region covers exactly a 100x100
                               ;; colored patch. Its world bounding box alone
                               ;; would select the wrong neighboring pixels.
                               (dolist (w windows) (%meta-cancel-motion world w :metaworld-layout))
                               (loop for w in windows for x in '(0d0 1000d0 2000d0) do
                                 (%meta-place world w x 0d0 600d0 360d0))
                               (setf (test-capture world)
                                 (lambda ()
                                   (let ((pixels (make-array 40000 :element-type '(unsigned-byte 8))))
                                     (%capture-canvas-region world '(0d0 100d0 100d0 100d0) 100 100 pixels (/ pi 2d0))
                                     (loop for offset in '(404 19800 39000) do
                                       (loop for value in '(239 96 72 255) for i from offset do
                                         (assert (<= (abs (- value (aref pixels i))) 1)))))))
                               (%request-all-frames world))
                              (3
                               (assert (null (test-capture world)))
                               ;; Offset identical patterned clients: in the
                               ;; overlap, the front client's orange top-left
                               ;; patch must cover the rear client's blue area.
                               (let ((back (first windows)) (front (second windows)))
                                 (%meta-place world back 0d0 0d0 600d0 360d0)
                                 (%meta-place world front 250d0 150d0 600d0 360d0)
                                 (%raise-window world front)
                                 (setf (test-capture world)
                                   (lambda ()
                                     (let ((pixels (make-array 400 :element-type '(unsigned-byte 8))))
                                       (%capture-canvas-region world '(260d0 160d0 10d0 10d0) 10 10 pixels)
                                       (loop for value in '(239 96 72 255) for i from 0 do
                                         (assert (<= (abs (- value (aref pixels i))) 1)))))))
                               (%request-all-frames world))
                              (4
                               (assert (null (test-capture world)))
                               (assert (plusp (gethash (%canvas-output-output left) (test-frames world) 0)))
                               (assert (plusp (gethash (%canvas-output-output right) (test-frames world) 0)))
                               (setf (%canvas-seat-output human) right)
                               (cffi:foreign-funcall "wlr_output_destroy" :pointer
                                 (ataxia.runtime::%object-pointer (ataxia.kernel:output-runtime-object (%canvas-output-output right))) :void)
                               (assert (= 1 (hash-table-count (%world-outputs world))))
                               (assert (eq left (%canvas-seat-output human)))
                               (modifiers)
                               (dolist (client clients) (when (uiop:process-alive-p client) (uiop:terminate-process client))))
                              (5
                               (assert (null (%world-stacking world)))
                               (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
                               ;; Context menus and selection gestures are gone.
                               (at 1180d0 750d0)
                               (button 273 :pressed) (button 273 :released)
                               (assert (null (%meta-menu world)))
                               (ataxia.runtime:update-event-loop-timer source 0)))
                            (incf phase)
                            (when (< phase 6) (ataxia.runtime:update-event-loop-timer source 350))
                            0))))
             (ataxia.runtime:update-event-loop-timer timer 700))
           (ataxia.kernel:run-kernel kernel :run-for 3.5d0)
           (assert (= 6 phase))
           (format t "PASS: removed context menus, two monitor rendering/crossing/unplug, exact rotated capture and front-window occlusion.~%"))
      (dolist (client clients) (when (uiop:process-alive-p client) (uiop:terminate-process client)))
      (ataxia.kernel:destroy-kernel kernel :test))))
