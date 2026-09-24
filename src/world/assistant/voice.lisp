;;;; Codex owns realtime speech, account authentication and speech-to-task handoff.
;;;; The same packaged WebRTC audio host as the CLI runs entirely outside the owner.
(in-package #:ataxia.assistant)

(defun %assistant-audio-stop-now (controller)
  "Owner-safe: revoke local audio before waiting for any network acknowledgement."
  (let ((host nil))
    (sb-thread:with-mutex ((assistant-controller-lock controller))
      (incf (assistant-controller-audio-epoch controller))
      (setf (assistant-controller-microphone controller) :off
            (assistant-controller-voice-caption controller) ""
            (assistant-controller-voice-resume-p controller) nil
            host (shiftf (assistant-controller-audio controller) nil)))
    ;; Closing a pipe can wait for its reader lock. Terminate only here; the
    ;; host reader closes streams and reaps the child on its own thread.
    (when host (ignore-errors (uiop:terminate-process (assistant-voice-host-process host) :urgent t)))))

(defun %assistant-voice-close (controller)
  (let ((was-active (shiftf (assistant-controller-voice-active controller) nil)))
    (%assistant-audio-stop-now controller)
    (when (and was-active (assistant-controller-process controller) (assistant-controller-thread-id controller))
      (setf (assistant-controller-voice-stopping-p controller) t)
      (ignore-errors
        (%assistant-rpc controller "thread/realtime/stop" (%assistant-object "threadId" (assistant-controller-thread-id controller))
          (lambda (result error) (declare (ignore result error))
            (setf (assistant-controller-voice-stopping-p controller) nil)))))
    (ignore-errors (%assistant-state controller :microphone :off))))

(defun %assistant-voice-fail (controller reason)
  (%assistant-voice-close controller)
  (%assistant-state controller :voice-error t :activity (format nil "Voice unavailable: ~A. You can keep typing." reason)))

(defun %assistant-toggle-microphone (controller)
  (unless (and (assistant-controller-voice-active controller)
               (member (assistant-controller-microphone controller) '(:listening :muted)))
    (error "Wait for voice to connect before changing the microphone."))
  (let ((muted (eq :listening (assistant-controller-microphone controller))))
    (setf (assistant-controller-microphone controller) (if muted :muting :unmuting))
    (%assistant-queue controller :voice-control (list (assistant-controller-audio controller) muted))))

(defun %assistant-voice-start (controller)
  (unless (and (eq :ready (assistant-controller-connection controller))
               (assistant-controller-thread-id controller))
    (%assistant-state controller :microphone :starting :activity "Connecting to Codex for talk mode")
    (return-from %assistant-voice-start nil))
  (when (or (assistant-controller-voice-active controller) (assistant-controller-voice-stopping-p controller))
    (return-from %assistant-voice-start nil))
  (let ((epoch (incf (assistant-controller-audio-epoch controller))))
    (clrhash (assistant-controller-utterances controller))
    (setf (assistant-controller-voice-active controller) t
          (assistant-controller-voice-version controller) nil
          (assistant-controller-voice-started-at controller) (monotonic-time))
    (%assistant-state controller :microphone :starting :voice-error nil :activity "Starting voice connection")
    (%assistant-voice-host-start controller epoch)))

(defun %assistant-voice-transcript (controller role text &key done id)
  (%assistant-owner controller
    (lambda ()
      (setf (assistant-controller-voice-caption-role controller) role
            (assistant-controller-voice-caption controller) (%assistant-text text 2048))
      (when done
        (%assistant-add-message controller (if (equal role "user") :you :assistant) text id))
      (%assistant-refresh controller))))

(defun %assistant-voice-user-start (controller)
  (when (%assistant-owner controller
          (lambda ()
            (when (and (assistant-controller-turn-id controller)
                       (not (assistant-controller-voice-resume-p controller)))
              (setf (assistant-controller-voice-resume-p controller) t
                    (assistant-controller-blocked controller) t)
              (when (assistant-controller-session controller)
                (cu:pause-session (assistant-controller-session controller) "Listening to your correction"))
              t)))
    (%assistant-interrupt-turn controller)))

(defun %assistant-voice-event (controller method params)
  (cond
    ((and (assistant-controller-voice-active controller) (equal method "thread/realtime/started"))
     (unless (member (%assistant-field params "version") '("v1" "v2" "v3") :test #'equal)
       (error "The voice server negotiated an unsupported protocol."))
     ;; Native devices open only after the WebRTC answer is connected.
     (setf (assistant-controller-voice-version controller) (%assistant-field params "version")))
    ((and (assistant-controller-voice-active controller) (equal method "thread/realtime/sdp"))
     (%assistant-voice-host-answer controller (%assistant-field params "sdp")))
    ((equal method "thread/realtime/error")
     (%assistant-voice-close controller)
     (%assistant-state controller :voice-error t :activity (format nil "Voice unavailable: ~A. You can keep typing." (%assistant-field params "message"))))
    ((equal method "thread/realtime/closed") (%assistant-voice-close controller))
    ((and (assistant-controller-voice-active controller) (equal method "thread/realtime/transcript/delta"))
     (unless (equal "v3" (assistant-controller-voice-version controller))
       (%assistant-voice-transcript controller (%assistant-field params "role")
         (concatenate 'string
           (if (equal (%assistant-field params "role") (assistant-controller-voice-caption-role controller))
               (assistant-controller-voice-caption controller) "")
           (%assistant-text (%assistant-field params "delta") 2048))))
     (when (equal (%assistant-field params "role") "user")
       (%assistant-voice-user-start controller)))
    ((and (assistant-controller-voice-active controller) (equal method "thread/realtime/transcript/done"))
     ;; Display only. The app-server's realtime handoff submits speech exactly once.
     (unless (equal "v3" (assistant-controller-voice-version controller))
       (%assistant-voice-transcript controller (%assistant-field params "role")
                                    (%assistant-field params "text") :done t)
       (setf (assistant-controller-voice-caption-role controller) nil)))
    ((and (assistant-controller-voice-active controller)
          (equal "v3" (assistant-controller-voice-version controller))
          (member method '("thread/realtime/item/started" "thread/realtime/item/completed") :test #'equal))
     (let* ((item (%assistant-field params "item")) (id (%assistant-field item "id")))
       (when (equal (%assistant-field item "type") "transcriptSegment")
         (when (and (equal method "thread/realtime/item/started")
                    (equal (%assistant-field item "role") "user"))
           (%assistant-voice-user-start controller))
         (when (> (hash-table-count (assistant-controller-utterances controller)) 64)
           (clrhash (assistant-controller-utterances controller)))
         (setf (gethash id (assistant-controller-utterances controller)) item)
         (%assistant-voice-transcript controller (%assistant-field item "role") (%assistant-field item "text")
           :id id :done (equal method "thread/realtime/item/completed")))))
    ((and (assistant-controller-voice-active controller)
          (equal "v3" (assistant-controller-voice-version controller))
          (equal method "thread/realtime/item/transcript/delta"))
     (let ((item (gethash (%assistant-field params "itemId") (assistant-controller-utterances controller))))
       (when item
         (setf (gethash "text" item)
               (%assistant-text (concatenate 'string (or (%assistant-field item "text") "")
                                             (%assistant-text (%assistant-field params "delta"))) 32768))
         (%assistant-voice-transcript controller (%assistant-field item "role") (%assistant-field item "text")))))))
