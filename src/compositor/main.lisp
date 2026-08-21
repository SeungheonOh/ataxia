;;;; Compositor command-line entrypoint.
;;;;
;;;; The launcher selects Runtime bootstrap options, starts the aggregate, and
;;;; optionally spawns Wayland clients after the compositor socket is live.

(in-package #:ataxia.compositor)

(defun compositor-usage (stream)
  (format stream
          "Usage: run-compositor [options]~%\
~%\
Options:~%\
  --backend auto|headless  Select the wlroots backend (default: auto)~%\
  --width PIXELS          Headless output width (default: 1280)~%\
  --height PIXELS         Headless output height (default: 720)~%\
  --run-for SECONDS       Stop after the given duration~%\
  --launch PROGRAM        Launch a program after startup (repeatable)~%\
  --no-socket             Do not publish a Wayland socket~%\
  --debug                 Enable wlroots debug logging~%\
  --help                  Show this help~%"))

(defun require-option-value (arguments option)
  (unless arguments
    (error 'invalid-compositor-state
           :operation :command-line :state (list :missing option)))
  (values (first arguments) (rest arguments)))

(defun parse-positive-integer (text option)
  (handler-case
      (let ((value (parse-integer text :junk-allowed nil)))
        (unless (plusp value)
          (error 'invalid-compositor-state
                 :operation option :state text))
        value)
    (parse-error ()
      (error 'invalid-compositor-state :operation option :state text))))

(defun parse-positive-real (text option)
  (let ((*read-eval* nil))
    (multiple-value-bind (value position)
        (read-from-string text nil nil)
      (unless (and (realp value) (plusp value)
                   (= position (length text)))
        (error 'invalid-compositor-state :operation option :state text))
      value)))

(defun parse-compositor-command-line (arguments)
  (let ((backend :auto)
        (width 1280)
        (height 720)
        (run-for nil)
        (socket-p t)
        (debug-p nil)
        (launch nil)
        (help-p nil))
    (loop while arguments
          for option = (pop arguments)
          do (cond
               ((string= option "--backend")
                (multiple-value-bind (value remaining)
                    (require-option-value arguments option)
                  (setf backend
                        (cond ((string= value "auto") :auto)
                              ((string= value "headless") :headless)
                              (t (error 'invalid-compositor-state
                                        :operation :backend :state value)))
                        arguments remaining)))
               ((string= option "--width")
                (multiple-value-bind (value remaining)
                    (require-option-value arguments option)
                  (setf width (parse-positive-integer value :width)
                        arguments remaining)))
               ((string= option "--height")
                (multiple-value-bind (value remaining)
                    (require-option-value arguments option)
                  (setf height (parse-positive-integer value :height)
                        arguments remaining)))
               ((string= option "--run-for")
                (multiple-value-bind (value remaining)
                    (require-option-value arguments option)
                  (setf run-for (parse-positive-real value :run-for)
                        arguments remaining)))
               ((string= option "--launch")
                (multiple-value-bind (value remaining)
                    (require-option-value arguments option)
                  (setf launch (append launch (list value))
                        arguments remaining)))
               ((string= option "--no-socket") (setf socket-p nil))
               ((string= option "--debug") (setf debug-p t))
               ((string= option "--help") (setf help-p t))
               (t
                (error 'invalid-compositor-state
                       :operation :command-line :state option))))
    (list :backend backend :headless-width width :headless-height height
          :run-for run-for :socket-p socket-p :debug-p debug-p
          :launch launch :help-p help-p)))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  (handler-case
      (let* ((options (parse-compositor-command-line arguments))
             (help-p (getf options :help-p))
             (run-for (getf options :run-for))
             (applications (getf options :launch)))
        (when help-p
          (compositor-usage *standard-output*)
          (return-from main 0))
        (remf options :help-p)
        (remf options :run-for)
        (remf options :launch)
        (let ((compositor (apply #'create-compositor options)))
          (unwind-protect
               (progn
                 (start-compositor compositor)
                 (format *standard-output* "[compositor] WAYLAND_DISPLAY=~A~%"
                         (or (ataxia.runtime:runtime-socket-name
                              (compositor-runtime compositor))
                             "unpublished"))
                 (finish-output *standard-output*)
                 (dolist (application applications)
                   (launch-application compositor application))
                 (run-compositor compositor :run-for run-for)
                 0)
            (destroy-compositor compositor))))
    (serious-condition (condition)
      (format *error-output* "[compositor] fatal: ~A~%" condition)
      (finish-output *error-output*)
      1)))
