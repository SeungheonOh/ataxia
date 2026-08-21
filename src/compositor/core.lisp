;;;; Aggregate component and operation primitives.
;;;;
;;;; Components share one compositor and owner thread. Operation descriptors are
;;;; typed CLOS objects so extensions do not depend on hard-coded event keywords.

(in-package #:ataxia.compositor)

(defgeneric compositor-runtime (compositor))
(defgeneric compositor-outputs (compositor))
(defgeneric compositor-surfaces (compositor))
(defgeneric compositor-desktop (compositor))
(defgeneric compositor-interaction (compositor))
(defgeneric compositor-behavior-policy (compositor))
(defgeneric compositor-presentation (compositor))
(defgeneric compositor-graphics (compositor))
(defgeneric compositor-extensions (compositor))
(defgeneric compositor-control (compositor))
(defgeneric compositor-owner-thread (compositor))
(defgeneric compositor-state (compositor))

(defclass compositor-component ()
  ((compositor :initarg :compositor :reader component-compositor)
   (state :initform :detached :accessor component-state)))

(defgeneric attach-component (component))
(defgeneric detach-component (component reason))
(defgeneric validate-component (component compositor))

(defmethod attach-component ((component compositor-component))
  (setf (component-state component) :attached)
  component)

(defmethod detach-component ((component compositor-component) reason)
  (declare (ignore reason))
  (setf (component-state component) :detached)
  component)

(defmethod validate-component
    ((component compositor-component) compositor)
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
   (identity :initarg :identity :reader provenance-identity)))

(defun make-local-provenance (&optional (identity :compositor))
  (make-instance 'provenance :kind :local :identity identity))

(defclass operation-descriptor ()
  ((subject :initarg :subject :reader operation-subject)
   (animation-override :initarg :animation-override :initform nil
                       :reader operation-animation-override)))

(defclass visibility-transition (operation-descriptor)
  ((old-state :initarg :old-state :reader visibility-old-state)
   (new-state :initarg :new-state :reader visibility-new-state)))

(defclass placement-transition (operation-descriptor)
  ((old-value :initarg :old-value :reader placement-old-value)
   (new-value :initarg :new-value :reader placement-new-value)))

(defclass interaction-transition (operation-descriptor)
  ((old-state :initarg :old-state :reader interaction-old-state)
   (new-state :initarg :new-state :reader interaction-new-state)))

(defclass content-transition (operation-descriptor)
  ((old-state :initarg :old-state :reader content-old-state)
   (new-state :initarg :new-state :reader content-new-state)))

(defclass component-replacement (operation-descriptor)
  ((role :initarg :role :reader replacement-role)
   (old-component :initarg :old-component :reader replacement-old-component)
   (new-component :initarg :new-component :reader replacement-new-component)))

(defclass view-configuration-decision ()
  ((width :initarg :width :reader configuration-width)
   (height :initarg :height :reader configuration-height)))

(defclass pointer-button-decision ()
  ((focus-target :initarg :focus-target :initform nil
                 :reader pointer-decision-focus-target)
   (operation-kind :initarg :operation-kind :initform nil
                   :reader pointer-decision-operation-kind)
   (resize-edges :initarg :resize-edges :initform 0
                 :reader pointer-decision-resize-edges)
   (deliver-p :initarg :deliver-p :initform t
              :reader pointer-decision-deliver-p)))

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
   (metadata :initarg :metadata :initform nil :reader context-metadata)))
