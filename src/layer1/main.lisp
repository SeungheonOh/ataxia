;;;; Layer 1 command-line entrypoint.
;;;;
;;;; This module parses only runtime bootstrap options, starts the Lisp-owned
;;;; event loop, and reports native failures without embedding compositor policy.

(in-package #:ataxia.layer1)

(defun %usage (stream)
  (format stream
          "Usage: run-layer1 [options]~%\
~%\
Options:~%\
  --backend auto|headless  Select the wlroots backend (default: auto)~%\
  --width PIXELS          Headless output width (default: 1280)~%\
  --height PIXELS         Headless output height (default: 720)~%\
  --run-for SECONDS       Stop after the given duration~%\
  --no-socket             Do not publish a Wayland socket~%\
  --debug                 Enable wlroots debug logging~%\
  --help                  Show this help~%"))

(defun %option-value (arguments option)
  (unless arguments
    (error 'native-call-failed :name :command-line :detail option))
  (values (first arguments) (rest arguments)))

(defun %parse-positive-integer (text option)
  (handler-case
      (let ((value (parse-integer text :junk-allowed nil)))
        (unless (plusp value)
          (error 'native-call-failed :name option :detail text))
        value)
    (parse-error ()
      (error 'native-call-failed :name option :detail text))))

(defun %parse-positive-real (text option)
  (handler-case
      (let ((*read-eval* nil))
        (multiple-value-bind (value position)
            (read-from-string text nil nil)
          (unless (and (realp value)
                       (plusp value)
                       (= position (length text)))
            (error 'native-call-failed :name option :detail text))
          value))
    (reader-error ()
      (error 'native-call-failed :name option :detail text))))

(defun %parse-backend (text)
  (cond
    ((string= text "auto") :auto)
    ((string= text "headless") :headless)
    (t (error 'native-call-failed :name :backend :detail text))))

(defun %parse-command-line (arguments)
  (let ((backend :auto)
        (width 1280)
        (height 720)
        (run-for nil)
        (socket-p t)
        (debug-p nil)
        (help-p nil))
    (loop while arguments
          for option = (pop arguments)
          do (cond
               ((string= option "--backend")
                (multiple-value-bind (value remaining)
                    (%option-value arguments option)
                  (setf backend (%parse-backend value)
                        arguments remaining)))
               ((string= option "--width")
                (multiple-value-bind (value remaining)
                    (%option-value arguments option)
                  (setf width (%parse-positive-integer value :width)
                        arguments remaining)))
               ((string= option "--height")
                (multiple-value-bind (value remaining)
                    (%option-value arguments option)
                  (setf height (%parse-positive-integer value :height)
                        arguments remaining)))
               ((string= option "--run-for")
                (multiple-value-bind (value remaining)
                    (%option-value arguments option)
                  (setf run-for (%parse-positive-real value :run-for)
                        arguments remaining)))
               ((string= option "--no-socket")
                (setf socket-p nil))
               ((string= option "--debug")
                (setf debug-p t))
               ((string= option "--help")
                (setf help-p t))
               (t
                (error 'native-call-failed
                       :name :command-line :detail option))))
    (list :backend backend
          :headless-width width
          :headless-height height
          :run-for run-for
          :socket-p socket-p
          :debug-p debug-p
          :help-p help-p)))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  (handler-case
      (let* ((options (%parse-command-line arguments))
             (help-p (getf options :help-p))
             (run-for (getf options :run-for)))
        (when help-p
          (%usage *standard-output*)
          (return-from main 0))
        (remf options :help-p)
        (remf options :run-for)
        (let ((runtime (apply #'create-layer1-runtime options)))
          (unwind-protect
               (progn
                 (call-with-egl-context
                  (runtime-egl runtime) (lambda () nil))
                 (create-xdg-shell runtime)
                 (create-data-device-manager runtime)
                 (let ((seat (create-seat runtime "seat0")))
                   (set-seat-capabilities seat 0))
                 (start-layer1-runtime runtime)
                 (run-layer1-runtime runtime :run-for run-for)
                 0)
            (destroy-layer1-runtime runtime))))
    (serious-condition (cause)
      (format *error-output* "[layer1] fatal: ~A~%" cause)
      (finish-output *error-output*)
      1)))
