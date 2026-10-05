;;;; Stage compositor entrypoint.
;;;;
;;;; The entrypoint owns the director process and the desktop services, not the
;;;; World: a replacement World listens on the same socket and the running
;;;; director reconnects. Shell services load on demand, as Metaworld's do.

(in-package #:ataxia.stage-world)

(defun %sdk-path (relative)
  (asdf:system-relative-pathname "ataxia-stage-world" (concatenate 'string "sdk/stage/" relative)))

(defun %director-command (script display socket)
  (let ((cli (%sdk-path "bin/ataxia-stage.mjs")))
    (unless (probe-file (%sdk-path "dist/index.js"))
      (error "The Stage SDK is not built; run `make stage` first."))
    (list "env" (format nil "WAYLAND_DISPLAY=~A" display)
          (format nil "ATAXIA_STAGE_SOCKET=~A" socket)
          (format nil "ATAXIA_STAGE_PARENT=~D" (sb-posix:getpid))
          "node" "--enable-source-maps" (namestring cli) (namestring (merge-pathnames script)))))

(defun run-stage-compositor
    (&key (backend :auto) (width 1280) (height 720) run-for debug-p damage-debug-p
          (sly-port 4005) (socket (default-director-socket))
          (script (asdf:system-relative-pathname "ataxia-stage-world" "examples/stage/canvas.tsx"))
          (director-p t) (xwayland-p t) (screen-sharing-p (not (eq backend :headless)))
          ;; Worlds draw their own bars; the shared web status bar is optional.
          status-bar-p
          (assistant-p (not (eq backend :headless))) assistant-project)
  "Run a Stage compositor. With DIRECTOR-P, launch the TypeScript runtime on SCRIPT."
  (when status-bar-p (asdf:load-system "ataxia-web/status-bar"))
  (when assistant-p (asdf:load-system "ataxia-assistant"))
  (let* ((factory (lambda () (make-stage-world :socket-path socket :damage-debug-p damage-debug-p
                                               :screen-sharing-p screen-sharing-p)))
         (kernel (ataxia.kernel:create-kernel
                  (funcall factory) :world-factory factory
                  :recovery-world-factory #'ataxia.world:make-rescue-world
                  :backend backend :headless-width width :headless-height height
                  :debug-p debug-p))
         (control nil)
         (director nil))
    (unwind-protect
         (let ((display (progn (ataxia.kernel:start-kernel kernel)
                               (ataxia.runtime:runtime-socket-name
                                (ataxia.kernel:kernel-runtime kernel)))))
           (when (or sly-port assistant-p)
             (setf control (ataxia.sly-control:start-sly-control kernel :port sly-port)))
           (when xwayland-p
             (ataxia.kernel:enable-xwayland kernel)
             (sb-posix:setenv "DISPLAY" (ataxia.kernel:xwayland-display-name kernel) 1))
           ;; A direct desktop session also points portals and activated services
           ;; at this display; the script runs apart so slow D-Bus never stalls frames.
           (unless (eq backend :headless)
             (uiop:launch-program
              (list "env" (format nil "WAYLAND_DISPLAY=~A" display) "sh"
                    (namestring (asdf:system-relative-pathname "ataxia-stage-world"
                                                               "scripts/setup-desktop-session")))
              :output nil :error-output nil))
           (when status-bar-p
             (uiop:symbol-call :ataxia.world.web.shell :enable-web-status-bar
                               (ataxia.kernel:kernel-world kernel)))
           (when assistant-p
             (uiop:symbol-call :ataxia.assistant :enable (ataxia.kernel:kernel-world kernel)
                               :project (or assistant-project
                                            (namestring (asdf:system-source-directory
                                                         "ataxia-stage-world")))))
           (when director-p
             (setf director (uiop:launch-program (%director-command script display socket)
                                                 :output :interactive :error-output :interactive)))
           (format t "[stage-world] WAYLAND_DISPLAY=~A ATAXIA_STAGE_SOCKET=~A~%" display socket)
           (finish-output)
           (ataxia.kernel:run-kernel kernel :run-for run-for)
           0)
      (when (and director (uiop:process-alive-p director))
        (uiop:terminate-process director))
      (when control (ataxia.sly-control:stop-sly-control control))
      (ataxia.kernel:destroy-kernel kernel :stage-world-exit))))

(defun %print-usage ()
  (format t "Usage: run-stage-world [--script PATH | --no-director] [--socket PATH] ~
[--status-bar|--no-status-bar] [--assistant|--no-assistant] [--assistant-project DIR] ~
[--no-xwayland] [--screen-sharing|--no-screen-sharing] [--backend auto|headless] [--width N] [--height N] [--run-for SECONDS] ~
[--debug] [--damage-debug] [--sly-port N|--no-sly]~%"))

(defun main (&optional (arguments (uiop:command-line-arguments)))
  (handler-case
      (let ((stage-options nil) (remaining nil))
        (loop while arguments
              for option = (pop arguments)
              do (cond
                   ((string= option "--script")
                    (setf (getf stage-options :script)
                          (or (pop arguments) (error "Missing --script path."))))
                   ((string= option "--socket")
                    (setf (getf stage-options :socket)
                          (or (pop arguments) (error "Missing --socket path."))))
                   ((string= option "--no-director")
                    (setf (getf stage-options :director-p) nil))
                   ((string= option "--no-xwayland")
                    (setf (getf stage-options :xwayland-p) nil))
                   ((member option '("--screen-sharing" "--no-screen-sharing") :test #'string=)
                    (setf (getf stage-options :screen-sharing-p) (string= option "--screen-sharing")))
                   ((member option '("--status-bar" "--no-status-bar") :test #'string=)
                    (setf (getf stage-options :status-bar-p) (string= option "--status-bar")))
                   ((member option '("--assistant" "--no-assistant") :test #'string=)
                    (setf (getf stage-options :assistant-p) (string= option "--assistant")))
                   ((string= option "--assistant-project")
                    (setf (getf stage-options :assistant-project)
                          (or (pop arguments) (error "Missing --assistant-project directory."))
                          (getf stage-options :assistant-p) t))
                   (t (push option remaining))))
        (let ((options (ataxia.world:parse-compositor-options (nreverse remaining))))
          (if (eq options :help)
              (progn (%print-usage) 0)
              (apply #'run-stage-compositor (append stage-options options)))))
    (serious-condition (cause)
      (format *error-output* "[stage-world] fatal: ~A~%" cause)
      (finish-output *error-output*)
      1)))
