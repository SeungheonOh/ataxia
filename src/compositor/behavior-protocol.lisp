;;;; Compositor-facing behavior policy protocol.
;;;;
;;;; This module defines the typed contract through which the compositor
;;;; invokes replaceable behavior policies. Concrete behavior stays under
;;;; src/behavior.

(in-package #:ataxia.compositor)

(defclass presentation-state ()
  ((opacity :initform 1d0 :accessor presentation-opacity)
   (scale :initform 1d0 :accessor presentation-scale)
   (offset-x :initform 0d0 :accessor presentation-offset-x)
   (offset-y :initform 0d0 :accessor presentation-offset-y)
   (effect-parameters :initform (make-hash-table :test #'equal)
                      :reader presentation-effect-parameters)
   (shader-uniforms :initform (make-hash-table :test #'equal)
                    :reader presentation-shader-uniforms)))

(defclass behavior-view-state ()
  ((placement :initarg :placement :initform nil
              :accessor behavior-state-placement)
   (restore-state :initarg :restore-state :initform nil
                  :accessor behavior-state-restore-state)
   (animation-policy :initarg :animation-policy :initform nil
                     :accessor behavior-state-animation-policy)
   (shader-program-name :initarg :shader-program-name :initform nil
                        :accessor behavior-state-shader-program-name)
   (presentation-state :initarg :presentation-state
                       :initform (make-instance 'presentation-state)
                       :reader behavior-state-presentation-state)))

(defun view-placement (view)
  (behavior-state-placement (view-behavior-state view)))

(defun (setf view-placement) (placement view)
  (setf (behavior-state-placement (view-behavior-state view)) placement))

(defun view-restore-placement (view)
  (behavior-state-restore-state (view-behavior-state view)))

(defun (setf view-restore-placement) (state view)
  (setf (behavior-state-restore-state (view-behavior-state view)) state))

(defun view-animation-policy (view)
  (behavior-state-animation-policy (view-behavior-state view)))

(defun (setf view-animation-policy) (policy view)
  (setf (behavior-state-animation-policy (view-behavior-state view)) policy))

(defun view-shader-program-name (view)
  (behavior-state-shader-program-name (view-behavior-state view)))

(defun (setf view-shader-program-name) (name view)
  (setf (behavior-state-shader-program-name (view-behavior-state view)) name))

(defun view-presentation-state (view)
  (behavior-state-presentation-state (view-behavior-state view)))

(defclass behavior-policy (compositor-component)
  ((active-p :initform nil :accessor behavior-policy-active-p)
   (revision :initform 0 :accessor behavior-policy-revision)))

(defclass behavior-placement () ())

(defclass placement-request ()
  ((x :initarg :x :initform nil :reader requested-placement-x)
   (y :initarg :y :initform nil :reader requested-placement-y)
   (width :initarg :width :initform nil :reader requested-placement-width)
   (height :initarg :height :initform nil :reader requested-placement-height)))

(defclass behavior-portable-state ()
  ((view-states :initarg :view-states
                :reader portable-state-view-states)
   (output-states :initarg :output-states
                  :reader portable-state-output-states)
   (seat-states :initarg :seat-states
                :reader portable-state-seat-states)))

(defclass portable-view-state ()
  ((x :initarg :x :reader portable-view-x)
   (y :initarg :y :reader portable-view-y)
   (width :initarg :width :reader portable-view-width)
   (height :initarg :height :reader portable-view-height)
   (depth :initarg :depth :initform 0d0 :reader portable-view-depth)
   (animation-policy :initarg :animation-policy :initform nil
                     :reader portable-view-animation-policy)
   (shader-program-name :initarg :shader-program-name :initform nil
                        :reader portable-view-shader-program-name)
   (presentation-state :initarg :presentation-state
                       :reader portable-view-presentation-state)))

(defclass portable-output-state ()
  ((horizontal :initarg :horizontal :reader portable-output-horizontal)
   (vertical :initarg :vertical :reader portable-output-vertical)
   (zoom :initarg :zoom :reader portable-output-zoom)))

(defclass portable-seat-state ()
  ((cursor-x :initarg :cursor-x :reader portable-seat-cursor-x)
   (cursor-y :initarg :cursor-y :reader portable-seat-cursor-y)
   (cursor-output :initarg :cursor-output :initform nil
                  :reader portable-seat-cursor-output)))

(defclass behavior-installation ()
  ((view-states :initarg :view-states
                :reader installation-view-states)
   (output-states :initarg :output-states
                  :reader installation-output-states)
   (seat-states :initarg :seat-states
                :reader installation-seat-states)))

(defgeneric schedule-presentation (presentation &optional output damage))

(defgeneric activate-behavior-policy (policy))
(defgeneric quiesce-behavior-policy (policy reason))
(defgeneric behavior-view-created (policy view))
(defgeneric behavior-view-committed (policy view commit initial-commit-p))
(defgeneric behavior-view-mapped (policy view))
(defgeneric behavior-view-unmapped (policy view))
(defgeneric behavior-view-destroying (policy view))
(defgeneric behavior-view-identity-changed (policy view kind value))
(defgeneric behavior-output-added (policy output))
(defgeneric behavior-output-removing (policy output))
(defgeneric behavior-outputs-changed (policy interaction))
(defgeneric behavior-seat-created
    (policy interaction seat pointer-x pointer-y))
(defgeneric behavior-seat-destroying (policy interaction seat))
(defgeneric behavior-seat-state (policy seat))
(defgeneric behavior-install-seat-state (policy seat state))
(defgeneric copy-behavior-seat-state (policy state))
(defgeneric behavior-cursor-layout-position (policy seat))
(defgeneric behavior-cursor-output (policy seat))
(defgeneric behavior-cursor-local-position
    (policy seat &optional output))
(defgeneric behavior-cursor-damage-box
    (policy seat output pointer-x pointer-y))
(defgeneric behavior-cursor-content-changed
    (policy interaction seat old-output old-box))
(defgeneric behavior-warp-cursor
    (policy interaction seat pointer-x pointer-y time-msec))
(defgeneric behavior-operation (policy seat))
(defgeneric behavior-request-move
    (policy interaction seat view &key serial button))
(defgeneric behavior-request-resize
    (policy interaction seat view edges &key serial button))
(defgeneric behavior-cancel-operation (policy interaction seat))
(defgeneric behavior-cancel-view-operations
    (policy interaction view))
(defgeneric behavior-recommend-initial-size (policy compositor view))
(defgeneric behavior-set-view-size (policy view width height context))
(defgeneric behavior-place-view (policy view placement-request))
(defgeneric behavior-update-placement (policy view placement context))
(defgeneric behavior-project-view (policy output view timestamp))
(defgeneric behavior-unproject-point (policy output output-x output-y))
(defgeneric copy-behavior-placement (policy placement))
(defgeneric copy-behavior-view-state (policy state))
(defgeneric copy-behavior-output-state (policy state))
(defgeneric behavior-export-state (policy compositor context))
(defgeneric behavior-import-state (policy portable-state context))
(defgeneric behavior-build-scene
    (policy presentation output timestamp))
(defgeneric behavior-compose-frame
    (policy presentation output snapshot timestamp))
(defgeneric behavior-build-view-items
    (policy items output view timestamp titlebar-height))
(defgeneric behavior-build-popup-items
    (policy items desktop output timestamp))
(defgeneric behavior-configure-view-for-output
    (policy compositor view output fullscreen-p))
(defgeneric behavior-restore-view (policy compositor view))
(defgeneric behavior-move-view (policy view x y context))
(defgeneric behavior-focus-changed (policy seat previous view))
(defgeneric behavior-handle-pointer-button
    (policy interaction seat hit button state time))
(defgeneric behavior-handle-pointer-motion
    (policy interaction seat event))
(defgeneric behavior-handle-pointer-motion-absolute
    (policy interaction seat event))
(defgeneric behavior-handle-pointer-axis
    (policy interaction seat input))
(defgeneric behavior-handle-keyboard-key
    (policy interaction seat input))
(defgeneric behavior-observe-output (policy output))
(defgeneric behavior-observe-view (policy view))
(defgeneric behavior-resolve-animation
    (policy engine subject descriptor context))
(defgeneric behavior-apply-animation-value
    (policy subject binding value instance))
(defgeneric behavior-finalize-animation-binding
    (policy subject binding instance reason))
(defgeneric behavior-prepare-animation-binding
    (policy subject binding instance))
(defgeneric behavior-set-view-animation-definition
    (policy view descriptor-class definition))
(defgeneric behavior-decode-control-action
    (policy control principal specification))
(defgeneric behavior-execute-control-action (policy control action))
(defgeneric behavior-validate-resources
    (policy compositor snapshots context))
