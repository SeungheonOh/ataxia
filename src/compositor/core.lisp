;;;; Aggregate component and operation primitives.
;;;;
;;;; Components share one compositor and owner thread. Operation descriptors are
;;;; typed CLOS objects so extensions do not depend on hard-coded event keywords.

(in-package #:ataxia.compositor)

(defstruct (damage-box
             (:constructor make-damage-box (x y width height)))
  (x 0 :type integer)
  (y 0 :type integer)
  (width 0 :type integer)
  (height 0 :type integer))

(defgeneric compositor-runtime (compositor)
  (:documentation
   "Implement COMPOSITOR-RUNTIME for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric compositor-outputs (compositor)
  (:documentation
   "Implement COMPOSITOR-OUTPUTS for this output specialization. Respect output membership, layout, scale, and hotplug lifetime when updating state."))
(defgeneric compositor-surfaces (compositor)
  (:documentation
   "Implement COMPOSITOR-SURFACES for this surface specialization. Respect Wayland configure, commit, map, unmap, and destruction ordering."))
(defgeneric compositor-desktop (compositor)
  (:documentation
   "Implement COMPOSITOR-DESKTOP for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric compositor-interaction (compositor)
  (:documentation
   "Implement COMPOSITOR-INTERACTION for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric compositor-behavior-policy (compositor)
  (:documentation
   "Implement COMPOSITOR-BEHAVIOR-POLICY for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric compositor-presentation (compositor)
  (:documentation
   "Implement COMPOSITOR-PRESENTATION while preserving frame ordering and damage correctness. Never retain transient render data past the documented frame boundary."))
(defgeneric compositor-graphics (compositor)
  (:documentation
   "Implement COMPOSITOR-GRAPHICS for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric compositor-extensions (compositor)
  (:documentation
   "Implement COMPOSITOR-EXTENSIONS for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric compositor-control (compositor)
  (:documentation
   "Implement COMPOSITOR-CONTROL after validating the principal and referenced objects. Execute mutations only at an owner-thread safe point."))
(defgeneric compositor-owner-thread (compositor)
  (:documentation
   "Implement COMPOSITOR-OWNER-THREAD for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))
(defgeneric compositor-state (compositor)
  (:documentation
   "Implement COMPOSITOR-STATE for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))

(defclass compositor-component ()
  ((compositor :initarg :compositor :reader component-compositor)
   (state :initform :detached :accessor component-state))
  (:documentation
   "Represents compositor compositor component. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defgeneric attach-component (component)
  (:documentation
   "Implement ATTACH-COMPONENT on the owner thread. Establish required listeners and state before publishing the object to other components."))
(defgeneric detach-component (component reason)
  (:documentation
   "Implement DETACH-COMPONENT idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."))
(defgeneric validate-component (component compositor)
  (:documentation
   "Implement VALIDATE-COMPONENT for compositor implementations. Preserve component ownership, protocol ordering, and the generic function's return contract."))

(defmethod attach-component ((component compositor-component))
  "Implement ATTACH-COMPONENT on the owner thread. Establish required listeners and state before publishing the object to other components."
  (setf (component-state component) :attached)
  component)

(defmethod detach-component ((component compositor-component) reason)
  "Implement DETACH-COMPONENT idempotently. Release owned listeners and resources exactly once, and invalidate wrappers before native teardown."
  (declare (ignore reason))
  (setf (component-state component) :detached)
  component)

(defmethod validate-component
    ((component compositor-component) compositor)
  "Implement VALIDATE-COMPONENT for this compositor specialization. Preserve component ownership, protocol ordering, and the generic function's return contract."
  (unless (eq compositor (component-compositor component))
    (error 'compositor-error))
  component)

(defun assert-compositor-owner (compositor operation)
  #+sb-thread
  (unless (eq sb-thread:*current-thread*
              (compositor-owner-thread compositor))
    (error 'invalid-compositor-state
           :operation operation :state :wrong-owner-thread))
  compositor)

(defun monotonic-seconds ()
  (/ (get-internal-real-time)
     (coerce internal-time-units-per-second 'double-float)))

(defclass provenance ()
  ((kind :initarg :kind :reader provenance-kind)
   (identity :initarg :identity :reader provenance-identity))
  (:documentation
   "Represents compositor provenance. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defun make-local-provenance (&optional (identity :compositor))
  (make-instance 'provenance :kind :local :identity identity))

(defclass operation-descriptor ()
  ((subject :initarg :subject :reader operation-subject)
   (animation-override :initarg :animation-override :initform nil
                       :reader operation-animation-override))
  (:documentation
   "Describes operation descriptor without performing it. Hooks and policies may inspect or replace it only within the declared operation phase."))

(defclass visibility-transition (operation-descriptor)
  ((old-state :initarg :old-state :reader visibility-old-state)
   (new-state :initarg :new-state :reader visibility-new-state))
  (:documentation
   "Describes visibility transition without performing it. Hooks and policies may inspect or replace it only within the declared operation phase."))

(defclass placement-transition (operation-descriptor)
  ((old-value :initarg :old-value :reader placement-old-value)
   (new-value :initarg :new-value :reader placement-new-value))
  (:documentation
   "Describes placement transition without performing it. Hooks and policies may inspect or replace it only within the declared operation phase."))

(defclass interaction-transition (operation-descriptor)
  ((old-state :initarg :old-state :reader interaction-old-state)
   (new-state :initarg :new-state :reader interaction-new-state))
  (:documentation
   "Describes interaction transition without performing it. Hooks and policies may inspect or replace it only within the declared operation phase."))

(defclass content-transition (operation-descriptor)
  ((old-state :initarg :old-state :reader content-old-state)
   (new-state :initarg :new-state :reader content-new-state))
  (:documentation
   "Describes content transition without performing it. Hooks and policies may inspect or replace it only within the declared operation phase."))

(defclass component-replacement (operation-descriptor)
  ((role :initarg :role :reader replacement-role)
   (old-component :initarg :old-component :reader replacement-old-component)
   (new-component :initarg :new-component :reader replacement-new-component))
  (:documentation
   "Represents compositor component replacement. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defclass view-configuration-decision ()
  ((width :initarg :width :reader configuration-width)
   (height :initarg :height :reader configuration-height))
  (:documentation
   "Carries the view configuration decision result from policy code to core. Treat it as immutable and apply the decision at most once."))

(defclass pointer-button-decision ()
  ((focus-target :initarg :focus-target :initform nil
                 :reader pointer-decision-focus-target)
   (operation-kind :initarg :operation-kind :initform nil
                   :reader pointer-decision-operation-kind)
   (resize-edges :initarg :resize-edges :initform 0
                 :reader pointer-decision-resize-edges)
   (deliver-p :initarg :deliver-p :initform t
              :reader pointer-decision-deliver-p))
  (:documentation
   "Carries the pointer button decision result from policy code to core. Treat it as immutable and apply the decision at most once."))

(defclass pointer-axis-input ()
  ((time :initarg :time :reader pointer-axis-input-time)
   (orientation :initarg :orientation :reader pointer-axis-input-orientation)
   (delta :initarg :delta :reader pointer-axis-input-delta)
   (discrete-delta :initarg :discrete-delta
                   :reader pointer-axis-input-discrete-delta)
   (source :initarg :source :reader pointer-axis-input-source)
   (relative-direction :initarg :relative-direction
                       :reader pointer-axis-input-relative-direction))
  (:documentation
   "Represents compositor pointer axis input. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defclass pointer-axis-decision ()
  ((deliver-p :initarg :deliver-p :initform t
              :reader pointer-axis-decision-deliver-p))
  (:documentation
   "Carries the pointer axis decision result from policy code to core. Treat it as immutable and apply the decision at most once."))

(defclass keyboard-key-input ()
  ((time :initarg :time :reader keyboard-input-time)
   (keycode :initarg :keycode :reader keyboard-input-keycode)
   (state :initarg :state :reader keyboard-input-state)
   (depressed-modifiers :initarg :depressed-modifiers
                        :reader keyboard-input-depressed-modifiers)
   (latched-modifiers :initarg :latched-modifiers
                      :reader keyboard-input-latched-modifiers)
   (locked-modifiers :initarg :locked-modifiers
                     :reader keyboard-input-locked-modifiers)
   (layout-group :initarg :layout-group
                 :reader keyboard-input-layout-group))
  (:documentation
   "Represents compositor keyboard key input. Mutate it only on the compositor owner thread and preserve the ownership invariants exposed by its accessors."))

(defclass keyboard-key-decision ()
  ((deliver-p :initarg :deliver-p :initform t
              :reader keyboard-decision-deliver-p))
  (:documentation
   "Carries the keyboard key decision result from policy code to core. Treat it as immutable and apply the decision at most once."))

(defun apply-view-configuration-decision (view decision)
  (when decision
    (check-type decision view-configuration-decision)
    (let ((width (max 1 (round (configuration-width decision))))
          (height (max 1 (round (configuration-height decision)))))
      (setf (view-width view) width
            (view-height view) height)
      (ataxia.runtime:xdg-toplevel-set-size (view-native view) width height)))
  decision)

(defclass operation-context ()
  ((subject :initarg :subject :reader context-subject)
   (operation :initarg :operation :reader context-operation)
   (old-state :initarg :old-state :initform nil :reader context-old-state)
   (new-state :initarg :new-state :initform nil :reader context-new-state)
   (cause :initarg :cause :initform nil :reader context-cause)
   (provenance :initarg :provenance :reader context-provenance)
   (timestamp :initarg :timestamp :initform (monotonic-seconds)
              :reader context-timestamp)
   (phase :initarg :phase :reader context-phase)
   (metadata :initarg :metadata :initform nil :reader context-metadata))
  (:documentation
   "Describes operation context without performing it. Hooks and policies may inspect or replace it only within the declared operation phase."))
