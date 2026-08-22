;;;; Infinite canvas compositor entrypoint.

(in-package #:ataxia.infinite-world)

(defun run-infinite-compositor
    (&key (backend :auto) (width 1280) (height 720) run-for debug-p
          (sly-port 4005))
  (let ((control nil)
        (kernel
          (ataxia.kernel:create-kernel
           (make-infinite-world)
           :backend backend
           :headless-width width
           :headless-height height
           :debug-p debug-p)))
    (unwind-protect
         (progn
           (ataxia.kernel:start-kernel kernel)
           (when sly-port
             (setf control
                   (ataxia.sly-control:start-sly-control
                    kernel :port sly-port)))
           (format t "[infinite-world] WAYLAND_DISPLAY=~A~%"
                   (ataxia.runtime:runtime-socket-name
                    (ataxia.kernel:kernel-runtime kernel)))
           (when control
             (format t "[infinite-world] SLYNK=localhost:~D~%"
                     (ataxia.sly-control:sly-control-port control)))
           (finish-output)
           (ataxia.kernel:run-kernel kernel :run-for run-for)
           0)
      (when control
        (ataxia.sly-control:stop-sly-control control))
      (ataxia.kernel:destroy-kernel kernel :infinite-world-exit))))

(defun %number-option (text integer-p name)
  (let ((*read-eval* nil))
    (multiple-value-bind (value consumed) (read-from-string text nil nil)
      (unless (and value (= consumed (length text)) (plusp value)
                   (if integer-p (integerp value) (realp value)))
        (error "Invalid ~A value: ~A" name text))
      value)))

(defun %parse-main-options (arguments)
  (let ((options (list :backend :auto :width 1280 :height 720
                       :run-for nil :debug-p nil :sly-port 4005)))
    (labels ((value-after (name)
               (or (pop arguments) (error "Missing value after ~A." name))))
      (loop while arguments
            for option = (pop arguments)
            do (cond
                 ((string= option "--backend")
                  (let ((value (value-after option)))
                    (setf (getf options :backend)
                          (cond ((string= value "auto") :auto)
                                ((string= value "headless") :headless)
                                (t (error "Unknown backend: ~A" value))))))
                 ((string= option "--width")
                  (setf (getf options :width)
                        (%number-option (value-after option) t option)))
                 ((string= option "--height")
                  (setf (getf options :height)
                        (%number-option (value-after option) t option)))
                 ((string= option "--run-for")
                  (setf (getf options :run-for)
                        (%number-option (value-after option) nil option)))
                 ((string= option "--debug")
                  (setf (getf options :debug-p) t))
                 ((string= option "--sly-port")
                  (let ((port (%number-option (value-after option) t option)))
                    (unless (<= port 65535)
                      (error "Invalid ~A value: ~A" option port))
                    (setf (getf options :sly-port) port)))
                 ((string= option "--no-sly")
                  (setf (getf options :sly-port) nil))
                 ((string= option "--help")
                  (return-from %parse-main-options :help))
                 (t (error "Unknown option: ~A" option)))))
    options))

(defun %print-usage ()
  (format t "Usage: run-infinite-world [--backend auto|headless] [--width N] [--height N] [--run-for SECONDS] [--debug] [--sly-port N|--no-sly]~%"))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  (handler-case
      (let ((options (%parse-main-options arguments)))
        (if (eq options :help)
            (progn (%print-usage) 0)
            (apply #'run-infinite-compositor options)))
    (serious-condition (cause)
      (format *error-output* "[infinite-world] fatal: ~A~%" cause)
      (finish-output *error-output*)
      1)))
