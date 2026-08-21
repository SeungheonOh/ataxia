;;;; Compositor conditions.
;;;;
;;;; Conditions describe policy, hook, control, and graphics failures without
;;;; leaking foreign pointers or Runtime implementation details.

(in-package #:ataxia.compositor)

(define-condition compositor-error (error) ()
  (:documentation
   "Signals compositor error. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))

(define-condition invalid-compositor-state (compositor-error)
  ((operation :initarg :operation :reader invalid-state-operation)
   (state :initarg :state :reader invalid-state-value))
  (:report
   (lambda (condition stream)
     (format stream "Compositor operation ~A is invalid in state ~A"
             (invalid-state-operation condition)
             (invalid-state-value condition))))
  (:documentation
   "Signals invalid compositor state. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))

(define-condition hook-vetoed (compositor-error)
  ((hook :initarg :hook :reader vetoed-hook)
   (handler :initarg :handler :reader vetoing-handler))
  (:report
   (lambda (condition stream)
     (format stream "Hook ~A was vetoed by ~A"
             (vetoed-hook condition) (vetoing-handler condition))))
  (:documentation
   "Signals hook vetoed. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))

(define-condition control-request-rejected (compositor-error)
  ((action :initarg :action :reader rejected-action)
   (reason :initarg :reason :reader rejection-reason))
  (:report
   (lambda (condition stream)
     (format stream "Control action ~A was rejected: ~A"
             (rejected-action condition) (rejection-reason condition))))
  (:documentation
   "Signals control request rejected. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))

(define-condition graphics-failure (compositor-error)
  ((operation :initarg :operation :reader graphics-operation)
   (detail :initarg :detail :initform nil :reader graphics-detail))
  (:report
   (lambda (condition stream)
     (format stream "Graphics operation ~A failed~@[ (~A)~]"
             (graphics-operation condition) (graphics-detail condition))))
  (:documentation
   "Signals graphics failure. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))
