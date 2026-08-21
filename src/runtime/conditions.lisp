;;;; Runtime conditions.
;;;;
;;;; These conditions preserve the exact failing native operation, wrapper, or
;;;; callback signal without introducing a generic command/error envelope.

(in-package #:ataxia.runtime)

(define-condition runtime-error (error) ()
  (:documentation
   "Signals runtime error. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))

(define-condition native-call-failed (runtime-error)
  ((name :initarg :name :reader native-call-name)
   (detail :initarg :detail :reader native-call-detail))
  (:report
   (lambda (condition stream)
     (format stream "Native operation ~A failed~@[ (~A)~]"
             (native-call-name condition)
             (native-call-detail condition))))
  (:documentation
   "Signals native call failed. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))

(define-condition native-abi-mismatch (runtime-error)
  ((expected :initarg :expected :reader native-abi-expected)
   (actual :initarg :actual :reader native-abi-actual)
   (subject :initarg :subject :reader native-abi-subject))
  (:report
   (lambda (condition stream)
     (format stream "Native ABI mismatch for ~A: expected ~A, got ~A"
             (native-abi-subject condition)
             (native-abi-expected condition)
             (native-abi-actual condition))))
  (:documentation
   "Signals native abi mismatch. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))

(define-condition dead-native-object (runtime-error)
  ((object :initarg :object :reader dead-native-object-value))
  (:report
   (lambda (condition stream)
     (format stream "Native ~A wrapper is no longer live"
             (class-name (class-of (dead-native-object-value condition))))))
  (:documentation
   "Signals dead native object. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))

(define-condition wrong-owner-thread (runtime-error)
  ((operation :initarg :operation :reader wrong-owner-operation))
  (:report
   (lambda (condition stream)
     (format stream "~A must execute on the Runtime owner thread"
             (wrong-owner-operation condition))))
  (:documentation
   "Signals wrong owner thread. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))

(define-condition callback-fault (runtime-error)
  ((signal :initarg :signal :reader callback-fault-signal)
   (cause :initarg :cause :reader callback-fault-cause))
  (:report
   (lambda (condition stream)
     (format stream "Runtime callback ~A failed: ~A"
             (callback-fault-signal condition)
             (callback-fault-cause condition))))
  (:documentation
   "Signals callback fault. Signalers must include enough context for callers to reject, unwind, or roll back the failed operation safely."))
