(in-package #:ataxia.infinite-world)

(defun run-metaworld-compositor
    (&key (backend :auto) (width 1280) (height 720) run-for debug-p
          damage-debug-p (sly-port 4005) standalone
          (state-file (%meta-state-path standalone)))
  (let* ((factory (lambda () (make-metaworld :damage-debug-p damage-debug-p
                                            :standalone standalone :state-file state-file)))
         (kernel (ataxia.kernel:create-kernel
                  (funcall factory) :world-factory factory
                  :recovery-world-factory #'ataxia.world:make-rescue-world
                  :backend backend :headless-width width :headless-height height :debug-p debug-p))
         (control nil))
    (unwind-protect
         (progn
           (ataxia.kernel:start-kernel kernel)
           (when sly-port
             (setf control (ataxia.sly-control:start-sly-control kernel :port sly-port)))
           (format t "[metaworld] WAYLAND_DISPLAY=~A mode=~A~%"
                   (ataxia.runtime:runtime-socket-name (ataxia.kernel:kernel-runtime kernel))
                   (or standalone :metaworld))
           (finish-output)
           (ataxia.kernel:run-kernel kernel :run-for run-for)
           0)
      (when control (ataxia.sly-control:stop-sly-control control))
      (ataxia.kernel:destroy-kernel kernel :metaworld-exit))))

(defun metaworld-main (&optional (arguments (uiop:command-line-arguments)))
  (handler-case
      (let ((remaining nil) (standalone nil) (state-file nil) (state-supplied-p nil))
        (loop while arguments
              for option = (pop arguments)
              do (cond
                   ((string= option "--world")
                    (let ((value (or (pop arguments) (error "Missing --world value."))))
                      (setf standalone
                            (cond ((string= value "metaworld") nil)
                                  ((string= value "niri") :niri)
                                  ((string= value "hyprland") :hyprland)
                                  (t (error "Unknown world: ~A" value))))))
                   ((string= option "--state-file")
                    (setf state-file (pathname (or (pop arguments) (error "Missing --state-file value.")))
                          state-supplied-p t))
                   ((string= option "--no-persist") (setf state-file nil state-supplied-p t))
                   (t (push option remaining))))
        (let ((options (%parse-main-options (nreverse remaining))))
          (if (eq :help options)
              (progn
                (format t "Metaworld: --world metaworld|niri|hyprland [--state-file PATH|--no-persist]~%")
                (%print-usage) 0)
              (apply #'run-metaworld-compositor :standalone standalone
                     :state-file (if state-supplied-p state-file (%meta-state-path standalone)) options))))
    (serious-condition (cause)
      (format *error-output* "[metaworld] fatal: ~A~%" cause)
      1)))

(defpackage #:ataxia.metaworld
  (:use #:cl)
  (:import-from #:ataxia.infinite-world
   #:metaworld #:niri-world #:hyprland-world
   #:make-metaworld #:make-niri-world #:make-hyprland-world
   #:metaworld-subworlds #:create-subworld #:object-subworld
   #:subworld #:subworld-id #:subworld-name #:subworld-kind #:subworld-layout
   #:subworld-x #:subworld-y #:subworld-width #:subworld-height
   #:subworld-workspace #:subworld-members
   #:enter-subworld #:leave-subworld #:move-object-to-subworld
   #:move-subworld #:remove-subworld #:save-metaworld #:run-metaworld-compositor #:metaworld-main)
  (:export
   #:metaworld #:niri-world #:hyprland-world
   #:make-metaworld #:make-niri-world #:make-hyprland-world
   #:metaworld-subworlds #:create-subworld #:object-subworld
   #:subworld #:subworld-id #:subworld-name #:subworld-kind #:subworld-layout
   #:subworld-x #:subworld-y #:subworld-width #:subworld-height
   #:subworld-workspace #:subworld-members
   #:enter-subworld #:leave-subworld #:move-object-to-subworld
   #:move-subworld #:remove-subworld #:save-metaworld #:run-metaworld-compositor #:metaworld-main))
