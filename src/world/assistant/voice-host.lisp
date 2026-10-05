;;;; Codex's packaged WebRTC host owns audio. Only bounded signaling crosses
;;;; these pipes; no PCM, device callbacks, or audio polling enter the World.
(in-package #:ataxia.assistant)

(defstruct assistant-voice-host process epoch connection-epoch expected deadline muted)

(defun %assistant-voice-package ()
  "Resolve resources beside the configured CLI, including PATH symlinks."
  (let* ((command (first *assistant-command*))
         (executable
           (if (find #\/ command)
               (probe-file command)
               (loop for directory in (uiop:split-string (or (uiop:getenv "PATH") "") :separator ":")
                     for path = (probe-file (merge-pathnames command (uiop:ensure-directory-pathname directory)))
                     when path return path))))
    (loop for directory = (and executable (uiop:pathname-directory-pathname (truename executable)))
            then (uiop:pathname-parent-directory-pathname directory)
          repeat 6 while directory
          when (probe-file (merge-pathnames "codex-package.json" directory))
            return directory
          finally (error "Install the packaged Codex CLI with its voice runtime to use Voice."))))

(defun %assistant-voice-environment ()
  ;; Match the CLI's clean native-runtime environment. In particular, do not
  ;; inherit Ataxia's LD_LIBRARY_PATH or scan system GStreamer plugins/caches.
  (append
   (loop for entry in (sb-ext:posix-environ)
         for separator = (position #\= entry)
         when (and separator
                   (member (subseq entry 0 separator)
                           '("SYSTEMROOT" "WINDIR" "HOME" "USERPROFILE" "LOCALAPPDATA" "APPDATA" "TEMP" "TMP" "TMPDIR"
                             "XDG_RUNTIME_DIR" "PULSE_SERVER" "PULSE_COOKIE" "PIPEWIRE_REMOTE" "DBUS_SESSION_BUS_ADDRESS"
                             "HTTP_PROXY" "HTTPS_PROXY" "ALL_PROXY" "NO_PROXY" "SSL_CERT_FILE" "SSL_CERT_DIR"
                             "REQUESTS_CA_BUNDLE" "CURL_CA_BUNDLE") :test #'string-equal))
           collect entry)
   '("GST_PLUGIN_PATH=" "GST_PLUGIN_PATH_1_0=" "GST_PLUGIN_SYSTEM_PATH=" "GST_PLUGIN_SYSTEM_PATH_1_0="
     "GST_REGISTRY=/dev/null" "GST_REGISTRY_UPDATE=no" "GST_REGISTRY_FORK=no")
   (loop for directory in '("/usr/lib/x86_64-linux-gnu/alsa-lib" "/usr/lib/aarch64-linux-gnu/alsa-lib"
                           "/usr/lib64/alsa-lib" "/usr/lib/alsa-lib")
         when (probe-file directory) return (list (format nil "ALSA_PLUGIN_DIR=~A" directory)))))

(defun %assistant-voice-launch ()
  (let* ((root (%assistant-voice-package))
         (manifest (ataxia.world.wire:decode
                    (uiop:read-file-string (merge-pathnames "codex-resources/voice/manifest.json" root))
                    :max-nodes 4096))
         (commit (%assistant-field manifest "buildCommit"))
         (path (merge-pathnames "codex-resources/voice/bin/codex-voice-host" root)))
    (unless (and (eql 1 (%assistant-field manifest "schemaVersion"))
                 (stringp commit) (= 40 (length commit))
                 (every (lambda (c) (digit-char-p c 16)) commit)
                 (equal path (probe-file path)))
      (error "The installed Codex voice runtime is incompatible or incomplete."))
    (values
     (uiop:launch-program (list (namestring path)) :directory root :environment (%assistant-voice-environment)
                          :input :stream :output :stream :error-output "/dev/null" :if-error-output-exists :append
                          :element-type '(unsigned-byte 8))
     commit)))

(defun %assistant-voice-read-frame (stream)
  ;; Never report parser text: an SDP contains private ICE credentials.
  (handler-case
      (let* ((size (loop repeat 4 for n = (read-byte stream) then (+ (ash n 8) (read-byte stream)) finally (return n))))
        (unless (<= 1 size 131072) (error "Invalid frame size."))
        (let ((bytes (make-array size :element-type '(unsigned-byte 8))))
          (unless (= size (read-sequence bytes stream)) (error "Incomplete frame."))
          (values (ataxia.world.wire:decode (sb-ext:octets-to-string bytes :external-format :utf-8)
                                                 :max-string 65536 :max-nodes 32 :max-depth 4)
                  size)))
    (error () (error "Codex voice runtime closed or returned an invalid control frame."))))

(defun %assistant-voice-write-frame (stream message)
  (let ((bytes (sb-ext:string-to-octets (ataxia.world.wire:encode message) :external-format :utf-8)))
    (unless (<= (length bytes) 131072) (error "Voice control frame is too large."))
    (loop for shift in '(24 16 8 0) do (write-byte (ldb (byte 8 shift) (length bytes)) stream))
    (write-sequence bytes stream)
    (finish-output stream)))

(defun %assistant-voice-host-current-p (controller host)
  (and (assistant-controller-alive controller)
       (= (assistant-voice-host-connection-epoch host) (assistant-controller-epoch controller))
       (= (assistant-voice-host-epoch host) (assistant-controller-audio-epoch controller))
       (eq host (assistant-controller-audio controller))))

(defun %assistant-voice-host-reader (controller host)
  (let ((process (assistant-voice-host-process host)))
    (unwind-protect
         (handler-case
             (loop while (%assistant-voice-host-current-p controller host) do
               (multiple-value-bind (message size) (%assistant-voice-read-frame (uiop:process-info-output process))
                 (%assistant-queue controller :voice-host (list host message) (+ size 256)
                                   (assistant-voice-host-connection-epoch host))))
           (error ()
             ;; The helper's framed channel is the only diagnostic boundary.
             (when (%assistant-voice-host-current-p controller host)
               (ignore-errors (%assistant-queue controller :voice-host (list host nil) 256
                                                 (assistant-voice-host-connection-epoch host))))))
      (ignore-errors (uiop:terminate-process process :urgent t))
      (ignore-errors (close (uiop:process-info-input process)))
      (ignore-errors (close (uiop:process-info-output process)))
      (ignore-errors (uiop:wait-process process)))))

(defun %assistant-voice-host-request (controller host expected seconds type &rest fields)
  (when (%assistant-voice-host-current-p controller host)
    (setf (assistant-voice-host-expected host) expected
          (assistant-voice-host-deadline host) (+ (monotonic-time) seconds))
    ;; Only the assistant worker writes. Bound even a stopped helper's pipe.
    (sb-ext:with-timeout 2d0
      (%assistant-voice-write-frame (uiop:process-info-input (assistant-voice-host-process host))
                                   (apply #'%assistant-object "type" type fields)))))

(defun %assistant-voice-sdp (value)
  (unless (and (stringp value) (plusp (length value))
               (<= (length (sb-ext:string-to-octets value :external-format :utf-8)) 65536))
    (error "Invalid voice session description."))
  value)

(defun %assistant-voice-host-controls (controller host muted)
  (setf (assistant-voice-host-muted host) muted)
  (%assistant-voice-host-request controller host "audioControlsApplied" 5d0 "setAudioControls"
    "controls" (%assistant-object "microphoneMuted" (if muted t :false) "speakerSuppressed" :false)))

(defun %assistant-voice-host-event (controller host message)
  (unless (%assistant-voice-host-current-p controller host) (return-from %assistant-voice-host-event nil))
  (let ((type (%assistant-field message "type")))
    (unless (and type (equal type (assistant-voice-host-expected host)))
      (error "Codex voice runtime failed while connecting or controlling audio."))
    (setf (assistant-voice-host-expected host) nil (assistant-voice-host-deadline host) nil)
    (cond
      ((equal type "ready") (%assistant-voice-host-request controller host "runtimeReady" 30d0 "initializeRuntime"))
      ((equal type "runtimeReady") (%assistant-voice-host-request controller host "offer" 20d0 "startTransport"))
      ((equal type "offer")
       (setf (assistant-voice-host-expected host) "sdp"
             (assistant-voice-host-deadline host) (+ (monotonic-time) 30d0))
       (%assistant-rpc controller "thread/realtime/start"
         (%assistant-object "threadId" (assistant-controller-thread-id controller) "version" "v3"
                            "outputModality" "audio" "includeStartupContext" :false
                            "transport" (%assistant-object "type" "webrtc" "sdp" (%assistant-voice-sdp (%assistant-field message "sdp")))
                            "clientManagedHandoffs" :false "flushTranscriptTailOnSessionEnd" :false)
         (lambda (result failure)
           (declare (ignore result))
           (when (and failure (%assistant-voice-host-current-p controller host))
             (%assistant-voice-fail controller (%assistant-field failure "message"))))))
      ((equal type "transportReady") (%assistant-voice-host-request controller host "devicesOpened" 5d0 "openDevices"))
      ((equal type "devicesOpened") (%assistant-voice-host-controls controller host nil))
      ((equal type "audioControlsApplied")
       ;; The acknowledgement invalidates old capture generations before the
       ;; UI says muted. End voice can race any acknowledgement on the owner.
       (%assistant-owner controller
         (lambda ()
           (when (%assistant-voice-host-current-p controller host)
             (setf (assistant-controller-microphone controller) (if (assistant-voice-host-muted host) :muted :listening))
             (unless (eq :working (assistant-controller-task controller))
               (setf (assistant-controller-activity controller) (if (assistant-voice-host-muted host) "Microphone muted" "Listening")))
             (%assistant-refresh controller))))))))

(defun %assistant-voice-host-answer (controller sdp)
  (let ((host (assistant-controller-audio controller)))
    (when (and host (%assistant-voice-host-current-p controller host)
               (equal "sdp" (assistant-voice-host-expected host)))
      (%assistant-voice-host-request controller host "transportReady" 20d0 "applyAnswer" "sdp" (%assistant-voice-sdp sdp)))))

(defun %assistant-voice-host-start (controller epoch)
  (multiple-value-bind (process commit) (%assistant-voice-launch)
    (let ((host (make-assistant-voice-host :process process :epoch epoch :connection-epoch (assistant-controller-epoch controller))))
      (unless (sb-thread:with-mutex ((assistant-controller-lock controller))
                (when (and (= epoch (assistant-controller-audio-epoch controller)) (assistant-controller-voice-active controller))
                  (setf (assistant-controller-audio controller) host) t))
        (uiop:terminate-process process :urgent t)
        (uiop:wait-process process)
        (return-from %assistant-voice-host-start nil))
      (setf (assistant-controller-audio-thread controller)
            (sb-thread:make-thread (lambda () (%assistant-voice-host-reader controller host)) :name "Ataxia voice controls"))
      (%assistant-voice-host-request controller host "ready" 30d0 "hello" "protocol" 1 "buildCommit" commit))))

(defun %assistant-voice-control (controller host muted)
  (when (and host (%assistant-voice-host-current-p controller host))
    (%assistant-voice-host-controls controller host muted)))
