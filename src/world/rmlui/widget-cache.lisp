;;;; Avoid rebuilding unchanged native UI properties.
(in-package #:ataxia.world.rmlui)

(defclass rmlui-widget (agent-widget)
  ((cache :initform (make-hash-table :test #'equal) :reader widget-cache)))

(defun cache-widget-value (widget key value function)
  "Apply VALUE through FUNCTION only when KEY's cached value changes."
  (unless (equal (gethash key (widget-cache widget) :absent) value)
    (funcall function (overlay-component widget))
    (setf (gethash key (widget-cache widget)) value)))

(defun set-widget-text (widget id value)
  (cache-widget-value
   widget id value
   (lambda (component) (set-rmlui-property component id value))))

(defun set-widget-style (widget id property value)
  (cache-widget-value
   widget (list id property) value
   (lambda (component) (set-rmlui-style component id property value))))

(defun short-ui-text (text limit)
  (if (> (length text) limit)
      (concatenate 'string (subseq text 0 (1- limit)) "…")
      text))
