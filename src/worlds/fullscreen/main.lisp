;;;; Fullscreen compositor entrypoint.
;;;;
;;;; This entrypoint constructs the reference World, publishes the Runtime
;;;; socket, and keeps teardown deterministic around the owner-thread loop.

(in-package #:ataxia.fullscreen-world)

(defun run-fullscreen-compositor
    (&key (backend :auto) (headless-width 1280) (headless-height 720)
          run-for (socket-p t) debug-p)
  (let* ((world (make-fullscreen-world))
         (kernel
           (ataxia.kernel:create-kernel
            world
            :world-factory #'make-fullscreen-world
            :recovery-world-factory #'ataxia.world:make-rescue-world
            :backend backend
            :headless-width headless-width
            :headless-height headless-height
            :socket-p socket-p
            :debug-p debug-p)))
    (unwind-protect
         (progn
           (ataxia.kernel:start-kernel kernel)
           (format t "[fullscreen-world] WAYLAND_DISPLAY=~A~%"
                   (ataxia.runtime:runtime-socket-name
                    (ataxia.kernel:kernel-runtime kernel)))
           (finish-output)
           (ataxia.kernel:run-kernel kernel :run-for run-for)
           0)
      (ataxia.kernel:destroy-kernel kernel :fullscreen-world-exit))))

(defun %usage (stream)
  (format stream
          "Usage: run-fullscreen-world [options]~%\
~%\
Options:~%\
  --backend auto|headless  Select wlroots backend (default: auto)~%\
  --width PIXELS          Headless width (default: 1280)~%\
  --height PIXELS         Headless height (default: 720)~%\
  --run-for SECONDS       Stop after the given duration~%\
  --no-socket             Do not publish a Wayland socket~%\
  --debug                 Enable wlroots debug logging~%\
  --help                  Show this help~%"))

(defun %parse-positive-number (text integer-p option)
  (handler-case
      (let ((*read-eval* nil))
        (multiple-value-bind (value position)
            (read-from-string text nil nil)
          (unless (and (if integer-p (integerp value) (realp value))
                       (plusp value)
                       (= position (length text)))
            (error "Invalid value for ~A: ~A" option text))
          value))
    (reader-error ()
      (error "Invalid value for ~A: ~A" option text))))

(defun %take-option-value (arguments option)
  (unless arguments
    (error "Missing value for ~A." option))
  (values (first arguments) (rest arguments)))

(defun %parse-options (arguments)
  (let ((options
          (list :backend :auto
                :headless-width 1280
                :headless-height 720
                :run-for nil
                :socket-p t
                :debug-p nil))
        (help-p nil))
    (loop while arguments
          for option = (pop arguments)
          do (cond
               ((string= option "--backend")
                (multiple-value-bind (value remaining)
                    (%take-option-value arguments option)
                  (setf (getf options :backend)
                        (cond
                          ((string= value "auto") :auto)
                          ((string= value "headless") :headless)
                          (t (error "Unknown backend: ~A" value)))
                        arguments remaining)))
               ((string= option "--width")
                (multiple-value-bind (value remaining)
                    (%take-option-value arguments option)
                  (setf (getf options :headless-width)
                        (%parse-positive-number value t option)
                        arguments remaining)))
               ((string= option "--height")
                (multiple-value-bind (value remaining)
                    (%take-option-value arguments option)
                  (setf (getf options :headless-height)
                        (%parse-positive-number value t option)
                        arguments remaining)))
               ((string= option "--run-for")
                (multiple-value-bind (value remaining)
                    (%take-option-value arguments option)
                  (setf (getf options :run-for)
                        (%parse-positive-number value nil option)
                        arguments remaining)))
               ((string= option "--no-socket")
                (setf (getf options :socket-p) nil))
               ((string= option "--debug")
                (setf (getf options :debug-p) t))
               ((string= option "--help")
                (setf help-p t))
               (t
                (error "Unknown option: ~A" option))))
    (values options help-p)))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  (handler-case
      (multiple-value-bind (options help-p) (%parse-options arguments)
        (if help-p
            (progn (%usage *standard-output*) 0)
            (apply #'run-fullscreen-compositor options)))
    (serious-condition (cause)
      (format *error-output* "[fullscreen-world] fatal: ~A~%" cause)
      (finish-output *error-output*)
      1)))
