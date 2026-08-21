;;;; Planar behavior policy state and lifecycle.
;;;;
;;;; The planar controller directly owns its world, output cameras, seats,
;;;; visual choices, and compositor-facing behavior endpoints.

(in-package #:ataxia.compositor)

(defclass planar-placement (behavior-placement)
  ((x :initarg :x :accessor placement-x)
   (y :initarg :y :accessor placement-y)
   (width :initarg :width :accessor placement-width)
   (height :initarg :height :accessor placement-height)
   (z :initarg :z :initform 0d0 :accessor placement-z)))

(defclass planar-behavior-state (behavior-view-state) ())

(defclass planar-viewport ()
  ((camera-x :initarg :camera-x :initform 0d0
             :accessor planar-viewport-camera-x)
   (camera-y :initarg :camera-y :initform 0d0
             :accessor planar-viewport-camera-y)
   (scale :initarg :scale :initform 1d0
          :accessor planar-viewport-scale)))

(defclass planar-behavior-policy (behavior-policy)
  ((application-reveal-style
    :initarg :application-reveal-style
    :initform (make-instance 'codec-reveal-style)
    :accessor behavior-application-reveal-style)
   (background-color :initarg :background-color
                     :initform '(0.035 0.045 0.065 1.0)
                     :accessor behavior-background-color)
   (seat-states :initform (make-hash-table :test #'eq)
                :reader behavior-seat-states)
   (panel-height :initarg :panel-height :initform 32d0
                 :reader behavior-panel-height)
   (titlebar-height :initarg :titlebar-height :initform 28d0
                    :reader behavior-titlebar-height)
   (cascade-x :initform 48d0 :accessor planar-cascade-x)
   (cascade-y :initform 68d0 :accessor planar-cascade-y)
   (cascade-step :initform 36d0 :reader planar-cascade-step)
   (next-z :initform 0d0 :accessor planar-next-z)
   (shadow-style :initarg :shadow-style
                 :initform (make-instance 'soft-shadow-style)
                 :accessor behavior-shadow-style)))

(defmethod activate-behavior-policy ((policy behavior-policy))
  (setf (behavior-policy-active-p policy) t)
  policy)

(defmethod quiesce-behavior-policy
    ((policy behavior-policy) reason)
  (declare (ignore reason))
  (setf (behavior-policy-active-p policy) nil)
  policy)

(defmethod attach-component :after ((policy behavior-policy))
  (activate-behavior-policy policy))

(defmethod detach-component :before
    ((policy behavior-policy) reason)
  (quiesce-behavior-policy policy reason)
  (let* ((compositor (component-compositor policy))
         (renderer
           (and (slot-boundp compositor 'graphics)
                (compositor-graphics compositor))))
    (when (and renderer (eq (component-state renderer) :attached))
      (release-shader-program-owner renderer policy))))

(defmacro define-policy-lifecycle-methods (policy-class)
  `(progn
     (defmethod behavior-output-removing
         ((policy ,policy-class) output)
       (setf (output-behavior-state output) nil)
       (incf (behavior-policy-revision policy))
       output)

     (defmethod behavior-view-mapped ((policy ,policy-class) view)
       (incf (behavior-policy-revision policy))
       view)

     (defmethod behavior-view-unmapped ((policy ,policy-class) view)
       (incf (behavior-policy-revision policy))
       view)

     (defmethod behavior-view-destroying ((policy ,policy-class) view)
       (incf (behavior-policy-revision policy))
       view)

     (defmethod behavior-view-identity-changed
         ((policy ,policy-class) view kind value)
       (declare (ignore kind value))
       (incf (behavior-policy-revision policy))
       view)

     (defmethod behavior-focus-changed
         ((policy ,policy-class) seat previous view)
       (declare (ignore seat previous))
       (when view
         (desktop-raise-view
          (compositor-desktop (component-compositor policy)) view))
       (incf (behavior-policy-revision policy))
       view)

     (defmethod behavior-validate-resources
         ((policy ,policy-class) compositor snapshots context)
       (declare (ignore policy context))
       (let ((renderer (compositor-graphics compositor)))
         (dolist (entry snapshots)
           (validate-presentation-snapshot-resources renderer (cdr entry))))
       t)))

(define-policy-lifecycle-methods planar-behavior-policy)

(defun adopt-planar-behavior-state (view)
  (let ((state (view-behavior-state view)))
    (unless (typep state 'planar-behavior-state)
      (setf state
             (make-instance
             'planar-behavior-state
             :placement (and state (behavior-state-placement state))
             :restore-state (and state (behavior-state-restore-state state))
             :animation-policy
             (and state (behavior-state-animation-policy state))
             :shader-program-name
             (and state (behavior-state-shader-program-name state))
             :presentation-state
             (if state
                 (behavior-state-presentation-state state)
                 (make-instance 'presentation-state)))
            (view-behavior-state view) state))
    state))

(defmethod behavior-view-created
    ((policy planar-behavior-policy) view)
  (adopt-planar-behavior-state view)
  (behavior-place-view policy view nil))

(defmethod behavior-output-added
  ((policy planar-behavior-policy) output)
  (setf (output-behavior-state output) (make-instance 'planar-viewport))
  (incf (behavior-policy-revision policy))
  output)

(defmethod behavior-view-committed
    ((policy planar-behavior-policy) view commit initial-commit-p)
  (declare (ignore initial-commit-p))
  (let ((width (ataxia.runtime:surface-commit-width commit))
        (height (ataxia.runtime:surface-commit-height commit)))
    (when (plusp width)
      (let ((placement (view-placement view)))
        (when (typep placement 'planar-placement)
          (setf (placement-width placement) (coerce width 'double-float)
                (placement-height placement) (coerce height 'double-float))))))
  (incf (behavior-policy-revision policy))
  view)

(defmethod behavior-recommend-initial-size
    ((policy planar-behavior-policy) compositor view)
  (declare (ignore policy view))
  (let ((output (first (compositor-outputs-list
                        (compositor-outputs compositor)))))
    (values
     (if output
         (min 900 (max 320 (- (ataxia.runtime:output-width
                               (output-native output)) 96)))
         900)
     (if output
         (min 650 (max 240 (- (ataxia.runtime:output-height
                               (output-native output)) 128)))
         650))))

(defmethod behavior-set-view-size
    ((policy planar-behavior-policy) view width height context)
  (declare (ignore context))
  (let ((placement (view-placement view)))
    (when placement
      (setf (placement-width placement) (coerce width 'double-float)
            (placement-height placement) (coerce height 'double-float))))
  (incf (behavior-policy-revision policy))
  (make-instance 'view-configuration-decision :width width :height height))

(defmethod copy-behavior-placement
    ((policy planar-behavior-policy) (placement planar-placement))
  (declare (ignore policy))
  (make-instance 'planar-placement
                 :x (placement-x placement) :y (placement-y placement)
                 :width (placement-width placement)
                 :height (placement-height placement)
                 :z (placement-z placement)))

(defun copy-presentation-state (state)
  (let ((copy (make-instance 'presentation-state)))
    (setf (presentation-opacity copy) (presentation-opacity state)
          (presentation-scale copy) (presentation-scale state)
          (presentation-offset-x copy) (presentation-offset-x state)
          (presentation-offset-y copy) (presentation-offset-y state))
    (maphash
     (lambda (name value)
       (setf (gethash name (presentation-effect-parameters copy)) value))
     (presentation-effect-parameters state))
    (maphash
     (lambda (name value)
       (setf (gethash name (presentation-shader-uniforms copy)) value))
     (presentation-shader-uniforms state))
    copy))

(defmethod copy-behavior-view-state
    ((policy planar-behavior-policy) (state planar-behavior-state))
  (make-instance
   'planar-behavior-state
   :placement
   (and (behavior-state-placement state)
        (copy-behavior-placement policy (behavior-state-placement state)))
   :restore-state
   (and (behavior-state-restore-state state)
        (copy-behavior-placement
         policy (behavior-state-restore-state state)))
   :animation-policy (behavior-state-animation-policy state)
   :shader-program-name (behavior-state-shader-program-name state)
   :presentation-state
   (copy-presentation-state (behavior-state-presentation-state state))))

(defmethod copy-behavior-output-state
    ((policy planar-behavior-policy) (state planar-viewport))
  (declare (ignore policy))
  (make-instance 'planar-viewport
                 :camera-x (planar-viewport-camera-x state)
                 :camera-y (planar-viewport-camera-y state)
                 :scale (planar-viewport-scale state)))

(defun policy-first-output (policy)
  (first
   (compositor-outputs-list
    (compositor-outputs (component-compositor policy)))))

(defun make-portable-view-copy (state x y width height depth)
  (make-instance
   'portable-view-state
   :x x :y y :width width :height height :depth depth
   :animation-policy (behavior-state-animation-policy state)
   :shader-program-name (behavior-state-shader-program-name state)
   :presentation-state
   (copy-presentation-state (behavior-state-presentation-state state))))

(defun make-portable-seat-copy (policy seat)
  (multiple-value-bind (cursor-x cursor-y)
      (behavior-cursor-layout-position policy seat)
    (make-instance
     'portable-seat-state :cursor-x cursor-x :cursor-y cursor-y
     :cursor-output (behavior-cursor-output policy seat))))

(defmethod behavior-export-state
    ((policy planar-behavior-policy) compositor context)
  (declare (ignore context))
  (let ((projection-output (policy-first-output policy)))
    (make-instance
     'behavior-portable-state
     :view-states
     (mapcar
      (lambda (view)
        (let ((state (view-behavior-state view))
              (placement (view-placement view)))
          (multiple-value-bind (x y width height)
              (if projection-output
                  (behavior-project-view
                   policy projection-output view (monotonic-seconds))
                  (values (placement-x placement) (placement-y placement)
                          (placement-width placement)
                          (placement-height placement)))
            (cons view
                  (make-portable-view-copy
                   state x y width height (placement-z placement))))))
      (desktop-views (compositor-desktop compositor)))
     :output-states
     (mapcar
      (lambda (output)
        (let* ((viewport (output-behavior-state output))
               (scale (planar-viewport-scale viewport))
               (width
                 (max 1d0
                      (coerce
                       (ataxia.runtime:output-width (output-native output))
                       'double-float)))
               (height
                 (max 1d0
                      (coerce
                       (ataxia.runtime:output-height (output-native output))
                       'double-float))))
          (cons
           output
           (make-instance
            'portable-output-state
            :horizontal (/ (* (planar-viewport-camera-x viewport) scale)
                           width)
            :vertical (/ (* (planar-viewport-camera-y viewport) scale)
                         height)
            :zoom scale))))
      (compositor-outputs-list (compositor-outputs compositor)))
     :seat-states
     (mapcar
      (lambda (seat)
        (cons seat (make-portable-seat-copy policy seat)))
      (interaction-seats (compositor-interaction compositor))))))

(defmethod behavior-import-state
    ((policy planar-behavior-policy)
     (portable behavior-portable-state) context)
  (declare (ignore context))
  (let* ((output-states
           (mapcar
            (lambda (entry)
              (let* ((output (car entry))
                     (state (cdr entry))
                     (scale (max 0.05d0 (portable-output-zoom state)))
                     (width
                       (max 1d0
                            (coerce
                             (ataxia.runtime:output-width
                              (output-native output))
                             'double-float)))
                     (height
                       (max 1d0
                            (coerce
                             (ataxia.runtime:output-height
                              (output-native output))
                             'double-float))))
                (cons
                 output
                 (make-instance
                  'planar-viewport
                  :camera-x (/ (* (portable-output-horizontal state) width)
                               scale)
                  :camera-y (/ (* (portable-output-vertical state) height)
                               scale)
                  :scale scale))))
            (portable-state-output-states portable)))
         (projection-output (caar output-states))
         (viewport (and projection-output
                        (cdr (assoc projection-output output-states
                                    :test #'eq)))))
    (make-instance
     'behavior-installation
     :view-states
     (mapcar
      (lambda (entry)
        (let* ((portable-view (cdr entry))
               (scale (if viewport (planar-viewport-scale viewport) 1d0))
               (x (+ (if viewport (planar-viewport-camera-x viewport) 0d0)
                     (/ (portable-view-x portable-view) scale)))
               (y (+ (if viewport (planar-viewport-camera-y viewport) 0d0)
                     (/ (portable-view-y portable-view) scale))))
          (cons
           (car entry)
           (make-instance
            'planar-behavior-state
            :placement
            (make-instance
             'planar-placement :x x :y y
             :width (max 120d0 (/ (portable-view-width portable-view) scale))
             :height (max 80d0 (/ (portable-view-height portable-view) scale))
             :z (portable-view-depth portable-view))
            :animation-policy (portable-view-animation-policy portable-view)
            :shader-program-name
            (portable-view-shader-program-name portable-view)
            :presentation-state
            (copy-presentation-state
             (portable-view-presentation-state portable-view))))))
      (portable-state-view-states portable))
     :output-states output-states
     :seat-states
     (mapcar
      (lambda (entry)
        (let ((state (cdr entry)))
          (cons
           (car entry)
           (make-instance
            'planar-seat-state
            :cursor-x (portable-seat-cursor-x state)
            :cursor-y (portable-seat-cursor-y state)
            :cursor-output (portable-seat-cursor-output state)))))
      (portable-state-seat-states portable)))))

(defmethod behavior-place-view
    ((policy planar-behavior-policy) view (request placement-request))
  (let* ((x (or (requested-placement-x request)
                (planar-cascade-x policy)))
         (y (or (requested-placement-y request)
                (planar-cascade-y policy)))
         (width (or (requested-placement-width request) (view-width view)))
         (height (or (requested-placement-height request) (view-height view)))
         (placement
           (make-instance 'planar-placement
                          :x (coerce x 'double-float)
                          :y (coerce y 'double-float)
                          :width (coerce width 'double-float)
                          :height (coerce height 'double-float)
                          :z (incf (planar-next-z policy)))))
    (incf (planar-cascade-x policy) (planar-cascade-step policy))
    (incf (planar-cascade-y policy) (planar-cascade-step policy))
    (when (> (planar-cascade-x policy) 360d0)
      (setf (planar-cascade-x policy) 48d0
            (planar-cascade-y policy) 68d0))
    (setf (view-placement view) placement)
    placement))

(defmethod behavior-place-view
    ((policy planar-behavior-policy) view (request null))
  (behavior-place-view policy view (make-instance 'placement-request)))

(defmethod behavior-update-placement
    ((policy planar-behavior-policy) view
     (placement planar-placement) context)
  (declare (ignore policy context))
  (setf (view-placement view) placement)
  placement)

(defmethod behavior-project-view
    ((policy planar-behavior-policy) output view timestamp)
  (declare (ignore policy timestamp))
  (let* ((viewport (output-behavior-state output))
         (placement (view-placement view))
         (scale (planar-viewport-scale viewport)))
    (check-type placement planar-placement)
    (values (* (- (placement-x placement)
                  (planar-viewport-camera-x viewport)) scale)
            (* (- (placement-y placement)
                  (planar-viewport-camera-y viewport)) scale)
            (* (placement-width placement) scale)
            (* (placement-height placement) scale))))

(defmethod behavior-unproject-point
    ((policy planar-behavior-policy) output output-x output-y)
  (declare (ignore policy))
  (let ((viewport (output-behavior-state output)))
    (values (+ (planar-viewport-camera-x viewport)
               (/ output-x (planar-viewport-scale viewport)))
            (+ (planar-viewport-camera-y viewport)
               (/ output-y (planar-viewport-scale viewport))))))

(defun pan-planar-viewport (viewport delta-x delta-y)
  (incf (planar-viewport-camera-x viewport)
        (coerce delta-x 'double-float))
  (incf (planar-viewport-camera-y viewport)
        (coerce delta-y 'double-float))
  viewport)

(defun zoom-planar-viewport (viewport factor anchor-x anchor-y)
  (let* ((old-scale (planar-viewport-scale viewport))
         (new-scale (max 0.05d0 (min 32d0 (* old-scale factor))))
         (world-x (+ (planar-viewport-camera-x viewport)
                     (/ anchor-x old-scale)))
         (world-y (+ (planar-viewport-camera-y viewport)
                     (/ anchor-y old-scale))))
    (setf (planar-viewport-scale viewport) new-scale
          (planar-viewport-camera-x viewport)
          (- world-x (/ anchor-x new-scale))
          (planar-viewport-camera-y viewport)
          (- world-y (/ anchor-y new-scale))))
  viewport)
