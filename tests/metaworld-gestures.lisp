;;;; Run: sbcl --script tests/metaworld-gestures.lisp
(load (merge-pathnames "support.lisp" *load-truename*))
(in-package #:ataxia.infinite-world)
(let* ((world (make-infinite-world)) (output (gensym)) (seat (gensym)) (device (gensym))
       (state (%make-canvas-output output)) (ss (%make-canvas-seat seat))
       (names '(%full-damage %update-all-membership %request-all-frames %output-logical-size %now))
       (saved (mapcar #'symbol-function names)))
  (unwind-protect
       (progn
         (dolist (name (subseq names 0 3)) (setf (symbol-function name) (lambda (&rest args) (declare (ignore args)))))
         (setf (symbol-function '%output-logical-size) (lambda (state) (declare (ignore state)) (values 1000d0 800d0))
               (symbol-function '%now) (lambda () 1d0)
               (gethash output (%world-outputs world)) state
               (gethash seat (%world-seats world)) ss
               (%canvas-seat-output ss) state (%canvas-seat-x ss) 300d0 (%canvas-seat-y ss) 200d0)
         (labels ((event (kind phase time &rest keys)
                    (ataxia.kernel:world-cursor-gesture world seat
                      (apply #'ataxia.kernel:make-cursor-gesture-input :device device :kind kind :phase phase :time-msec time keys)))
                  (near (a b) (assert (< (abs (- a b)) 1d-6))))
           (setf (%canvas-output-zoom state) .5d0)
           (event :swipe :begin 0 :fingers 3)
           (event :swipe :update 10 :fingers 3 :dx 20d0 :dy -10d0)
           (near (%canvas-output-camera-x state) -40d0)
           (near (%canvas-output-camera-y state) 20d0)
           (event :swipe :update 20 :fingers 3 :dx 20d0)
           (event :swipe :end 21)
           (let ((before (%canvas-output-camera-x state)))
             (ataxia.world:advance-animations (%world-animator world) 1.1d0)
             (assert (< (%canvas-output-camera-x state) before)))
           ;; A hold/new contact brakes momentum immediately.
           (event :hold :begin 22 :fingers 3)
           (let ((before (%canvas-output-camera-x state)))
             (ataxia.world:advance-animations (%world-animator world) 2d0)
             (near (%canvas-output-camera-x state) before))
           ;; Pinch scale is absolute since BEGIN, not multiplied per event.
           (event :pinch :begin 100 :fingers 2)
           (multiple-value-bind (x y) (%screen-to-world state 300d0 200d0)
             (event :pinch :update 110 :fingers 2 :scale 1.5d0)
             (event :pinch :update 120 :fingers 2 :scale 2d0)
             (near (%canvas-output-zoom state) 1d0)
             (multiple-value-bind (new-x new-y) (%screen-to-world state 300d0 200d0)
               (near x new-x) (near y new-y)))
           (event :pinch :update 121 :fingers 2 :scale 100d0)
           (near (%canvas-output-zoom state) 8d0)
           (event :pinch :update 122 :fingers 2 :scale 50d0)
           (near (%canvas-output-zoom state) 8d0)
           (event :pinch :update 123 :fingers 2 :scale 2d0)
           (near (%canvas-output-zoom state) 1d0)
           (event :pinch :end 124 :cancelled-p t)
           (assert (null (gethash ss *canvas-gestures*)))
           ;; Wrong-device events and changed finger counts cannot hijack a drag.
           (event :swipe :begin 200 :fingers 3)
           (let ((before (%canvas-output-camera-x state)))
             (ataxia.kernel:world-cursor-gesture world seat
              (ataxia.kernel:make-cursor-gesture-input :device (gensym) :kind :swipe :phase :update :fingers 3 :dx 100d0))
             (near before (%canvas-output-camera-x state))
             (event :swipe :update 210 :fingers 4 :dx 100d0)
             (near before (%canvas-output-camera-x state)))
           (assert (null (gethash ss *canvas-gestures*)))
           ;; Rotated canvas pans along the physical touchpad direction.
           (setf (%canvas-output-rotation state) (/ pi 2))
           (event :swipe :begin 300 :fingers 3)
           (let ((x (%canvas-output-camera-x state)) (y (%canvas-output-camera-y state)))
             (event :swipe :update 310 :fingers 3 :dx 20d0)
             (near x (%canvas-output-camera-x state))
             (near (+ y 20d0) (%canvas-output-camera-y state)))
           (event :swipe :end 311 :cancelled-p t)
           (let ((x (%canvas-output-camera-x state)) (y (%canvas-output-camera-y state)))
             (ataxia.world:advance-animations (%world-animator world) 3d0)
             (near x (%canvas-output-camera-x state)) (near y (%canvas-output-camera-y state)))
           ;; Pressed buttons reserve the gesture for the existing drag.
           (setf (gethash 272 (%canvas-seat-buttons ss)) :world)
           (event :swipe :begin 400 :fingers 3)
           (assert (null (gethash ss *canvas-gestures*)))))
    (loop for name in names for fn in saved do (setf (symbol-function name) fn))))
(format t "PASS: pan, bounded momentum, contact braking, anchored absolute pinch, cancellation, device isolation, rotated canvas and drag exclusion.~%")
;; The Runtime snapshot retains an owned copy after native event storage changes.
(ataxia.runtime.raw:load-native-libraries)
(cffi:with-foreign-object (event :uint8 64)
  ;; Public wlroots pinch update layout is validated independently by the C test.
  (setf (cffi:mem-ref event :pointer) (cffi:null-pointer)
        (cffi:mem-ref event :uint32 8) 123
        (cffi:mem-ref event :uint32 12) 2
        (cffi:mem-ref event :double 16) 4d0
        (cffi:mem-ref event :double 24) -6d0
        (cffi:mem-ref event :double 32) 1.25d0
        (cffi:mem-ref event :double 40) 0d0)
  (let ((snapshot (ataxia.runtime::%gesture-snapshot :pointer event 1 1)))
    (setf (cffi:mem-ref event :double 32) 9d0)
    (assert (= 1.25d0 (ataxia.runtime:pointer-gesture-scale snapshot)))
    (assert (= 123 (ataxia.runtime:pointer-gesture-time-msec snapshot)))
    (assert (eq :pinch (ataxia.runtime:pointer-gesture-kind snapshot)))))
(format t "PASS: copied native gesture snapshots.~%")
(defclass gesture-test-world (ataxia.kernel:world) ())
(defvar *gesture-test-received* nil)
(defmethod ataxia.kernel:world-cursor-gesture ((world gesture-test-world) seat input)
  (declare (ignore seat)) (setf *gesture-test-received* input))
(let* ((kernel (make-instance 'ataxia.kernel:kernel :world (make-instance 'gesture-test-world)))
       (seat (make-instance 'ataxia.kernel:logical-seat))
       (device (make-instance 'ataxia.kernel:kernel-input-device :seat seat))
       (lookup (symbol-function 'ataxia.kernel::%event-input-device))
       (guard (symbol-function 'ataxia.kernel::%guard-kernel-operation)))
  (unwind-protect
       (progn
         (setf (symbol-function 'ataxia.kernel::%event-input-device)
               (lambda (kernel pointer) (declare (ignore kernel pointer)) device)
               (symbol-function 'ataxia.kernel::%guard-kernel-operation)
               (lambda (kernel world operation callback)
                 (declare (ignore kernel world))
                 (assert (eq operation 'ataxia.kernel:world-cursor-gesture))
                 (funcall callback)))
         (ataxia.runtime:pointer-gesture kernel
          (ataxia.runtime::make-pointer-gesture-event :pointer :native :kind :swipe :phase :end
            :time-msec 98 :fingers 0 :cancelled-p t :dx 0d0 :dy 0d0 :scale 1d0 :rotation 0d0))
         (assert (eq device (ataxia.kernel:cursor-gesture-input-device *gesture-test-received*)))
         (assert (ataxia.kernel:cursor-gesture-input-cancelled-p *gesture-test-received*))
         (assert (= 98 (ataxia.kernel:cursor-gesture-input-time-msec *gesture-test-received*))))
    (setf (symbol-function 'ataxia.kernel::%event-input-device) lookup
          (symbol-function 'ataxia.kernel::%guard-kernel-operation) guard)))
(format t "PASS: Runtime-to-Kernel gesture dispatch preserves device, seat and cancellation.~%")
;; WORLD-KEY-EVENT receives both KEY-INPUT and MODIFIERS-INPUT. Modifier changes
;; must brake a gesture without calling key-only accessors (Shift crash regression).
(let* ((world (make-infinite-world)) (seat (gensym)) (ss (%make-canvas-seat seat))
       (names '(%cancel-seat-gesture %update-view-shift-modifiers ataxia.world:handle-shortcut-input))
       (saved (mapcar #'symbol-function names)) (cancelled 0))
  (unwind-protect
       (progn
         (setf (gethash seat (%world-seats world)) ss
               (symbol-function '%cancel-seat-gesture)
               (lambda (world seat) (declare (ignore world seat)) (incf cancelled))
               (symbol-function '%update-view-shift-modifiers)
               (lambda (&rest args) (declare (ignore args)))
               (symbol-function 'ataxia.world:handle-shortcut-input)
               (lambda (&rest args) (declare (ignore args)) :handled))
         (dolist (modifiers '((:shift) (:control) (:alt) (:logo) nil))
           (ataxia.kernel:world-key-event world seat
             (ataxia.kernel:make-modifiers-input :names modifiers)))
         (assert (= cancelled 5))
         (ataxia.kernel:world-key-event world seat (ataxia.kernel:make-key-input :state :pressed))
         (assert (= cancelled 6))
         (ataxia.kernel:world-key-event world seat (ataxia.kernel:make-key-input :state :released))
         (assert (= cancelled 6)))
    (loop for name in names for fn in saved do (setf (symbol-function name) fn))))
(format t "PASS: Shift/Ctrl/Alt/Super modifier updates and key press/release through real method dispatch.~%")

;; Entered groups own the complete gesture stream; only their navigation may
;; move the camera. Exercise the public event path, not just the step helper.
(let* ((world (make-metaworld :state-file nil)) (seat (gensym)) (output (gensym))
       (device (gensym)) (ss (%make-canvas-seat seat)) (state (%make-canvas-output output))
       (group (%make-subworld :id 1 :kind :niri))
       (a (make-instance 'canvas-window :application (make-instance 'ataxia.kernel:wayland-application)
                         :x 0d0 :y 0d0 :width 500d0 :height 800d0))
       (b (make-instance 'canvas-window :application (make-instance 'ataxia.kernel:wayland-application)
                         :x 500d0 :y 0d0 :width 500d0 :height 800d0))
       (names '(%meta-focus %meta-switch-workspace %meta-changed %request-all-frames))
       (saved (mapcar #'symbol-function names)))
  (unwind-protect
       (progn
         (setf (gethash seat (%world-seats world)) ss
               (gethash output (%world-outputs world)) state
               (%canvas-seat-output ss) state
               (metaworld-subworlds world) (list group)
               (%meta-view-active (%meta-view-for-state world state)) group
               (gethash group *meta-workspace-counts*) 3
               (%canvas-window-mapped-p a) t (%canvas-window-mapped-p b) t
               (gethash a (%meta-owners world)) group (gethash b (%meta-owners world)) group
               (subworld-members group) (list (%make-subworld-member :object a :column 1 :width 500d0)
                                             (%make-subworld-member :object b :column 2 :width 500d0))
               (gethash group (%meta-group-focus world)) a
               (symbol-function '%meta-focus)
               (lambda (world object &optional seat animate)
                 (declare (ignore world seat animate)) (setf (gethash group (%meta-group-focus world)) object))
               (symbol-function '%meta-switch-workspace)
               (lambda (world group number seat)
                 (declare (ignore world seat)) (setf (subworld-workspace group) number))
               (symbol-function '%meta-changed) #'identity
               (symbol-function '%request-all-frames) #'identity)
         (labels ((event (kind phase &rest keys)
                    (ataxia.kernel:world-cursor-gesture world seat
                      (apply #'ataxia.kernel:make-cursor-gesture-input :kind kind :phase phase :device device keys)))
                  (unchanged-camera () (assert (equalp (%meta-camera state) '(0d0 0d0 1d0 0d0)))))
           (event :swipe :begin :fingers 3)
           (event :swipe :update :fingers 3 :dx -110d0)
           (assert (eq b (gethash group (%meta-group-focus world))))
           (unchanged-camera)
           (event :swipe :end)
           (assert (= 1 (subworld-workspace group)))
           ;; Vertical travel changes the workspace, never the outer viewport.
           (event :swipe :begin :fingers 3)
           (event :swipe :update :fingers 3 :dy -110d0)
           (event :swipe :end)
           (assert (= 2 (subworld-workspace group)))
           (unchanged-camera)
           ;; A short cancelled gesture does not commit on END.
           (event :swipe :begin :fingers 3)
           (event :swipe :update :fingers 3 :dy -60d0)
           (event :swipe :end :cancelled-p t)
           (assert (= 2 (subworld-workspace group)))
           ;; Four fingers retain workspace navigation on either axis, clamped
           ;; at existing pages. Ambiguous diagonal travel never picks an axis.
           (event :swipe :begin :fingers 4)
           (event :swipe :update :fingers 4 :dx -300d0)
           (event :swipe :end)
           (assert (= 3 (subworld-workspace group)))
           (event :swipe :begin :fingers 4)
           (event :swipe :update :fingers 4 :dy 110d0)
           (event :swipe :end)
           (assert (= 2 (subworld-workspace group)))
           (event :swipe :begin :fingers 3)
           (event :swipe :update :fingers 3 :dx -150d0 :dy -150d0)
           (event :swipe :end)
           (assert (= 2 (subworld-workspace group)))
           (unchanged-camera)
           ;; Unsupported pinch is owned, including after exiting mid-stream.
           (event :pinch :begin :fingers 2)
           (event :pinch :update :fingers 2 :scale 2d0 :dx 90d0)
           (unchanged-camera)
           (setf (%meta-view-active (%meta-view-for-state world state)) nil)
           (event :pinch :update :fingers 2 :scale 3d0)
           (event :pinch :end)
           (unchanged-camera)
           ;; Entering a group also cancels a gesture begun on the canvas.
           (event :swipe :begin :fingers 3)
           (setf (%meta-view-active (%meta-view-for-state world state)) group)
           (event :swipe :update :fingers 3 :dx 100d0)
           (event :swipe :end)
           (unchanged-camera)))
    (loop for name in names for fn in saved do (setf (symbol-function name) fn))))
(format t "PASS: subworld ownership, horizontal tile focus, vertical workspaces, consumed pinch and mid-gesture entry/exit.~%")

;; Velocity estimation follows elapsed time, including coalesced timestamps;
;; a long pause invalidates an old flick instead of reusing stale momentum.
(let* ((world (make-infinite-world)) (output (gensym)) (state (%make-canvas-output output))
       (names '(%full-damage %update-all-membership %request-all-frames %now))
       (saved (mapcar #'symbol-function names)) (speeds nil))
  (unwind-protect
       (progn
         (dolist (name (butlast names))
           (setf (symbol-function name) (lambda (&rest args) (declare (ignore args)))))
         (setf (symbol-function '%now) (lambda () 1d0)
               (gethash output (%world-outputs world)) state)
         (flet ((update (gesture time dx)
                  (%gesture-update world gesture
                    (ataxia.kernel:make-cursor-gesture-input
                     :kind :swipe :phase :update :time-msec time :dx dx))))
           (dolist (interval '(4 5 10 20))
             (let ((gesture (make-canvas-gesture :kind :swipe :fingers 3 :state state)))
               (loop for time from interval to 100 by interval do
                 (update gesture time (float interval 1d0)))
               (push (canvas-gesture-vx gesture) speeds)))
           (assert (every (lambda (v) (< (abs (- v (first speeds))) 1d-6)) speeds))
           (let ((gesture (make-canvas-gesture :kind :swipe :fingers 3 :state state)))
             (update gesture 0 5d0)
             (update gesture 10 5d0)
             (let ((expected (* 1000d0 (- 1d0 (exp -.4d0)))))
               (assert (< (abs (- (canvas-gesture-vx gesture) expected)) 1d-6)))
             (update gesture 20 10d0)
             (update gesture 200 0d0)
             (%gesture-coast world gesture 201)
             (assert (zerop (canvas-gesture-vx gesture)))
             (assert (not (ataxia.world:animations-active-p (%world-animator world)))))
           (let ((gesture (make-canvas-gesture :kind :swipe :fingers 3 :state state
                                              :time #xfffffff8)))
             (update gesture 2 10d0)
             (assert (plusp (canvas-gesture-vx gesture)))))
         (dolist (hz '(60 120 144 240))
           (setf (%canvas-output-camera-x state) 0d0 (%canvas-output-zoom state) 1d0)
           (%gesture-coast world (make-canvas-gesture :state state :samples 2 :time 100 :vx 1000d0) 101)
           (loop for i from 1 to (ceiling (* hz .24d0)) do
             (ataxia.world:advance-animations (%world-animator world) (+ 1d0 (/ i (float hz 1d0)))))
           (ataxia.world:advance-animations (%world-animator world) 2d0)
           (assert (< (abs (+ 120d0 (%canvas-output-camera-x state))) 1d-6))
           (assert (not (ataxia.world:animations-active-p (%world-animator world)))))
         (format t "PASS: event-rate independent velocity, coalesced timestamps, stale flick rejection, timestamp wrap and refresh-rate independent coast.~%"))
    (loop for name in names for original in saved do (setf (symbol-function name) original))))
