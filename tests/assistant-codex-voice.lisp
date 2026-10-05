;;;; Opt-in check of the installed CLI/account and our actual helper framing.
;;;; Establishes WebRTC without opening microphone or playback devices.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-assistant")
(in-package #:ataxia.assistant)
(unless (equal "1" (uiop:getenv "ATAXIA_TEST_CODEX"))
  (error "Set ATAXIA_TEST_CODEX=1 to connect to the realtime service."))

(let ((server nil) (host nil) (next-id 0) (thread-id nil))
  (labels ((read-message ()
             (ataxia.world.wire:decode
              (ataxia.world.wire:read-line-bytes (uiop:process-info-output server) +assistant-frame-limit+)
              :max-string +assistant-frame-limit+ :max-nodes 100000 :max-depth 32))
           (request (method params)
             (incf next-id)
             (ataxia.world.wire:write-line-bytes (uiop:process-info-input server)
               (ataxia.world.wire:encode (%assistant-object "id" next-id "method" method "params" params)))
             (loop for message = (read-message)
                   when (eql next-id (%assistant-field message "id")) do
                     (assert (not (%assistant-field message "error")))
                     (return (%assistant-field message "result"))))
           (exchange (type expected &rest fields)
             (%assistant-voice-write-frame (uiop:process-info-input host) (apply #'%assistant-object "type" type fields))
             (let ((message (%assistant-voice-read-frame (uiop:process-info-output host))))
               (assert (equal expected (%assistant-field message "type")))
               message)))
    (unwind-protect
         (sb-ext:with-timeout 90d0
           (multiple-value-bind (process commit) (%assistant-voice-launch)
             (setf host process)
             (exchange "hello" "ready" "protocol" 1 "buildCommit" commit))
           (exchange "initializeRuntime" "runtimeReady")
           (let ((offer (exchange "startTransport" "offer")))
             (setf server (uiop:launch-program *assistant-command* :input :stream :output :stream
                                              :error-output "/dev/null" :if-error-output-exists :append
                                              :element-type '(unsigned-byte 8)))
             (request "initialize" (%assistant-object "clientInfo" (%assistant-object "name" "ataxia_voice_test" "version" "1")
                                                       "capabilities" (%assistant-object "experimentalApi" t)))
             (ataxia.world.wire:write-line-bytes (uiop:process-info-input server) "{\"method\":\"initialized\"}")
             (assert (equal "chatgpt" (%assistant-field (request "account/read" (%assistant-object)) "account" "type")))
             (setf thread-id (%assistant-field
                              (request "thread/start" (%assistant-object "ephemeral" t "cwd" "/tmp" "sandbox" "read-only" "approvalPolicy" "on-request"))
                              "thread" "id"))
             (request "thread/realtime/start"
               (%assistant-object "threadId" thread-id "version" "v3" "outputModality" "audio"
                                  "includeStartupContext" :false "clientManagedHandoffs" :false
                                  "transport" (%assistant-object "type" "webrtc" "sdp" (%assistant-field offer "sdp"))))
             (loop for message = (read-message) for method = (%assistant-field message "method") do
               (when (equal method "thread/realtime/error") (error "The signed-in account could not start realtime."))
               (when (equal method "thread/realtime/sdp")
                 (exchange "applyAnswer" "transportReady" "sdp" (%assistant-field message "params" "sdp"))
                 (return)))
             ;; Do NOT send openDevices: this test never captures user audio.
             (request "thread/realtime/stop" (%assistant-object "threadId" thread-id))
             (exchange "close" "closed")
             (format t "PASS: installed Codex voice host and ChatGPT account connected over v3 WebRTC; audio devices remained closed.~%")))
      (dolist (process (list host server))
        (when process
          (ignore-errors (close (uiop:process-info-input process)))
          (handler-case (sb-ext:with-timeout 3d0 (uiop:wait-process process))
            (serious-condition () (ignore-errors (uiop:terminate-process process :urgent t))
                                  (ignore-errors (uiop:wait-process process)))))))))
