(in-package #:ataxia.infinite-world)

(defun run-metaworld-compositor
    (&key (backend :auto) (width 1280) (height 720) run-for debug-p
       damage-debug-p (sly-port 4005) standalone (assistant-p (not (eq backend :headless))) assistant-project (xwayland-p t)
       (status-bar-p (or assistant-p (not (eq backend :headless))))
       (screen-sharing-p (not (eq backend :headless)))
       (state-file (%meta-state-path standalone)))
  (when assistant-p (asdf:load-system "ataxia-assistant/metaworld"))
  (when status-bar-p (asdf:load-system "ataxia-web/status-bar"))
  (when screen-sharing-p (asdf:load-system "ataxia-screencast"))
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
           (when status-bar-p
             (uiop:symbol-call :ataxia.world.web.shell :enable-web-status-bar
                               (ataxia.kernel:kernel-world kernel)))
           (when xwayland-p
             (ataxia.kernel:enable-xwayland kernel)
             (sb-posix:setenv "DISPLAY" (ataxia.kernel:xwayland-display-name kernel) 1))
           (when screen-sharing-p
             (handler-case (uiop:symbol-call :ataxia.infinite-world :enable-screen-sharing (ataxia.kernel:kernel-world kernel))
               (error (cause) (format *error-output* "[metaworld] screen sharing unavailable: ~A~%" cause))))
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
             (uiop:symbol-call :ataxia.assistant :enable (ataxia.kernel:kernel-world kernel) :project (or assistant-project (namestring (asdf:system-source-directory "ataxia-metaworld")))))
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
      (let ((xwayland-p t) (screen-sharing-p :default) (status-bar-p :default)
            (remaining nil) (standalone nil) (state-file nil) (state-supplied-p nil)
            (assistant-p (cond ((equal "1" (uiop:getenv "ATAXIA_ASSISTANT")) t)
                               ((equal "0" (uiop:getenv "ATAXIA_ASSISTANT")) nil) (t :default)))
            (assistant-project nil))
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
                   ((string= option "--no-xwayland") (setf xwayland-p nil))
                   ((string= option "--no-screen-sharing") (setf screen-sharing-p nil))
                   ((string= option "--screen-sharing") (setf screen-sharing-p t))
                   ((string= option "--status-bar") (setf status-bar-p t))
                   ((string= option "--no-status-bar") (setf status-bar-p nil))
                   ((string= option "--no-persist") (setf state-file nil state-supplied-p t))
                   ((string= option "--assistant") (setf assistant-p t))
                   ((string= option "--no-assistant") (setf assistant-p nil))
                   ((string= option "--assistant-project")
                    (setf assistant-project (or (pop arguments) (error "Missing --assistant-project directory.")) assistant-p t))
                   (t (push option remaining))))
        (let ((options (%parse-main-options (nreverse remaining))))
          (if (eq :help options)
              (progn
                (format t "Metaworld: --world metaworld|niri|hyprland [--state-file PATH|--no-persist] [--assistant|--no-assistant] [--assistant-project DIR] [--no-xwayland] [--screen-sharing|--no-screen-sharing] [--status-bar|--no-status-bar]~%")
                (%print-usage) 0)
              (apply #'run-metaworld-compositor :standalone standalone :assistant-project assistant-project
                     :state-file (if state-supplied-p state-file (%meta-state-path standalone))
                     :xwayland-p xwayland-p
                     (append (unless (eq assistant-p :default) (list :assistant-p assistant-p))
                             (unless (eq screen-sharing-p :default) (list :screen-sharing-p screen-sharing-p))
                             (unless (eq status-bar-p :default) (list :status-bar-p status-bar-p)) options)))))
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
