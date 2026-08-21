;;;; Frame snapshots, outputs, and presentation coordination.
;;;;
;;;; One snapshot supplies both drawing and hit testing. Output submission uses
;;;; Runtime swapchains and direct GLES without depending on wlr_scene.

(in-package #:ataxia.compositor)

(defparameter *trace-output-p*
  (not (null (uiop:getenv "ATAXIA_TRACE_OUTPUT"))))

(defun trace-output (control &rest arguments)
  (when *trace-output-p*
    (apply #'format *error-output* control arguments)
    (finish-output *error-output*)))

(defclass frame-damage ()
  ((full-p :initarg :full-p :initform nil :accessor frame-damage-full-p)
   (boxes :initarg :boxes :initform nil :accessor frame-damage-boxes)))

(defclass compositor-output ()
  ((native :initarg :native :reader output-native)
   (layout-x :initarg :layout-x :initform 0d0 :accessor output-layout-x)
   (layout-y :initarg :layout-y :initform 0d0 :accessor output-layout-y)
   (behavior-state :initform nil :accessor output-behavior-state)
   (swapchain :initarg :swapchain :accessor output-swapchain)
   (last-snapshot :initform nil :accessor output-last-snapshot)
   (frame-revision :initform 0 :accessor output-frame-revision)
   (commit-pending-p :initform nil :accessor output-commit-pending-p)
   (redraw-pending-p :initform t :accessor output-redraw-pending-p)
   (full-damage-p :initform t :accessor output-full-damage-p)
   (damage-boxes :initform nil :accessor output-damage-boxes)
   (frame-timer :initform nil :accessor output-frame-timer)
   (frame-timer-armed-p :initform nil
                        :accessor output-frame-timer-armed-p)
   (frame-requested-p :initform nil :accessor output-frame-requested-p)
   (last-present-time :initform 0d0 :accessor output-last-present-time)
   (refresh-seconds :initform (/ 1d0 60d0)
                    :accessor output-refresh-seconds)
   (available-p :initform t :accessor output-available-p)))

(defun output-viewport (output)
  (output-behavior-state output))

(defclass output-system (compositor-component)
  ((outputs :initform (make-hash-table :test #'eq)
            :reader output-table)
   (order :initform nil :accessor output-order)))

(defclass presentation-system (compositor-component)
  ((animation-engine :initarg :animation-engine
                     :reader presentation-animation-engine)
   (panel-height :initarg :panel-height :initform 32d0
                 :reader presentation-panel-height)
   (titlebar-height :initarg :titlebar-height :initform 28d0
                    :reader presentation-titlebar-height)
   (queued-outputs :initform nil :accessor presentation-queued-outputs)
   (render-source :initform nil :accessor presentation-render-source)
   (revision :initform 0 :accessor presentation-revision)))

(defgeneric build-presentation-snapshot (presentation output timestamp))
(defgeneric build-frame-plan (presentation output snapshot timestamp))
(defgeneric presentation-hit-test (snapshot output-x output-y))
(defgeneric render-presentation-frame (presentation output snapshot))
(defgeneric present-output (presentation output))
(defgeneric schedule-presentation (presentation &optional output damage))

(defmethod attach-component :before ((presentation presentation-system))
  (let ((animation (presentation-animation-engine presentation)))
    (validate-component animation (component-compositor presentation))
    (unless (eq (component-state animation) :attached)
      (attach-component animation))))

(defmethod detach-component :before
    ((presentation presentation-system) reason)
  (let ((source (presentation-render-source presentation)))
    (when (and source (ataxia.runtime:native-object-live-p source))
      (ataxia.runtime:remove-event-loop-source source))
    (setf (presentation-render-source presentation) nil
          (presentation-queued-outputs presentation) nil))
  (let ((animation (presentation-animation-engine presentation)))
    (when (eq (component-state animation) :attached)
      (detach-component animation reason))))

(defclass presentation-geometry () ())

(defclass presentation-mapping () ())

(defclass functional-presentation-mapping (presentation-mapping)
  ((function :initarg :function :reader presentation-mapping-function)
   (inverse-function :initarg :inverse-function :initform nil
                     :reader presentation-mapping-inverse-function)))

(defgeneric map-presentation-point (mapping item output-x output-y))
(defgeneric unmap-presentation-point (mapping item surface-x surface-y))

(defclass mesh-geometry (presentation-geometry)
  ((vertices :initarg :vertices :reader mesh-geometry-vertices)
   (vertex-count :initarg :vertex-count :reader mesh-geometry-vertex-count)))

(defun make-mesh-geometry (vertices)
  (let ((values (coerce vertices 'vector)))
    (unless (zerop (mod (length values) 12))
      (error 'compositor-error))
    (make-instance 'mesh-geometry :vertices values
                   :vertex-count (/ (length values) 4))))

(defun mesh-geometry-bounds (geometry)
  (let ((vertices (mesh-geometry-vertices geometry)))
    (if (zerop (length vertices))
        (values 0d0 0d0 0d0 0d0)
        (loop with minimum-x = most-positive-double-float
              with minimum-y = most-positive-double-float
              with maximum-x = most-negative-double-float
              with maximum-y = most-negative-double-float
              for offset from 0 below (length vertices) by 4
              for x = (coerce (aref vertices offset) 'double-float)
              for y = (coerce (aref vertices (+ offset 1)) 'double-float)
              do (setf minimum-x (min minimum-x x)
                       minimum-y (min minimum-y y)
                       maximum-x (max maximum-x x)
                       maximum-y (max maximum-y y))
              finally
                 (return (values minimum-x minimum-y
                                 (- maximum-x minimum-x)
                                 (- maximum-y minimum-y)))))))

(defclass presentation-material () ())

(defclass solid-color-material (presentation-material)
  ((color :initarg :color :reader material-color)))

(defclass surface-texture-material (presentation-material)
  ((texture :initarg :texture :reader material-texture)
   (source-x :initarg :source-x :initform 0d0 :reader material-source-x)
   (source-y :initarg :source-y :initform 0d0 :reader material-source-y)
   (source-width :initarg :source-width :initform 1d0
                 :reader material-source-width)
   (source-height :initarg :source-height :initform 1d0
                  :reader material-source-height)
   (transform :initarg :transform :initform 0 :reader material-transform)
   (opacity :initarg :opacity :initform 1d0 :reader material-opacity)
   (program-name :initarg :program-name :initform nil
                 :reader material-program-name)
   (uniforms :initarg :uniforms :initform nil :reader material-uniforms)))

(defclass shader-material (presentation-material)
  ((program-name :initarg :program-name :reader material-program-name)
   (uniforms :initarg :uniforms :initform nil :reader material-uniforms)))

(defclass presentation-item ()
  ((material :initarg :material :reader presentation-item-material)
   (owner :initarg :owner :initform nil :reader presentation-item-owner)
   (surface :initarg :surface :initform nil :reader presentation-item-surface)
   (x :initarg :x :reader presentation-item-x)
   (y :initarg :y :reader presentation-item-y)
   (width :initarg :width :reader presentation-item-width)
   (height :initarg :height :reader presentation-item-height)
   (geometry :initarg :geometry :initform nil
             :reader presentation-item-geometry)
   (mapping :initarg :mapping :initform nil
            :reader presentation-item-mapping)
   (interactive-p :initarg :interactive-p :initform nil
                  :reader presentation-item-interactive-p)
   (hit-kind :initarg :hit-kind :initform nil :reader presentation-item-hit-kind)
   (source-width :initarg :source-width :initform 1d0
                 :reader presentation-item-source-width)
   (source-height :initarg :source-height :initform 1d0
                  :reader presentation-item-source-height)))

(defclass presentation-snapshot ()
  ((output :initarg :output :reader snapshot-output)
   (timestamp :initarg :timestamp :reader snapshot-timestamp)
   (revision :initarg :revision :reader snapshot-revision)
   (items :initarg :items :reader snapshot-items)))

(defclass render-pass ()
  ((name :initarg :name :initform nil :reader render-pass-name)
   (target :initarg :target :initform :output :reader render-pass-target)
   (damage-mode :initarg :damage-mode :initform :frame
                :reader render-pass-damage-mode)))

(defclass item-render-pass (render-pass)
  ((items :initarg :items :reader render-pass-items)))

(defclass present-render-pass (render-pass) ())

(defclass frame-plan ()
  ((snapshot :initarg :snapshot :reader frame-plan-snapshot)
   (passes :initarg :passes :reader frame-plan-passes)
   (damage :initarg :damage :initform nil :accessor frame-plan-damage)
   (continuous-p :initarg :continuous-p :initform nil
                 :reader frame-plan-continuous-p)))

(defclass frame-context ()
  ((output :initarg :output :reader frame-context-output)
   (plan :initarg :plan :reader frame-context-plan)
   (snapshot :initarg :snapshot :reader frame-context-snapshot)
   (state :initarg :state :reader frame-context-state)
   (buffer :initarg :buffer :reader frame-context-buffer)
   (framebuffer :initarg :framebuffer :reader frame-context-framebuffer)
   (scene-framebuffer :initform 0 :accessor frame-context-scene-framebuffer)
   (scene-texture :initform 0 :accessor frame-context-scene-texture)
   (scene-target :initform nil :accessor frame-context-scene-target)
   (scene-initialized-p :initform nil
                        :accessor frame-context-scene-initialized-p)
   (scene-updated-p :initform nil :accessor frame-context-scene-updated-p)
   (width :initarg :width :reader frame-context-width)
   (height :initarg :height :reader frame-context-height)))

(defstruct (presentation-hit
             (:constructor make-presentation-hit
                 (&key item owner surface surface-x surface-y kind)))
  item owner surface
  (surface-x 0d0 :type double-float)
  (surface-y 0d0 :type double-float)
  kind)

(defun compositor-outputs-list (outputs)
  (remove-if-not #'output-available-p (copy-list (output-order outputs))))

(defun find-compositor-output (outputs native)
  (gethash native (output-table outputs)))

(defun default-compositor-output (compositor)
  (first (compositor-outputs-list (compositor-outputs compositor))))

(defun output-layout-width (output)
  (coerce (ataxia.runtime:output-width (output-native output)) 'double-float))

(defun output-layout-height (output)
  (coerce (ataxia.runtime:output-height (output-native output)) 'double-float))

(defun full-output-damage (output)
  (make-instance
   'frame-damage :full-p t
   :boxes (list (make-damage-box
                 0 0 (ataxia.runtime:output-width (output-native output))
                 (ataxia.runtime:output-height (output-native output))))))

(defun current-output-damage (output)
  (if (or (output-full-damage-p output)
          (null (output-last-snapshot output)))
      (full-output-damage output)
      (let ((boxes (output-damage-boxes output)))
        (make-instance
         'frame-damage
         :boxes
         (when boxes
           (list
            (reduce
             (lambda (left right)
               (let ((x (min (damage-box-x left) (damage-box-x right)))
                     (y (min (damage-box-y left) (damage-box-y right)))
                     (right-edge
                       (max (+ (damage-box-x left) (damage-box-width left))
                            (+ (damage-box-x right) (damage-box-width right))))
                     (bottom-edge
                       (max (+ (damage-box-y left) (damage-box-height left))
                            (+ (damage-box-y right) (damage-box-height right)))))
                 (make-damage-box x y (- right-edge x) (- bottom-edge y))))
             boxes)))))))

(defun reset-output-damage (output)
  (setf (output-full-damage-p output) nil
        (output-damage-boxes output) nil)
  output)

(defun clamp-damage-box (output box)
  (let* ((width (ataxia.runtime:output-width (output-native output)))
         (height (ataxia.runtime:output-height (output-native output)))
         (left (max 0 (damage-box-x box)))
         (top (max 0 (damage-box-y box)))
         (right (min width (+ (damage-box-x box) (damage-box-width box))))
         (bottom (min height (+ (damage-box-y box) (damage-box-height box)))))
    (when (and (< left right) (< top bottom))
      (make-damage-box left top (- right left) (- bottom top)))))

(defun accumulate-output-damage (output damage)
  (cond
    ((or (null damage) (eq damage :full))
     (setf (output-full-damage-p output) t
           (output-damage-boxes output) nil))
    ((not (output-full-damage-p output))
     (let ((boxes
             (remove nil
                     (mapcar (lambda (box) (clamp-damage-box output box))
                             damage))))
       (setf (output-damage-boxes output)
             (nconc boxes (output-damage-boxes output)))
       (when (> (length (output-damage-boxes output)) 64)
         (setf (output-full-damage-p output) t
               (output-damage-boxes output) nil)))))
  output)

(defun output-contains-layout-point-p (output x y)
  (and (<= (output-layout-x output) x)
       (< x (+ (output-layout-x output) (output-layout-width output)))
       (<= (output-layout-y output) y)
       (< y (+ (output-layout-y output) (output-layout-height output)))))

(defun output-at-layout-position (outputs x y)
  (find-if (lambda (output) (output-contains-layout-point-p output x y))
           (compositor-outputs-list outputs)))

(defun output-local-position (output layout-x layout-y)
  (values (- layout-x (output-layout-x output))
          (- layout-y (output-layout-y output))))

(defun output-layout-bounds (outputs)
  (let ((available (compositor-outputs-list outputs)))
    (when available
      (values
       (reduce #'min available :key #'output-layout-x)
       (reduce #'min available :key #'output-layout-y)
       (reduce #'max available
               :key (lambda (output)
                      (+ (output-layout-x output) (output-layout-width output))))
       (reduce #'max available
               :key (lambda (output)
                      (+ (output-layout-y output) (output-layout-height output))))))))

(defun confine-layout-position (outputs x y)
  "Return the output and nearest valid layout position for X and Y."
  (let ((containing (output-at-layout-position outputs x y)))
    (when containing
      (return-from confine-layout-position (values containing x y))))
  (let ((best-output nil)
        (best-x 0d0)
        (best-y 0d0)
        (best-distance most-positive-double-float))
    (dolist (output (compositor-outputs-list outputs))
      (let* ((minimum-x (output-layout-x output))
             (minimum-y (output-layout-y output))
             (maximum-x (+ minimum-x (max 0d0 (1- (output-layout-width output)))))
             (maximum-y (+ minimum-y (max 0d0 (1- (output-layout-height output)))))
             (candidate-x (max minimum-x (min maximum-x x)))
             (candidate-y (max minimum-y (min maximum-y y)))
             (distance (+ (expt (- candidate-x x) 2)
                          (expt (- candidate-y y) 2))))
        (when (< distance best-distance)
          (setf best-output output
                best-x candidate-x
                best-y candidate-y
                best-distance distance))))
    (values best-output best-x best-y)))

(defun next-horizontal-output-x (outputs)
  (reduce #'max (compositor-outputs-list outputs)
          :initial-value 0d0
          :key (lambda (output)
                 (+ (output-layout-x output) (output-layout-width output)))))

(defun set-output-layout-position (output x y)
  (setf (output-layout-x output) (coerce x 'double-float)
        (output-layout-y output) (coerce y 'double-float))
  output)

(defun output-scanout-pending-p (output)
  (or (output-commit-pending-p output)
      (ataxia.runtime:output-frame-pending-p (output-native output))))

(defun output-frame-delay-milliseconds (output)
  (let* ((elapsed (- (monotonic-seconds)
                     (output-last-present-time output)))
         (remaining (max 0d0 (- (output-refresh-seconds output) elapsed))))
    (max 1 (ceiling (* remaining 1000d0)))))

(defun arm-output-frame (output)
  "Coalesce redraws and ask wlroots for one frame at the next refresh deadline."
  (when (and (output-available-p output)
             (output-frame-timer output)
             (not (output-frame-timer-armed-p output))
             (not (output-scanout-pending-p output)))
    (ataxia.runtime:update-event-loop-timer
     (output-frame-timer output)
     (output-frame-delay-milliseconds output))
    (setf (output-frame-timer-armed-p output) t))
  output)

(defun request-output-frame-now (output)
  (when (and (output-available-p output)
             (not (output-frame-requested-p output))
             (not (output-scanout-pending-p output)))
    (setf (output-frame-requested-p output) t)
    (ataxia.runtime:output-schedule-frame (output-native output)))
  output)

(defun install-output-frame-timer (runtime output)
  (setf
   (output-frame-timer output)
   (ataxia.runtime:add-event-loop-timer
    runtime
    (lambda (source)
      (declare (ignore source))
      (setf (output-frame-timer-armed-p output) nil)
      (when (and (output-available-p output)
                 (output-redraw-pending-p output)
                 (not (output-scanout-pending-p output)))
        (request-output-frame-now output))
      0)))
  output)

(defun record-output-presentation (output event)
  (setf (output-last-present-time output) (monotonic-seconds))
  (let ((refresh-nanoseconds
          (ataxia.runtime:output-present-refresh-nanoseconds event)))
    (when (plusp refresh-nanoseconds)
      (setf (output-refresh-seconds output)
            (/ (coerce refresh-nanoseconds 'double-float) 1d9))))
  (setf (output-commit-pending-p output) nil)
  (when (output-redraw-pending-p output)
    (arm-output-frame output))
  output)

(defun configure-native-output (runtime native)
  (ataxia.runtime:initialize-output-render
   native (ataxia.runtime:runtime-allocator runtime)
   (ataxia.runtime:runtime-renderer runtime))
  (let ((state (ataxia.runtime:create-output-state native)))
    (unwind-protect
         (progn
           (ataxia.runtime:output-state-set-enabled state t)
           (let ((mode (ataxia.runtime:output-preferred-mode native)))
             (when mode
               (ataxia.runtime:output-state-set-mode state mode)))
           (unless (ataxia.runtime:output-test-state native state)
             (error 'ataxia.runtime:native-call-failed
                    :name :output-test-state
                    :detail (ataxia.runtime:output-name native)))
           (unless (ataxia.runtime:output-commit-state native state)
             (error 'ataxia.runtime:native-call-failed
                    :name :output-commit-state
                    :detail (ataxia.runtime:output-name native))))
      (ataxia.runtime:destroy-output-state state)))
  (ataxia.runtime:create-output-global native)
  (ataxia.runtime:configure-output-swapchain native))

(defun register-compositor-output (outputs runtime native)
  (handler-case
      (let* ((layout-x (next-horizontal-output-x outputs))
             (swapchain (configure-native-output runtime native))
             (output
               (make-instance 'compositor-output
                              :native native :swapchain swapchain
                              :layout-x layout-x :layout-y 0d0))
             (published-p nil))
        (unwind-protect
             (progn
               ;; Install callback-owned resources before publishing the
               ;; output to the rest of the compositor as fully usable.
               (install-output-frame-timer runtime output)
               (setf (gethash native (output-table outputs)) output
                     (output-order outputs)
                     (append (output-order outputs) (list output))
                     published-p t)
               output)
          (unless published-p
            (when (and (output-frame-timer output)
                       (ataxia.runtime:native-object-live-p
                        (output-frame-timer output)))
              (ataxia.runtime:remove-event-loop-source
               (output-frame-timer output)))
            (when (ataxia.runtime:native-object-live-p swapchain)
              (ataxia.runtime:destroy-output-swapchain swapchain)))))
    (ataxia.runtime:native-call-failed (condition)
      (format *error-output* "[compositor] output unavailable ~A: ~A~%"
              (or (ataxia.runtime:output-name native) "unknown") condition)
      (finish-output *error-output*)
      nil)))

(defun unregister-compositor-output (outputs native)
  (let ((output (gethash native (output-table outputs))))
    (when output
      (setf (output-available-p output) nil)
      (when (and (output-frame-timer output)
                 (ataxia.runtime:native-object-live-p
                  (output-frame-timer output)))
        (ataxia.runtime:remove-event-loop-source
         (output-frame-timer output)))
      (setf (output-frame-timer output) nil
            (output-frame-timer-armed-p output) nil
            (output-frame-requested-p output) nil)
      (when (and (output-swapchain output)
                 (ataxia.runtime:native-object-live-p
                  (output-swapchain output)))
        (ataxia.runtime:destroy-output-swapchain
         (output-swapchain output)))
      (setf (output-order outputs)
            (delete output (output-order outputs) :test #'eq))
      (remhash native (output-table outputs)))
    output))

(defun make-solid-item
    (x y width height color &key owner interactive-p hit-kind geometry)
  (make-instance 'presentation-item
                 :material (make-instance 'solid-color-material :color color)
                 :x x :y y :width width :height height
                 :owner owner :interactive-p interactive-p
                 :hit-kind hit-kind :geometry geometry))

(defun make-surface-item
    (surface x y width height texture
     &key owner (opacity 1d0) program-name uniforms geometry mapping
       record interactive-p hit-kind (source-width 1d0) (source-height 1d0)
       (texture-source-x 0d0) (texture-source-y 0d0)
       (texture-source-width 1d0) (texture-source-height 1d0)
       (texture-transform 0))
  (make-instance
   'presentation-item
   :material (make-instance 'surface-texture-material
                            :texture texture :opacity opacity
                            :source-x
                            (if record (surface-record-texture-source-x record)
                                texture-source-x)
                            :source-y
                            (if record (surface-record-texture-source-y record)
                                texture-source-y)
                            :source-width
                            (if record
                                (surface-record-texture-source-width record)
                                texture-source-width)
                            :source-height
                            (if record
                                (surface-record-texture-source-height record)
                                texture-source-height)
                            :transform
                            (if record (surface-record-texture-transform record)
                                texture-transform)
                            :program-name program-name :uniforms uniforms)
   :surface surface :x x :y y :width width :height height
   :owner owner :geometry geometry :mapping mapping
   :interactive-p interactive-p :hit-kind hit-kind
   :source-width source-width :source-height source-height))

(defun make-shader-item
    (x y width height program-name uniforms &key owner geometry)
  "Create geometry whose visual meaning is entirely defined by a shader material."
  (make-instance
   'presentation-item
   :material (make-instance 'shader-material
                            :program-name program-name :uniforms uniforms)
   :x x :y y :width width :height height :owner owner :geometry geometry))

(defun scaled-view-geometry (x y width height state)
  (let* ((scale (presentation-scale state))
         (scaled-width (* width scale))
         (scaled-height (* height scale)))
    (values (+ x (/ (- width scaled-width) 2d0)
               (presentation-offset-x state))
            (+ y (/ (- height scaled-height) 2d0)
               (presentation-offset-y state))
            scaled-width scaled-height)))


(defmethod build-presentation-snapshot
    ((presentation presentation-system) (output compositor-output) timestamp)
  (let* ((compositor (component-compositor presentation))
         (policy (compositor-behavior-policy compositor)))
    (make-instance
     'presentation-snapshot :output output :timestamp timestamp
     :revision (incf (presentation-revision presentation))
     :items (behavior-build-scene policy presentation output timestamp))))

(defmethod build-frame-plan
    ((presentation presentation-system) (output compositor-output)
     (snapshot presentation-snapshot) timestamp)
  (let ((plan
          (behavior-compose-frame
           (compositor-behavior-policy (component-compositor presentation))
           presentation output snapshot timestamp)))
    (check-type plan frame-plan)
    (unless (frame-plan-damage plan)
      (setf (frame-plan-damage plan) (current-output-damage output)))
    plan))

(defun point-in-item-p (item x y)
  (and (<= (presentation-item-x item) x
           (+ (presentation-item-x item) (presentation-item-width item)))
       (<= (presentation-item-y item) y
           (+ (presentation-item-y item) (presentation-item-height item)))))

(defun barycentric-coordinate (point-x point-y ax ay bx by cx cy)
  (let ((denominator
          (+ (* (- by cy) (- ax cx))
             (* (- cx bx) (- ay cy)))))
    (unless (< (abs denominator) 1d-12)
      (let* ((first
               (/ (+ (* (- by cy) (- point-x cx))
                     (* (- cx bx) (- point-y cy)))
                  denominator))
             (second
               (/ (+ (* (- cy ay) (- point-x cx))
                     (* (- ax cx) (- point-y cy)))
                  denominator))
             (third (- 1d0 first second)))
        (when (and (>= first -1d-7) (>= second -1d-7) (>= third -1d-7))
          (values first second third))))))

(defun mesh-local-point (geometry output-x output-y source-width source-height)
  (let ((vertices (mesh-geometry-vertices geometry)))
    (loop for offset from 0 below (length vertices) by 12
          do (multiple-value-bind (first second third)
                 (barycentric-coordinate
                  output-x output-y
                  (aref vertices offset) (aref vertices (+ offset 1))
                  (aref vertices (+ offset 4)) (aref vertices (+ offset 5))
                  (aref vertices (+ offset 8)) (aref vertices (+ offset 9)))
               (when first
                 (let ((texture-x
                         (+ (* first (aref vertices (+ offset 2)))
                            (* second (aref vertices (+ offset 6)))
                            (* third (aref vertices (+ offset 10)))))
                       (texture-y
                         (+ (* first (aref vertices (+ offset 3)))
                            (* second (aref vertices (+ offset 7)))
                            (* third (aref vertices (+ offset 11))))))
                   (return
                     (values t (* texture-x source-width)
                             (* texture-y source-height))))))
          finally (return (values nil 0d0 0d0)))))

(defmethod map-presentation-point
    ((mapping functional-presentation-mapping) item output-x output-y)
  (funcall (presentation-mapping-function mapping)
           item output-x output-y))

(defmethod map-presentation-point
    ((mapping null) item output-x output-y)
  (let ((geometry (presentation-item-geometry item)))
    (if (typep geometry 'mesh-geometry)
        (mesh-local-point
         geometry output-x output-y
         (presentation-item-source-width item)
         (presentation-item-source-height item))
        (values
         t
         (* (/ (- output-x (presentation-item-x item))
               (max 1d0 (presentation-item-width item)))
            (presentation-item-source-width item))
         (* (/ (- output-y (presentation-item-y item))
               (max 1d0 (presentation-item-height item)))
            (presentation-item-source-height item))))))

(defun mesh-output-point
    (geometry surface-x surface-y source-width source-height)
  (let ((vertices (mesh-geometry-vertices geometry))
        (texture-x (/ surface-x (max 1d0 source-width)))
        (texture-y (/ surface-y (max 1d0 source-height))))
    (loop for offset from 0 below (length vertices) by 12
          do (multiple-value-bind (first second third)
                 (barycentric-coordinate
                  texture-x texture-y
                  (aref vertices (+ offset 2))
                  (aref vertices (+ offset 3))
                  (aref vertices (+ offset 6))
                  (aref vertices (+ offset 7))
                  (aref vertices (+ offset 10))
                  (aref vertices (+ offset 11)))
               (when first
                 (return
                   (values
                    t
                    (+ (* first (aref vertices offset))
                       (* second (aref vertices (+ offset 4)))
                       (* third (aref vertices (+ offset 8))))
                    (+ (* first (aref vertices (+ offset 1)))
                       (* second (aref vertices (+ offset 5)))
                       (* third (aref vertices (+ offset 9))))))))
          finally (return (values nil 0d0 0d0)))))

(defun default-unmap-presentation-point (item surface-x surface-y)
  (let ((geometry (presentation-item-geometry item)))
    (if (typep geometry 'mesh-geometry)
        (mesh-output-point
         geometry surface-x surface-y
         (presentation-item-source-width item)
         (presentation-item-source-height item))
        (values
         t
         (+ (presentation-item-x item)
            (* (/ surface-x
                  (max 1d0 (presentation-item-source-width item)))
               (presentation-item-width item)))
         (+ (presentation-item-y item)
            (* (/ surface-y
                  (max 1d0 (presentation-item-source-height item)))
               (presentation-item-height item)))))))

(defmethod unmap-presentation-point
    ((mapping presentation-mapping) item surface-x surface-y)
  (declare (ignore mapping))
  (default-unmap-presentation-point item surface-x surface-y))

(defmethod unmap-presentation-point
    ((mapping functional-presentation-mapping) item surface-x surface-y)
  (let ((inverse (presentation-mapping-inverse-function mapping)))
    (if inverse
        (funcall inverse item surface-x surface-y)
        (default-unmap-presentation-point item surface-x surface-y))))

(defmethod unmap-presentation-point
    ((mapping null) item surface-x surface-y)
  (default-unmap-presentation-point item surface-x surface-y))

(defun presentation-item-local-point (item output-x output-y)
  (map-presentation-point
   (presentation-item-mapping item) item output-x output-y))

(defun presentation-item-output-point (item surface-x surface-y)
  (unmap-presentation-point
   (presentation-item-mapping item) item surface-x surface-y))

(defun presentation-item-live-p (item)
  "Reject geometry that still references a surface retired after the snapshot."
  (let ((surface (presentation-item-surface item))
        (owner (presentation-item-owner item)))
    (and (or (null surface)
             (ataxia.runtime:native-object-live-p surface))
         (typecase owner
           (view
            (and (ataxia.runtime:native-object-live-p (view-native owner))
                 (ataxia.runtime:native-object-live-p
                  (surface-record-native (view-surface owner)))))
           (popup-view
            (let ((parent (popup-parent-view owner)))
              (and (ataxia.runtime:native-object-live-p (popup-native owner))
                   (ataxia.runtime:native-object-live-p
                    (surface-record-native (popup-surface owner)))
                   (or (null parent)
                       (ataxia.runtime:native-object-live-p
                        (view-native parent))))))
           (t t)))))

(defmethod presentation-hit-test
    ((snapshot presentation-snapshot) output-x output-y)
  (dolist (item (reverse (snapshot-items snapshot)))
    (when (and (presentation-item-live-p item)
               (presentation-item-interactive-p item)
               (point-in-item-p item output-x output-y))
      (multiple-value-bind (inside-p local-x local-y)
          (presentation-item-local-point item output-x output-y)
        (when inside-p
          (let* ((kind (presentation-item-hit-kind item))
                 (surface nil)
                 (surface-x local-x)
                 (surface-y local-y))
            (case kind
              (:content
               (multiple-value-setq (surface surface-x surface-y)
                 (ataxia.runtime:xdg-surface-at
                  (view-native (presentation-item-owner item))
                  local-x local-y)))
              ((:popup :subsurface)
               (multiple-value-setq (surface surface-x surface-y)
                 (ataxia.runtime:surface-at
                  (presentation-item-surface item) local-x local-y))))
            ;; wlroots may exclude pixels through a surface input region.
            (when (or surface (member kind '(:frame :titlebar) :test #'eq))
              (return
                (make-presentation-hit
                 :item item :owner (presentation-item-owner item)
                 :surface surface
                 :surface-x (coerce surface-x 'double-float)
                 :surface-y (coerce surface-y 'double-float)
                 :kind kind)))))))))

(defmethod renderer-draw-item
    ((renderer direct-gles-renderer) frame-context
     (item presentation-item))
  (renderer-draw-material
   renderer frame-context item (presentation-item-material item))
  item)

(defun validate-presentation-snapshot-resources (renderer snapshot)
  (dolist (item (snapshot-items snapshot))
    (let ((material (presentation-item-material item)))
      (typecase material
        (surface-texture-material
         (when (material-program-name material)
           (shader-program-for-texture
            renderer (material-program-name material)
            (ataxia.runtime:gles-texture-target
             (material-texture material)))))
        (shader-material
         (shader-program-for-material
          renderer (material-program-name material))))))
  snapshot)

(defmethod renderer-execute-pass
    ((renderer direct-gles-renderer) frame-context (pass item-render-pass))
  (if (eq :scene (render-pass-target pass))
      (let* ((damage (frame-plan-damage (frame-context-plan frame-context)))
             (boxes
               (if (or (frame-damage-full-p damage)
                       (not (frame-context-scene-initialized-p frame-context)))
                   (frame-damage-boxes
                    (full-output-damage (frame-context-output frame-context)))
                   (frame-damage-boxes damage))))
        (dolist (box boxes)
          (renderer-clip-damage-box box)
          (renderer-clear-current-target)
          (dolist (item (render-pass-items pass))
            (when (and (< (presentation-item-x item)
                          (+ (damage-box-x box) (damage-box-width box)))
                       (< (damage-box-x box)
                          (+ (presentation-item-x item)
                             (presentation-item-width item)))
                       (< (presentation-item-y item)
                          (+ (damage-box-y box) (damage-box-height box)))
                       (< (damage-box-y box)
                          (+ (presentation-item-y item)
                             (presentation-item-height item))))
              (renderer-draw-item renderer frame-context item))))
        (setf (frame-context-scene-updated-p frame-context) t)
        (renderer-disable-damage-clip))
      (dolist (item (render-pass-items pass))
        (renderer-draw-item renderer frame-context item)))
  pass)

(defmethod renderer-execute-pass
    ((renderer direct-gles-renderer) frame-context (pass present-render-pass))
  (declare (ignore pass))
  (renderer-present-retained-scene renderer frame-context))

(defmethod renderer-execute-pass :around
    ((renderer direct-gles-renderer) frame-context (pass render-pass))
  (renderer-bind-target renderer frame-context (render-pass-target pass))
  (call-next-method))

(defmethod renderer-execute-pass
    ((renderer direct-gles-renderer) frame-context (pass render-pass))
  (declare (ignore renderer frame-context))
  (error 'graphics-failure
         :operation :execute-render-pass
         :detail (format nil "No executor for ~S" (class-of pass))))

(defmethod renderer-draw-material
    ((renderer direct-gles-renderer) frame-context
     (item presentation-item) (material solid-color-material))
  (draw-solid-rectangle
   renderer (frame-context-width frame-context)
   (frame-context-height frame-context)
   (presentation-item-x item) (presentation-item-y item)
   (presentation-item-width item) (presentation-item-height item)
   (material-color material) (presentation-item-geometry item)))

(defmethod renderer-draw-material
    ((renderer direct-gles-renderer) frame-context
     (item presentation-item) (material surface-texture-material))
  (draw-textured-rectangle
   renderer (frame-context-width frame-context)
   (frame-context-height frame-context)
   (presentation-item-x item) (presentation-item-y item)
   (presentation-item-width item) (presentation-item-height item)
   (material-texture material) (material-opacity material)
   (material-program-name material) (material-uniforms material)
   (presentation-item-geometry item)
   (material-source-x material) (material-source-y material)
   (material-source-width material) (material-source-height material)
   (material-transform material)))

(defun synchronize-output-surface-membership (compositor output snapshot)
  "Synchronize wl_surface output membership with one committed snapshot."
  (let ((visible (make-hash-table :test #'eq))
        (records (surface-records (compositor-surfaces compositor))))
    (dolist (item (snapshot-items snapshot))
      (let* ((surface (presentation-item-surface item))
             (record (and surface (gethash surface records))))
        (when (and record (surface-record-mapped-p record))
          (setf (gethash record visible) t))))
    (maphash
     (lambda (surface record)
       (declare (ignore surface))
       (if (gethash record visible)
           (surface-enter-output record output)
           (surface-leave-output record output)))
     records))
  snapshot)

(defun mark-snapshot-presentation-feedback (output snapshot)
  (dolist (surface
            (remove-duplicates
             (remove nil (mapcar #'presentation-item-surface
                                 (snapshot-items snapshot)))
             :test #'eq))
    (when (ataxia.runtime:native-object-live-p surface)
      (ataxia.runtime:mark-surface-textured-on-output
       surface (output-native output))))
  snapshot)

(defmethod renderer-draw-material
    ((renderer direct-gles-renderer) frame-context
     (item presentation-item) (material shader-material))
  (draw-shader-material
   renderer (frame-context-width frame-context)
   (frame-context-height frame-context)
   (presentation-item-x item) (presentation-item-y item)
   (presentation-item-width item) (presentation-item-height item)
   (material-program-name material) (material-uniforms material)
   (presentation-item-geometry item)))

(defmethod render-presentation-frame
    ((presentation presentation-system) (output compositor-output)
     (plan frame-plan))
  (let* ((compositor (component-compositor presentation))
         (snapshot (frame-plan-snapshot plan))
         (runtime (compositor-runtime compositor))
         (renderer (compositor-graphics compositor))
         (native (output-native output))
         (state (ataxia.runtime:create-output-state native))
         (buffer nil))
    (unwind-protect
         (progn
           (setf (output-swapchain output)
                 (ataxia.runtime:configure-output-swapchain
                  native (output-swapchain output)))
           (setf buffer
                 (ataxia.runtime:acquire-output-buffer
                  (output-swapchain output)))
           (let ((frame
                   (make-instance
                    'frame-context :output output :plan plan :snapshot snapshot
                    :state state :buffer buffer
                    :framebuffer
                    (ataxia.runtime:output-buffer-framebuffer
                     (ataxia.runtime:runtime-renderer runtime) buffer)
                    :width (ataxia.runtime:buffer-width buffer)
                    :height (ataxia.runtime:buffer-height buffer))))
             (ataxia.runtime:with-egl-context
                 ((ataxia.runtime:runtime-egl runtime))
               (renderer-begin-frame renderer output frame)
               (handler-case
                   (progn
                     (dolist (pass (frame-plan-passes plan))
                       (renderer-execute-pass renderer frame pass))
                     (renderer-end-frame renderer frame))
                 (serious-condition (condition)
                   (renderer-abort-frame renderer frame condition)
                   (error condition)))))
           (ataxia.runtime:output-state-set-buffer state buffer)
           (ataxia.runtime:output-state-set-damage
            state
            (mapcar
             (lambda (box)
               (ataxia.runtime:make-damage-rectangle
                (damage-box-x box) (damage-box-y box)
                (damage-box-width box) (damage-box-height box)))
             (frame-damage-boxes (frame-plan-damage plan))))
           (mark-snapshot-presentation-feedback output snapshot)
           (ataxia.runtime:release-buffer buffer)
           (setf buffer nil)
           (unless (ataxia.runtime:output-test-state native state)
             (error 'graphics-failure :operation :output-test))
           (unless (ataxia.runtime:output-commit-state native state)
             (error 'graphics-failure :operation :output-commit))
           (synchronize-output-surface-membership
            compositor output snapshot)
           (reset-output-damage output))
      (when (and buffer (ataxia.runtime:native-object-live-p buffer))
        (ataxia.runtime:release-buffer buffer))
      (ataxia.runtime:destroy-output-state state)))
  (setf (output-last-snapshot output) (frame-plan-snapshot plan))
  (incf (output-frame-revision output))
  (let ((surfaces
           (remove-duplicates
           (remove nil (mapcar #'presentation-item-surface
                               (snapshot-items (frame-plan-snapshot plan))))
           :test #'eq)))
    (dolist (surface surfaces)
      (when (ataxia.runtime:native-object-live-p surface)
        (ataxia.runtime:surface-send-frame-done surface))))
  (frame-plan-snapshot plan))

(defun present-output-at
    (presentation output timestamp &key (sample-animations-p t))
  (when sample-animations-p
    (sample-animations
     (presentation-animation-engine presentation) timestamp))
  (handler-case
      (let* ((snapshot
               (build-presentation-snapshot presentation output timestamp))
             (plan
               (build-frame-plan presentation output snapshot timestamp)))
        (setf (output-redraw-pending-p output) nil)
        (render-presentation-frame presentation output plan)
        (setf (output-commit-pending-p output) t)
        (trace-output
         "[output] commit ~A revision=~D native-pending=~A~%"
         (ataxia.runtime:output-name (output-native output))
         (output-frame-revision output)
         (ataxia.runtime:output-frame-pending-p (output-native output)))
        (when (or (frame-plan-continuous-p plan)
                  (active-animations-p
                   (presentation-animation-engine presentation)))
          (accumulate-output-damage output :full)
          (setf (output-redraw-pending-p output) t))
        snapshot)
    (serious-condition (condition)
      (format *error-output* "[compositor] frame failed on ~A: ~A~%"
              (ataxia.runtime:output-name (output-native output)) condition)
      (finish-output *error-output*)
      ;; Transient DRM busy failures must not strand the output without a
      ;; future frame. If scanout is pending, its presentation callback owns
      ;; the retry; otherwise wlroots may schedule immediately.
      (setf (output-redraw-pending-p output) t)
      (trace-output
       "[output] failure ~A lisp-pending=~A native-pending=~A~%"
       (ataxia.runtime:output-name (output-native output))
       (output-commit-pending-p output)
       (ataxia.runtime:output-frame-pending-p (output-native output)))
      (arm-output-frame output)
      nil)))

(defmethod present-output
    ((presentation presentation-system) (output compositor-output))
  (present-output-at presentation output (monotonic-seconds)))

(defun queue-output-presentation (presentation output)
  ;; One idle callback samples global animation state once, then every output
  ;; ready in that event-loop batch observes the exact same values.
  (pushnew output (presentation-queued-outputs presentation) :test #'eq)
  (unless (presentation-render-source presentation)
    (setf
     (presentation-render-source presentation)
     (ataxia.runtime:add-event-loop-idle
      (compositor-runtime (component-compositor presentation))
      (lambda (source)
        (declare (ignore source))
        (setf (presentation-render-source presentation) nil)
        (let ((outputs (prog1 (nreverse
                               (presentation-queued-outputs presentation))
                         (setf (presentation-queued-outputs presentation) nil)))
              (timestamp (monotonic-seconds)))
          (sample-animations
           (presentation-animation-engine presentation) timestamp)
          (dolist (candidate outputs)
            (when (and (output-available-p candidate)
                       (output-redraw-pending-p candidate)
                       (not (output-scanout-pending-p candidate)))
              (present-output-at
               presentation candidate timestamp :sample-animations-p nil))))
        0))))
  output)

(defmethod schedule-presentation
    ((presentation presentation-system) &optional output (damage :full))
  (let ((outputs (compositor-outputs (component-compositor presentation))))
    (dolist (candidate
              (if output
                  (list output)
                  (compositor-outputs-list outputs)))
      (when (output-available-p candidate)
        (accumulate-output-damage candidate damage)
        (setf (output-redraw-pending-p candidate) t)
        (trace-output
         "[output] request ~A lisp-pending=~A native-pending=~A~%"
         (ataxia.runtime:output-name (output-native candidate))
         (output-commit-pending-p candidate)
         (ataxia.runtime:output-frame-pending-p (output-native candidate)))
        ;; Once the backend frame cycle has produced a snapshot, it owns
        ;; pacing. Manual scheduling here would create idle frames faster than
        ;; DRM refresh and can race a just-presented page flip.
        (if (null (output-last-snapshot candidate))
            (unless (output-scanout-pending-p candidate)
              (request-output-frame-now candidate))
            (arm-output-frame candidate)))))
  presentation)
