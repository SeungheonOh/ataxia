(in-package #:ataxia.infinite-world)

(defun run-metaworld-compositor
    (&key (backend :auto) (width 1280) (height 720) run-for debug-p
       damage-debug-p (sly-port 4005) standalone assistant-p assistant-project
       (state-file (%meta-state-path standalone)))
  (when assistant-p (asdf:load-system "ataxia-assistant/metaworld"))
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
           ;; Portal activation belongs to the direct desktop session. Run its
           ;; setup independently so a slow D-Bus service cannot stall frames.
           (unless (eq backend :headless)
             (%queue-program-launch
              (list "env" (format nil "WAYLAND_DISPLAY=~A"
                                  (ataxia.runtime:runtime-socket-name (ataxia.kernel:kernel-runtime kernel)))
                    "sh" (namestring (asdf:system-relative-pathname "ataxia-metaworld" "scripts/setup-desktop-session")))))
           (when (or sly-port assistant-p)
             (setf control (ataxia.sly-control:start-sly-control kernel :port sly-port)))
           (when assistant-p
             (uiop:symbol-call :ataxia.world.shell :enable-rmlui-status-bar (ataxia.kernel:kernel-world kernel))
             (uiop:symbol-call :ataxia.assistant :enable (ataxia.kernel:kernel-world kernel) :project assistant-project))
           (format t "[metaworld] WAYLAND_DISPLAY=~A mode=~A~%"
                   (ataxia.runtime:runtime-socket-name (ataxia.kernel:kernel-runtime kernel))
                   (or standalone :metaworld))
           (finish-output)
           (ataxia.kernel:run-kernel kernel :run-for run-for)
           0)
      (when control (ataxia.sly-control:stop-sly-control control))
      (ataxia.kernel:destroy-kernel kernel :metaworld-exit)
      (%meta-flush-saves))))

(defun metaworld-main (&optional (arguments (uiop:command-line-arguments)))
  (handler-case
      (let ((remaining nil) (standalone nil) (state-file nil) (state-supplied-p nil)
            (assistant-p (equal "1" (uiop:getenv "ATAXIA_ASSISTANT"))) (assistant-project nil))
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
                   ((string= option "--assistant") (setf assistant-p t))
                   ((string= option "--assistant-project")
                    (setf assistant-project (or (pop arguments) (error "Missing --assistant-project directory.")) assistant-p t))
                   (t (push option remaining))))
        (let ((options (%parse-main-options (nreverse remaining))))
          (if (eq :help options)
              (progn
                (format t "Metaworld: --world metaworld|niri|hyprland [--state-file PATH|--no-persist] [--assistant] [--assistant-project DIR]~%")
                (%print-usage) 0)
              (apply #'run-metaworld-compositor :standalone standalone :assistant-p assistant-p :assistant-project assistant-project
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
