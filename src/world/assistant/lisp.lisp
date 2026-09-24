;;;; Direct World inspection, control and live development through the owner queue.
(in-package #:ataxia.assistant)

(defclass assistant-output (sb-gray:fundamental-character-output-stream)
  ((text :initform (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)
         :reader assistant-output-text)
   (truncated :initform nil :accessor assistant-output-truncated)))
(defmethod sb-gray:stream-write-char ((stream assistant-output) character)
  (if (< (length (assistant-output-text stream)) 16384)
      (vector-push-extend character (assistant-output-text stream))
      (setf (assistant-output-truncated stream) t))
  character)
(defmethod sb-gray:stream-line-column ((stream assistant-output))
  (let* ((text (assistant-output-text stream)) (newline (position #\Newline text :from-end t)))
    (- (length text) (if newline (1+ newline) 0))))

(defun %assistant-evaluate-lisp (controller arguments)
  ;; The dispatcher checks the task before compilation; check again on the
  ;; owner before executing a prepared form in case the user paused meanwhile.
  (let* ((code (cu:bounded-string (gethash "code" arguments) 32768 "code"))
         (mode (gethash "mode" arguments))
         (*package* (find-package :cl-user))
         (*read-eval* nil)
         (*default-pathname-defaults* (pathname (assistant-controller-project controller)))
         (output (make-instance 'assistant-output))
         (*standard-input* (make-string-input-stream ""))
         (*standard-output* output) (*error-output* output) (*trace-output* output)
         (*query-io* (make-two-way-stream *standard-input* output))
         (*print-length* 64) (*print-level* 8) (*print-circle* t)
         (*print-pretty* nil))
    (unless (member mode '("inspect" "apply" "worker") :test #'equal)
      (error "Lisp mode must be inspect, apply, or worker."))
    (sb-ext:with-timeout 30d0
      (let* ((eof (gensym))
             (form (with-input-from-string (input code)
                     (let ((form (read input nil eof)))
                       (when (eq form eof) (error "Enter one Lisp form."))
                       (unless (eq eof (read input nil eof)) (error "Use PROGN for multiple Lisp forms."))
                       form)))
             ;; WORLD is lexical and supplied only for short owner-thread work.
             (function (compile nil `(lambda (cl-user::world)
                                       (declare (ignorable cl-user::world)) ,form)))
             (result
               (if (equal mode "worker")
                   (multiple-value-list (funcall function nil))
                   (%assistant-owner controller
                     (lambda ()
                       (%assistant-require-task controller)
                       ;; Catch inside the owner request, including timeout. Lisp
                       ;; mistakes must not trigger World replacement/recovery.
                       (handler-case
                           (let* ((*standard-input* (make-string-input-stream ""))
                                  (*standard-output* output) (*error-output* output) (*trace-output* output)
                                  (*query-io* (make-two-way-stream *standard-input* output))
                                 (*print-length* 64) (*print-level* 8) (*print-circle* t) (*print-pretty* nil))
                            (sb-ext:with-timeout .25d0
                             (let ((values (multiple-value-list
                                            (funcall function (assistant-controller-world controller)))))
                               (when (equal mode "apply")
                                 (refresh-world (assistant-controller-world controller)))
                               ;; Print while the owner still holds the objects.
                               ;; Never traverse mutable World values on the worker.
                               (dolist (value values) (write value :stream output) (terpri output))
                               nil)))
                         (serious-condition (cause) (list :error (princ-to-string cause)))))))))
        (unless (equal mode "worker")
          (when (getf result :error) (error "~A" (getf result :error)))
          (setf result nil))
        (dolist (value result) (write value :stream output) (terpri output))
        (list :ok t :output (copy-seq (assistant-output-text output))
              :truncated (if (assistant-output-truncated output) t :false))))))
