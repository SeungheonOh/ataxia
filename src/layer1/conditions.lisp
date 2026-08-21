;;;; Layer 1 conditions.
;;;;
;;;; These conditions preserve the exact failing native operation, wrapper, or
;;;; callback signal without introducing a generic command/error envelope.

(in-package #:ataxia.layer1)

(define-condition layer1-error (error) ())

(define-condition native-call-failed (layer1-error)
  ((name :initarg :name :reader native-call-name)
   (detail :initarg :detail :reader native-call-detail))
  (:report
   (lambda (condition stream)
     (format stream "Native operation ~A failed~@[ (~A)~]"
             (native-call-name condition)
             (native-call-detail condition)))))

(define-condition native-abi-mismatch (layer1-error)
  ((expected :initarg :expected :reader native-abi-expected)
   (actual :initarg :actual :reader native-abi-actual)
   (subject :initarg :subject :reader native-abi-subject))
  (:report
   (lambda (condition stream)
     (format stream "Native ABI mismatch for ~A: expected ~A, got ~A"
             (native-abi-subject condition)
             (native-abi-expected condition)
             (native-abi-actual condition)))))

(define-condition dead-native-object (layer1-error)
  ((object :initarg :object :reader dead-native-object-value))
  (:report
   (lambda (condition stream)
     (format stream "Native ~A wrapper is no longer live"
             (class-name (class-of (dead-native-object-value condition)))))))

(define-condition wrong-owner-thread (layer1-error)
  ((operation :initarg :operation :reader wrong-owner-operation))
  (:report
   (lambda (condition stream)
     (format stream "~A must execute on the Layer 1 owner thread"
             (wrong-owner-operation condition)))))

(define-condition callback-fault (layer1-error)
  ((signal :initarg :signal :reader callback-fault-signal)
   (cause :initarg :cause :reader callback-fault-cause))
  (:report
   (lambda (condition stream)
     (format stream "Layer 1 callback ~A failed: ~A"
             (callback-fault-signal condition)
             (callback-fault-cause condition)))))
