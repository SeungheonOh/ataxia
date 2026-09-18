;;;; Packed atlas compositor entrypoint.

(in-package #:ataxia.atlas-world)

(defun run-atlas-compositor
    (&key (backend :auto) (width 1280) (height 720) run-for debug-p
          damage-debug-p (sly-port 4005))
  (let ((control nil)
        (kernel
          (ataxia.kernel:create-kernel
           (make-atlas-world :damage-debug-p damage-debug-p)
           :world-factory
           (lambda ()
             (make-atlas-world :damage-debug-p damage-debug-p))
           :recovery-world-factory #'ataxia.world:make-rescue-world
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
           (format t "[atlas-world] WAYLAND_DISPLAY=~A~%"
                   (ataxia.runtime:runtime-socket-name
                    (ataxia.kernel:kernel-runtime kernel)))
           (when control
             (format t "[atlas-world] SLYNK=localhost:~D~%"
                     (ataxia.sly-control:sly-control-port control)))
           (finish-output)
           (ataxia.kernel:run-kernel kernel :run-for run-for)
           0)
      (when control
        (ataxia.sly-control:stop-sly-control control))
      (ataxia.kernel:destroy-kernel kernel :atlas-world-exit))))

(defun %parse-main-options (arguments)
  (ataxia.world:parse-compositor-options arguments))

(defun %print-usage ()
  (format t "Usage: run-atlas-world [--backend auto|headless] [--width N] [--height N] [--run-for SECONDS] [--debug] [--damage-debug] [--sly-port N|--no-sly]~%"))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  (handler-case
      (let ((options (%parse-main-options arguments)))
        (if (eq options :help)
            (progn (%print-usage) 0)
            (apply #'run-atlas-compositor options)))
    (serious-condition (cause)
      (format *error-output* "[atlas-world] fatal: ~A~%" cause)
      (finish-output *error-output*)
      1)))
