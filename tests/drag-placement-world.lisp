;;;; A tab detaches after release: preserve that point, not later input/defaults.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-world/synthetic-input")
(in-package #:ataxia.infinite-world)

(let* ((world (make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                           :headless-width 1400 :headless-height 800))
       (runtime (ataxia.kernel:kernel-runtime kernel))
       (pointer nil) (clients nil) (seat nil) (human nil) (first-output nil) (second-output nil)
       (origin nil) (target nil) (client-id nil) (expected nil) (phase 0))
  (labels ((at (x y)
             (ataxia.kernel:world-cursor-motion world seat
               (ataxia.kernel:make-cursor-motion-input
                 :delta-x (- x (%canvas-seat-x human)) :delta-y (- y (%canvas-seat-y human)))))
           (button (value)
             (ataxia.kernel:world-cursor-button world seat
               (ataxia.kernel:make-cursor-button-input :code 272 :state value)))
           (window (title)
             (find title (%world-stacking world) :test #'equal
                   :key (lambda (w) (ataxia.kernel:application-title (canvas-window-application w)))))
           (launch (title &rest env)
             (push (uiop:launch-program
                     (append (list "env" (format nil "WAYLAND_DISPLAY=~A" (ataxia.runtime:runtime-socket-name runtime))
                                   (format nil "ATAXIA_TEST_TITLE=~A" title)) env
                             (list "build/computer-use-client" (format nil "/tmp/ataxia-tab-~A.log" title)))
                     :output "/tmp/ataxia-tab-client.log" :error-output :output) clients)))
    (unwind-protect
         (progn
           (ataxia.kernel:start-kernel kernel)
           (setf first-output (%first-output-state world))
           (ataxia.runtime.raw:%wlr-headless-add-output
            (ataxia.runtime::%object-pointer (ataxia.runtime:runtime-backend runtime)) 800 800)
           (setf second-output (find-if (lambda (s) (not (eq s first-output))) (%output-states world))
                 seat (first (ataxia.kernel:kernel-seats kernel))
                 human (gethash seat (%world-seats world))
                 pointer (ataxia.world.synthetic-input:create-synthetic-input runtime :pointer "Tab fixture pointer"))
           (ataxia.kernel:register-input-device kernel pointer :seat seat)
           (launch "origin" "ATAXIA_TEST_DRAG=1" "ATAXIA_TEST_TAB_DETACH=1" "ATAXIA_TEST_TAB_CLOSE_ORIGIN=1")
           (launch "target")
           (let ((timer (ataxia.runtime:add-event-loop-timer runtime
                          (lambda (source)
                            (format t "Tab placement phase ~D~%" phase)
                            (case phase
                              (0
                               (setf origin (window "origin") target (window "target"))
                               (assert (and origin target second-output))
                               (setf (canvas-window-x origin) 20d0 (canvas-window-y origin) 20d0
                                     (canvas-window-x target) 700d0 (canvas-window-y target) 20d0
                                     (%canvas-output-camera-x first-output) 0d0
                                     (%canvas-output-camera-y first-output) 0d0
                                     (%canvas-output-zoom first-output) 1d0)
                               (%full-damage world first-output)
                               (at 100d0 100d0) (button :pressed))
                              (1
                               (assert (ataxia.kernel:seat-drag-has-mime-type-p seat "application/x-moz-tabbrowser-tab"))
                               (at 850d0 100d0))
                              (2
                               (assert (ataxia.kernel:seat-drag-drop-accepted-p seat))
                               (button :released)
                               (assert (zerop (hash-table-count (%world-pending-tab-drops world)))))
                              (3
                               (assert (null (window "detached-tab")))
                               (at 100d0 100d0) (button :pressed))
                              (4
                               (assert (ataxia.kernel:seat-pointer-drag-active-p seat))
                               (setf client-id (ataxia.kernel:application-client-identity (canvas-window-application origin))
                                     (%canvas-output-camera-x second-output) -4000d0
                                     (%canvas-output-camera-y second-output) 2200d0
                                     (%canvas-output-zoom second-output) .65d0
                                     (%canvas-output-rotation second-output) .4d0)
                               ;; Enter the second physical viewport, then release there.
                               (at 1650d0 400d0)
                               (assert (eq second-output (%canvas-seat-output human)))
                               (assert (not (ataxia.kernel:seat-drag-drop-accepted-p seat)))
                               (setf expected (multiple-value-list
                                               (%screen-to-world second-output (%canvas-seat-x human) (%canvas-seat-y human))))
                               (button :released)
                               ;; The new window has not arrived. Move pointer/camera and
                               ;; make a subworld current, all before its first map.
                               (assert (= 1 (hash-table-count (%world-pending-tab-drops world))))
                               (at 500d0 120d0)
                               (setf (%canvas-output-camera-x second-output) -8000d0
                                     (%meta-view-active (%meta-view-for-state world second-output))
                                     (first (metaworld-subworlds world)))
                               (launch "unrelated"))
                              (5
                               (let ((detached (window "detached-tab")) (unrelated (window "unrelated")))
                                 (assert (and detached unrelated))
                                 (assert (null (window "origin")))
                                 (assert (%canvas-window-drop-placed-p detached))
                                 (assert (null (object-subworld world detached)))
                                 (assert (< (abs (- (first expected) (canvas-window-x detached))) 1d-8))
                                 (assert (< (abs (- (second expected) (canvas-window-y detached))) 1d-8))
                                 (assert (eql client-id (ataxia.kernel:application-client-identity (canvas-window-application detached))))
                                 (assert (not (eql client-id (ataxia.kernel:application-client-identity (canvas-window-application unrelated)))))
                                 (assert (not (%canvas-window-drop-placed-p unrelated)))
                                 (assert (zerop (hash-table-count (%world-pending-tab-drops world))))
                                 ;; Claimed once; neither expired hints nor unrelated connections qualify.
                                 (setf (gethash seat (%world-pending-tab-drops world))
                                       (list client-id (- (%now) 1d0) 99d0 88d0))
                                 (assert (null (%claim-tab-drop world (canvas-window-application detached))))
                                 (assert (zerop (hash-table-count (%world-pending-tab-drops world))))
                                 ;; A later keyboard action cannot spawn a window at an
                                 ;; abandoned drop, including Metaworld's key override.
                                 (setf (gethash seat (%world-pending-tab-drops world))
                                       (list client-id (+ (%now) 5d0) 99d0 88d0))
                                 (let ((focus (%canvas-seat-focused human)))
                                   (unwind-protect
                                        (progn
                                          (setf (%canvas-seat-focused human) nil)
                                          (ataxia.kernel:world-key-event world seat
                                            (ataxia.kernel:make-key-input :keycode 30 :keysyms #("a") :state :pressed)))
                                     (setf (%canvas-seat-focused human) focus)))
                                 (assert (zerop (hash-table-count (%world-pending-tab-drops world)))))))
                            (incf phase)
                            (when (< phase 6) (ataxia.runtime:update-event-loop-timer source 500))
                            0))))
             (ataxia.runtime:update-event-loop-timer timer 700))
           (ataxia.kernel:run-kernel kernel :run-for 3.8d0)
           (assert (= phase 6))
           (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
           (format t "PASS: detached tab uses release coordinates across monitors, zoom/rotation, delayed map, source destruction, unrelated clients, accepted drops and expiry.~%"))
      (dolist (client clients) (when (uiop:process-alive-p client) (uiop:terminate-process client)))
      (when pointer (ataxia.world.synthetic-input:destroy-synthetic-input pointer))
      (ataxia.kernel:destroy-kernel kernel :test))))
