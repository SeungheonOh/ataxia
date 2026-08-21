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
                    :reader presentation-shader-uniforms))
  (:documentation
   "Stores presentation state. Only the owning subsystem or active behavior policy may mutate it, and replacement must copy or migrate mutable members."))

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
                       :reader behavior-state-presentation-state))
  (:documentation
   "Stores behavior view state. Only the owning subsystem or active behavior policy may mutate it, and replacement must copy or migrate mutable members."))

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
   (revision :initform 0 :accessor behavior-policy-revision))
  (:documentation
   "Defines the replaceable behavior policy. It owns policy-specific state and must satisfy compositor generics without mutating Runtime objects directly."))

(defclass behavior-placement () ()
  (:documentation
   "Represents compositor behavior placement. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defclass placement-request ()
  ((x :initarg :x :initform nil :reader requested-placement-x)
   (y :initarg :y :initform nil :reader requested-placement-y)
   (width :initarg :width :initform nil :reader requested-placement-width)
   (height :initarg :height :initform nil :reader requested-placement-height))
  (:documentation
   "Represents compositor placement request. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defclass behavior-portable-state ()
  ((source-policy :initarg :source-policy
                  :reader portable-state-source-policy)
   (view-states :initarg :view-states
                :reader portable-state-view-states)
   (output-states :initarg :output-states
                  :reader portable-state-output-states))
  (:documentation
   "Stores behavior portable state. Only the owning subsystem or active behavior policy may mutate it, and replacement must copy or migrate mutable members."))

(defclass behavior-installation ()
  ((view-states :initarg :view-states
                :reader installation-view-states)
   (output-states :initarg :output-states
                  :reader installation-output-states))
  (:documentation
   "Represents compositor behavior installation. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defgeneric activate-behavior-policy (policy)
  (:documentation
   "Implement ACTIVATE-BEHAVIOR-POLICY on the owner thread. Establish required listeners and state before publishing the object to other components."))
(defgeneric quiesce-behavior-policy (policy reason)
  (:documentation
   "Implement QUIESCE-BEHAVIOR-POLICY for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric behavior-view-created (policy view)
  (:documentation
   "Implement BEHAVIOR-VIEW-CREATED for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-view-committed (policy view commit initial-commit-p)
  (:documentation
   "Implement BEHAVIOR-VIEW-COMMITTED for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-view-mapped (policy view)
  (:documentation
   "Implement BEHAVIOR-VIEW-MAPPED for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-view-unmapped (policy view)
  (:documentation
   "Implement BEHAVIOR-VIEW-UNMAPPED for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-view-destroying (policy view)
  (:documentation
   "Implement BEHAVIOR-VIEW-DESTROYING for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-view-identity-changed (policy view kind value)
  (:documentation
   "Implement BEHAVIOR-VIEW-IDENTITY-CHANGED for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-output-added (policy output)
  (:documentation
   "Implement BEHAVIOR-OUTPUT-ADDED for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-output-removing (policy output)
  (:documentation
   "Implement BEHAVIOR-OUTPUT-REMOVING for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-recommend-initial-size (policy compositor view)
  (:documentation
   "Implement BEHAVIOR-RECOMMEND-INITIAL-SIZE for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-set-view-size (policy view width height context)
  (:documentation
   "Implement BEHAVIOR-SET-VIEW-SIZE for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-place-view (policy view placement-request)
  (:documentation
   "Implement BEHAVIOR-PLACE-VIEW for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-update-placement (policy view placement context)
  (:documentation
   "Implement BEHAVIOR-UPDATE-PLACEMENT for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-project-view (policy output viewport view timestamp)
  (:documentation
   "Implement BEHAVIOR-PROJECT-VIEW for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-unproject-point
    (policy output viewport output-x output-y)
  (:documentation
   "Implement BEHAVIOR-UNPROJECT-POINT for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric copy-behavior-placement (policy placement)
  (:documentation
   "Implement COPY-BEHAVIOR-PLACEMENT by returning an independent copy. Do not share mutable policy, presentation, or lifecycle state with the source."))
(defgeneric copy-behavior-view-state (policy state)
  (:documentation
   "Implement COPY-BEHAVIOR-VIEW-STATE by returning an independent copy. Do not share mutable policy, presentation, or lifecycle state with the source."))
(defgeneric copy-behavior-output-state (policy state)
  (:documentation
   "Implement COPY-BEHAVIOR-OUTPUT-STATE by returning an independent copy. Do not share mutable policy, presentation, or lifecycle state with the source."))
(defgeneric migrate-behavior-view-state
    (old-policy new-policy view state)
  (:documentation
   "Implement MIGRATE-BEHAVIOR-VIEW-STATE without mutating the source. Reject unsupported state before installation so policy replacement can roll back atomically."))
(defgeneric migrate-behavior-output-state
    (old-policy new-policy output state)
  (:documentation
   "Implement MIGRATE-BEHAVIOR-OUTPUT-STATE without mutating the source. Reject unsupported state before installation so policy replacement can roll back atomically."))
(defgeneric behavior-export-state (policy compositor context)
  (:documentation
   "Implement BEHAVIOR-EXPORT-STATE for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-import-state (policy portable-state context)
  (:documentation
   "Implement BEHAVIOR-IMPORT-STATE for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-build-scene
    (policy presentation output timestamp)
  (:documentation
   "Implement BEHAVIOR-BUILD-SCENE for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-compose-frame
    (policy presentation output snapshot timestamp)
  (:documentation
   "Implement BEHAVIOR-COMPOSE-FRAME for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-build-view-items
    (policy items output view timestamp titlebar-height)
  (:documentation
   "Implement BEHAVIOR-BUILD-VIEW-ITEMS for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-build-popup-items
    (policy items desktop output timestamp)
  (:documentation
   "Implement BEHAVIOR-BUILD-POPUP-ITEMS for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-begin-operation
    (policy interaction seat view kind edges button)
  (:documentation
   "Implement BEHAVIOR-BEGIN-OPERATION for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-update-operation (policy interaction operation)
  (:documentation
   "Implement BEHAVIOR-UPDATE-OPERATION for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-configure-view-for-output
    (policy compositor view output fullscreen-p)
  (:documentation
   "Implement BEHAVIOR-CONFIGURE-VIEW-FOR-OUTPUT for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-restore-view (policy compositor view)
  (:documentation
   "Implement BEHAVIOR-RESTORE-VIEW for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-pan-output (policy output delta-x delta-y)
  (:documentation
   "Implement BEHAVIOR-PAN-OUTPUT for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-zoom-output
    (policy output factor anchor-x anchor-y)
  (:documentation
   "Implement BEHAVIOR-ZOOM-OUTPUT for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-move-view (policy view x y context)
  (:documentation
   "Implement BEHAVIOR-MOVE-VIEW for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-focus-changed (policy seat previous view)
  (:documentation
   "Implement BEHAVIOR-FOCUS-CHANGED for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-handle-pointer-button
    (policy interaction seat hit button state time)
  (:documentation
   "Implement BEHAVIOR-HANDLE-POINTER-BUTTON for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-handle-pointer-axis
    (policy interaction seat input)
  (:documentation
   "Implement BEHAVIOR-HANDLE-POINTER-AXIS for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-handle-keyboard-key
    (policy interaction seat input)
  (:documentation
   "Implement BEHAVIOR-HANDLE-KEYBOARD-KEY for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-observe-output (policy output)
  (:documentation
   "Implement BEHAVIOR-OBSERVE-OUTPUT for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-observe-view (policy view)
  (:documentation
   "Implement BEHAVIOR-OBSERVE-VIEW for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-resolve-animation
    (policy engine subject descriptor context)
  (:documentation
   "Implement BEHAVIOR-RESOLVE-ANIMATION for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-set-view-animation-definition
    (policy view descriptor-class definition)
  (:documentation
   "Implement BEHAVIOR-SET-VIEW-ANIMATION-DEFINITION for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
(defgeneric behavior-validate-resources
    (policy compositor snapshots context)
  (:documentation
   "Implement BEHAVIOR-VALIDATE-RESOURCES for behavior policies. Mutate only behavior-owned state and return a value the compositor can validate and apply synchronously."))
