;;;; Run: sbcl --script tests/metaworld-layout-qa.lisp
(load (merge-pathnames "support.lisp" *load-truename*))
(in-package #:ataxia.infinite-world)

(defun qa-window ()
  (let ((w (make-instance 'canvas-window :application (make-instance 'ataxia.kernel:wayland-application)
                          :x 0d0 :y 0d0 :width 200d0 :height 100d0)))
    (setf (%canvas-window-mapped-p w) t) w))
(defun qa-near (a b) (< (abs (- a b)) 0.000001d0))

;; Page fit uses all available viewport area, never crops, and preserves aspect.
(let ((original (symbol-function '%meta-set-camera)) (camera nil))
  (unwind-protect
       (progn
         (setf (symbol-function '%meta-set-camera)
               (lambda (world state value) (declare (ignore world state)) (setf camera value)))
         (dolist (size '((1280 720 1d0) (1920 1080 1.5d0) (1080 1920 1d0) (3440 1440 1d0) (800 600 2d0)))
           (destructuring-bind (width height scale) size
             (let* ((world (make-metaworld :state-file nil))
                    (group (%make-subworld :kind :hyprland :x 500d0 :y -200d0))
                    (output (make-instance 'ataxia.kernel:kernel-output :width width :height height :scale scale :transform 0))
                    (state (%make-canvas-output output)))
               (multiple-value-bind (vw vh) (%output-logical-size state)
                 (%meta-fit-group world state group)
                 (let ((z (third camera)))
                   (assert (or (qa-near (* z 1400d0) vw) (qa-near (* z 800d0) vh)))
                   (assert (<= (* z 1400d0) (+ vw 0.000001d0)))
                   (assert (<= (* z 800d0) (+ vh 0.000001d0)))
                   (assert (qa-near (* (- 500d0 (first camera)) z) (/ (- vw (* z 1400d0)) 2d0)))
                   (assert (qa-near (* (- -200d0 (second camera)) z) (/ (- vh (* z 800d0)) 2d0)))))))))
    (setf (symbol-function '%meta-set-camera) original)))
(format t "PASS: edge fit, centering, aspect ratio, portrait/ultrawide and fractional output scaling.~%")

;; Layout rectangles must match their real clamped presentation dimensions.
(let ((original (symbol-function '%meta-place)) (rectangles nil))
  (unwind-protect
       (progn
         (setf (symbol-function '%meta-place)
               (lambda (world object x y width height)
                 (declare (ignore world object))
                 (push (list x y (max 96d0 width) (max 64d0 height)) rectangles)))
         (dolist (size '((1400d0 800d0) (480d0 320d0) (1920d0 1080d0)))
          (dolist (ratio '(0.2d0 0.55d0 0.8d0))
           (dolist (layout '(:dwindle :master :niri))
            (loop for count from 1 to 12 do
             (let* ((group (%make-subworld :kind (if (eq layout :niri) :niri :hyprland)
                                          :width (first size) :height (second size) :ratio ratio))
                    (members (loop for i below count collect (%make-subworld-member :object (qa-window) :column 1
                                                                                   :weight (if (zerop i) 0.1d0 1d0)))))
               (setf (subworld-members group) members rectangles nil)
               (case layout
                 (:niri (%meta-layout-niri nil group members))
                 (:master (%meta-layout-master nil group members))
                 (:dwindle (%meta-layout-dwindle nil group members)))
               (assert (= count (length rectangles)))
               (dolist (r rectangles)
                 (destructuring-bind (x y w h) r
                   (assert (>= x (if (eq layout :niri) 0d0 16d0)))
                   (assert (>= y (if (eq layout :niri) 0d0 16d0)))
                   (assert (<= (+ x w) (+ (- (if (eq layout :niri) (%meta-workspace-width group 1)
                                                 (subworld-width group)) (if (eq layout :niri) 0d0 16d0)) 0.000001d0)))
                   (assert (<= (+ y h) (+ (- (subworld-height group) (if (eq layout :niri) 0d0 16d0)) 0.000001d0)))))
               (loop for tail on rectangles for a = (first tail) do
                 (dolist (b (rest tail))
                   (assert (or (<= (+ (first a) (third a)) (+ (first b) 0.000001d0))
                               (<= (+ (first b) (third b)) (+ (first a) 0.000001d0))
                               (<= (+ (second a) (fourth a)) (+ (second b) 0.000001d0))
                               (<= (+ (second b) (fourth b)) (+ (second a) 0.000001d0)))
                           () "Overlapping ~A layout with ~D windows: ~S ~S" layout count a b)))))))))
    (setf (symbol-function '%meta-place) original)))
(format t "PASS: Niri stacks and Hyprland master/dwindle stay within their content bounds without overlap, 1–12 windows, 3 sizes, 3 ratios and skewed weights.~%")

(let* ((world (make-metaworld :state-file nil))
       (group (%make-subworld :kind :niri :x 500d0 :y -200d0))
       (output (make-instance 'ataxia.kernel:kernel-output :width 1280 :height 720 :scale 1d0 :transform 0))
       (state (%make-canvas-output output)) (seat (%make-canvas-seat :seat))
       (first (qa-window)) (last (qa-window))
       (names '(%focus-target %meta-changed %meta-raise-floating %full-damage %update-all-membership))
       (originals (mapcar #'symbol-function names)))
  (unwind-protect
       (progn
         (dolist (name names) (setf (symbol-function name) (lambda (&rest args) (declare (ignore args)))))
         (setf (gethash output (%world-outputs world)) state
               (gethash :seat (%world-seats world)) seat (%canvas-seat-output seat) state
               (%meta-view-active (%meta-view-for-state world state)) group
               (gethash first (%meta-owners world)) group (gethash last (%meta-owners world)) group
               (canvas-window-x first) 500d0 (canvas-window-width first) 660d0
               (canvas-window-x last) 1820d0 (canvas-window-width last) 660d0
               (subworld-members group) (list (%make-subworld-member :object first :column 1)
                                               (%make-subworld-member :object (qa-window) :column 2)
                                               (%make-subworld-member :object last :column 3)))
         (assert (= (%meta-workspace-width group 1) (* 3 660d0)))
         (%meta-fit-group world state group)
         (let ((origin (%meta-camera state)))
           (%meta-focus world first :seat nil)
           (assert (equalp origin (%meta-camera state)))
           (assert (zerop (gethash 1 (subworld-scrolls group))))
           (%meta-focus world last :seat nil)
           (assert (> (gethash 1 (subworld-scrolls group)) 0d0))
           (assert (<= (gethash 1 (subworld-scrolls group)) (- (%meta-workspace-width group 1) (/ 1280d0 (%canvas-output-zoom state)))))
           (%meta-focus world first :seat nil)
           (assert (equalp origin (%meta-camera state)))
           ;; Keyboard focus must still reveal the first column after a manual zoom.
           (%meta-set-camera world state '(1200d0 -200d0 1.5d0 0d0))
           (%meta-focus world first :seat nil)
           (assert (= 500d0 (%canvas-output-camera-x state)))))
    (loop for name in names for original in originals do (setf (symbol-function name) original))))
(format t "PASS: Niri first/last focus clamps to page bounds; zero outer insets and no trailing gap.~%")

(let* ((world (make-metaworld :state-file nil)) (group (first (metaworld-subworlds world)))
       (output (make-instance 'ataxia.kernel:kernel-output :width 1280 :height 720 :scale 1d0 :transform 0))
       (state (%make-canvas-output output)) (seat (%make-canvas-seat :seat))
       (names '(%meta-focus %meta-changed %meta-transition-camera %full-damage %update-all-membership))
       (originals (mapcar #'symbol-function names))
       (parent '(175d0 -250d0 0.35d0 0.2d0)))
  (unwind-protect
       (progn
         (dolist (name names) (setf (symbol-function name) (lambda (&rest args) (declare (ignore args)))))
         (setf (gethash output (%world-outputs world)) state
               (gethash :seat (%world-seats world)) seat (%canvas-seat-output seat) state)
         (%meta-set-camera world state parent)
         (enter-subworld world group :seat)
         (assert (equalp parent (%meta-view-parent-camera (%meta-view-for-state world state))))
         (%meta-set-camera world state '(900d0 700d0 1.2d0 0d0))
         (leave-subworld world :seat)
         (assert (null (%meta-view-active (%meta-view-for-state world state))))
         (assert (equalp parent (%meta-camera state))))
    (loop for name in names for original in originals do (setf (symbol-function name) original))))
(format t "PASS: leaving restores the exact overview camera after navigating within a subworld.~%")

;; Wheel navigation uses the same strip bounds as keyboard and gesture focus.
(let* ((world (make-metaworld :state-file nil))
       (group (%make-subworld :kind :niri :x 100d0 :y 200d0 :width 2400d0 :height 800d0))
       (output (make-instance 'ataxia.kernel:kernel-output :width 1280 :height 720 :scale 1d0 :transform 0))
       (state (%make-canvas-output output)) (seat (%make-canvas-seat :seat))
       (names '(%full-damage %update-all-membership %request-all-frames))
       (originals (mapcar #'symbol-function names)))
  (unwind-protect
       (progn
         (dolist (name names)
           (setf (symbol-function name) (lambda (&rest args) (declare (ignore args)))))
         (setf (gethash output (%world-outputs world)) state
               (gethash :seat (%world-seats world)) seat (%canvas-seat-output seat) state
               (%meta-view-active (%meta-view-for-state world state)) group
               (gethash :seat (%meta-modifiers world)) '(:shift))
         (%meta-fit-group world state group)
         (ataxia.kernel:world-cursor-axis world :seat
          (ataxia.kernel:make-cursor-axis-input :delta 100000d0))
         (assert (qa-near (%canvas-output-camera-x state)
                          (+ 100d0 (- 2400d0 (/ 1280d0 (%canvas-output-zoom state))))))
         (ataxia.kernel:world-cursor-axis world :seat
          (ataxia.kernel:make-cursor-axis-input :delta -100000d0))
         (assert (= 100d0 (%canvas-output-camera-x state)))
         (assert (= 200d0 (%canvas-output-camera-y state)))
         ;; Switching to Hyprland must not reuse Niri's horizontal scroll.
         (setf (subworld-kind group) :hyprland (gethash 1 (subworld-scrolls group)) 500d0)
         (%meta-fit-group world state group)
         (assert (qa-near (%canvas-output-camera-x state) 100d0)))
    (loop for name in names for original in originals do (setf (symbol-function name) original))))
(format t "PASS: wheel navigation clamps to both strip ends, and Hyprland ignores saved Niri scroll.~%")

(let* ((world (make-metaworld :state-file nil)) (window (qa-window))
       (group (%make-subworld :kind :niri :x 100d0 :y 200d0 :workspace 2 :fullscreen window))
       (names '(%meta-place %meta-set-visible %meta-raise-floating %meta-changed))
       (originals (mapcar #'symbol-function names)) (rectangle nil))
  (unwind-protect
       (progn
         (dolist (name names)
           (setf (symbol-function name) (lambda (&rest args) (declare (ignore args)))))
         (setf (symbol-function '%meta-place)
               (lambda (world object x y width height)
                 (declare (ignore world object)) (setf rectangle (list x y width height))))
         (%meta-layout world group)
         (assert (equalp rectangle '(100d0 1000d0 1400d0 800d0))))
    (loop for name in names for original in originals do (setf (symbol-function name) original))))
(format t "PASS: a fullscreen Niri tile uses the complete workspace height without legacy padding.~%")
