;;;; Optional Codex realtime adapter. PCM16 mono at 24 kHz matches Codex's
;;;; realtime websocket session format. PipeWire's s16 is little-endian on x86-64.
;;;; The server owns speech-to-task handoff: transcripts are never resubmitted.
(in-package #:ataxia.assistant)
(defparameter *assistant-record-command* '("pw-record" "--raw" "--rate" "24000" "--channels" "1" "--format" "s16" "-"))
(defparameter *assistant-play-command* '("pw-play" "--raw" "--rate" "24000" "--channels" "1" "--format" "s16" "-"))

(defun %assistant-unbase64 (text)
  (unless (and (stringp text) (<= (length text) (* 2 1024 1024)) (zerop (mod (length text) 4)))
    (error "Invalid audio frame size."))
  (let ((bytes (make-array (* 3 (/ (length text) 4)) :element-type '(unsigned-byte 8) :fill-pointer 0)))
    (loop for i from 0 below (length text) by 4 do
          (let ((bits 0) (padding 0))
            (dotimes (j 4)
              (let ((c (char text (+ i j))))
                (if (char= c #\=)
                    (progn (unless (and (>= j 2) (= (+ i 4) (length text))) (error "Invalid audio padding."))
                           (incf padding) (setf bits (ash bits 6)))
                    (progn (when (plusp padding) (error "Invalid audio padding."))
                           (setf bits (logior (ash bits 6) (or (position c +assistant-base64-alphabet+) (error "Invalid audio encoding."))))))))
            (loop for shift in '(16 8 0) for j from 0 below (- 3 padding) do (vector-push (ldb (byte 8 shift) bits) bytes))))
    bytes))
(defun %assistant-audio-stop-now (controller)
  "Owner-safe: revoke local audio before waiting for any network acknowledgement."
  (let ((processes nil))
    (sb-thread:with-mutex ((assistant-controller-lock controller))
      (incf (assistant-controller-audio-epoch controller))
      (setf (assistant-controller-microphone controller) :off
            (assistant-controller-voice-resume-p controller) nil
            processes (list (shiftf (assistant-controller-audio controller) nil)
                            (shiftf (assistant-controller-audio-player controller) nil)))
      (sb-thread:signal-semaphore (assistant-controller-audio-wake controller)))
    (dolist (process processes) (when process (ignore-errors (uiop:terminate-process process))))))
(defun %assistant-voice-close (controller)
  (let ((was-active (shiftf (assistant-controller-voice-active controller) nil)))
    (%assistant-audio-stop-now controller)
    (sb-thread:with-mutex ((assistant-controller-lock controller))
      (setf (assistant-controller-audio-output controller) nil (assistant-controller-audio-output-bytes controller) 0))
    (when (and was-active (assistant-controller-process controller) (assistant-controller-thread-id controller))
      (setf (assistant-controller-voice-stopping-p controller) t)
      (ignore-errors
        (%assistant-rpc controller "thread/realtime/stop" (%assistant-object "threadId" (assistant-controller-thread-id controller))
          (lambda (result error) (declare (ignore result error))
            (setf (assistant-controller-voice-stopping-p controller) nil)))))
    (ignore-errors (%assistant-state controller :microphone :off))))

(defun %assistant-audio-playback-main (controller epoch play wake)
  (unwind-protect
       (handler-case
           (loop while (and (assistant-controller-alive controller)
                            (= epoch (assistant-controller-audio-epoch controller))) do
                 (sb-thread:wait-on-semaphore wake)
                 (let ((chunks
                        (sb-thread:with-mutex ((assistant-controller-lock controller))
                          (when (= epoch (assistant-controller-audio-epoch controller))
                            (prog1 (nreverse (assistant-controller-audio-output controller))
                              (setf (assistant-controller-audio-output controller) nil
                                    (assistant-controller-audio-output-bytes controller) 0))))))
                   (dolist (chunk chunks)
                     (when (= epoch (assistant-controller-audio-epoch controller))
                       (write-sequence chunk (uiop:process-info-input play))
                       (finish-output (uiop:process-info-input play))))))
         (error (cause)
           (when (= epoch (assistant-controller-audio-epoch controller))
             (ignore-errors (%assistant-queue controller :voice-error (princ-to-string cause))))))
    (ignore-errors (uiop:terminate-process play))))

(defun %assistant-voice-open-audio (controller epoch)
  (unless (and (= epoch (assistant-controller-audio-epoch controller)) (assistant-controller-voice-active controller))
    (return-from %assistant-voice-open-audio nil))
  (let* ((wake (sb-thread:make-semaphore :count 0))
         (record (uiop:launch-program *assistant-record-command* :input "/dev/null" :output :stream :error-output "/dev/null" :if-error-output-exists :append
                                      :element-type '(unsigned-byte 8)))
         (play (handler-case (uiop:launch-program *assistant-play-command* :input :stream :output "/dev/null" :if-output-exists :append :error-output "/dev/null" :if-error-output-exists :append
                                                  :element-type '(unsigned-byte 8))
                 (error (cause) (ignore-errors (uiop:terminate-process record)) (error cause)))))
    (unless (sb-thread:with-mutex ((assistant-controller-lock controller))
              (when (and (= epoch (assistant-controller-audio-epoch controller)) (assistant-controller-voice-active controller))
                (setf (assistant-controller-audio controller) record
                      (assistant-controller-audio-player controller) play
                      (assistant-controller-audio-wake controller) wake)
                (when (assistant-controller-audio-output controller)
                  (sb-thread:signal-semaphore wake))
                t))
      (ignore-errors (uiop:terminate-process record))
      (ignore-errors (uiop:terminate-process play))
      (return-from %assistant-voice-open-audio nil))
    (setf (assistant-controller-audio-thread controller)
          (sb-thread:make-thread
           (lambda ()
             (unwind-protect
                  (handler-case
                      (let ((first t) (buffer (make-array 2400 :element-type '(unsigned-byte 8))))
                        (loop while (and (assistant-controller-alive controller) (= epoch (assistant-controller-audio-epoch controller)))
                              for count = (read-sequence buffer (uiop:process-info-output record)) do
                              (when (zerop count) (error "PipeWire could not record audio."))
                              (when first (%assistant-queue controller :mic-ready epoch) (setf first nil))
                              (%assistant-queue controller :audio (list epoch (%assistant-base64 (subseq buffer 0 count)) (/ count 2)) (+ count 256))))
                    (error (cause)
                      (when (= epoch (assistant-controller-audio-epoch controller))
                        (ignore-errors (%assistant-queue controller :voice-error (princ-to-string cause))))))
               (ignore-errors (uiop:terminate-process record))))
           :name "Ataxia microphone"))
    (setf (assistant-controller-audio-play-thread controller)
          (sb-thread:make-thread
           (lambda () (%assistant-audio-playback-main controller epoch play wake))
           :name "Ataxia voice playback"))))
(defun %assistant-voice-start (controller)
  (unless (assistant-controller-thread-id controller)
    (%assistant-state controller :microphone :starting :activity "Connecting to Codex for talk mode")
    (return-from %assistant-voice-start nil))
  (when (or (assistant-controller-voice-active controller) (assistant-controller-voice-stopping-p controller))
    (return-from %assistant-voice-start nil))
  (let ((epoch (incf (assistant-controller-audio-epoch controller))))
    (setf (assistant-controller-voice-active controller) t (assistant-controller-voice-started-at controller) (monotonic-time))
    (%assistant-state controller :microphone :starting :activity "Starting voice connection")
    (%assistant-rpc controller "thread/realtime/start"
        (%assistant-object "threadId" (assistant-controller-thread-id controller) "outputModality" "audio"
                           "version" "v2" "transport" (%assistant-object "type" "websocket")
                           "clientManagedHandoffs" :false "flushTranscriptTailOnSessionEnd" :false)
      (lambda (result failure)
        (declare (ignore result))
        (when (= epoch (assistant-controller-audio-epoch controller))
          (when failure
            (progn (%assistant-voice-close controller)
                   (%assistant-state controller :activity
                                     (format nil "Voice unavailable: ~A. You can keep typing." (%assistant-field failure "message"))))
            ))))))
(defun %assistant-voice-send (controller value)
  (destructuring-bind (epoch data samples) value
    (when (and (= epoch (assistant-controller-audio-epoch controller)) (assistant-controller-voice-active controller))
      (%assistant-rpc controller "thread/realtime/appendAudio"
          (%assistant-object "threadId" (assistant-controller-thread-id controller)
                             "audio" (%assistant-object "data" data "sampleRate" 24000 "numChannels" 1 "samplesPerChannel" samples))
        (lambda (result failure)
          (declare (ignore result))
          (when (and failure (= epoch (assistant-controller-audio-epoch controller))) (%assistant-voice-close controller)
                (%assistant-state controller :activity (format nil "Voice connection failed: ~A" (%assistant-field failure "message")))))))))
(defun %assistant-voice-event (controller method params)
  (cond
    ((and (assistant-controller-voice-active controller) (equal method "thread/realtime/started"))
     (unless (equal "v2" (%assistant-field params "version")) (error "The voice server negotiated an unsupported protocol."))
     (when (and (eq :starting (assistant-controller-microphone controller))
                (null (assistant-controller-audio controller)))
       (%assistant-voice-open-audio controller (assistant-controller-audio-epoch controller))))
    ((equal method "thread/realtime/error")
     (%assistant-voice-close controller)
     (%assistant-state controller :activity (format nil "Voice unavailable: ~A. You can keep typing." (%assistant-field params "message"))))
    ((equal method "thread/realtime/closed") (%assistant-voice-close controller))
    ((and (assistant-controller-voice-active controller) (equal method "thread/realtime/outputAudio/delta"))
     (let* ((audio (%assistant-field params "audio"))
            (rate (%assistant-field audio "sampleRate")) (channels (%assistant-field audio "numChannels")))
       (unless (and (eql rate 24000) (eql channels 1))
         (error "Unsupported realtime audio format: ~A Hz, ~A channels." rate channels))
       (let ((bytes (%assistant-unbase64 (%assistant-field audio "data"))))
         (unless (evenp (length bytes)) (error "Incomplete PCM16 audio sample."))
         (sb-thread:with-mutex ((assistant-controller-lock controller))
           (when (> (+ (length bytes) (assistant-controller-audio-output-bytes controller)) (* 2 1024 1024))
             (error "Voice playback queue is full."))
           (let ((empty (null (assistant-controller-audio-output controller))))
             (push bytes (assistant-controller-audio-output controller))
             (incf (assistant-controller-audio-output-bytes controller) (length bytes))
             (when empty
               (sb-thread:signal-semaphore (assistant-controller-audio-wake controller))))))))
    ((and (assistant-controller-voice-active controller) (equal method "thread/realtime/transcript/delta"))
     (when (equal (%assistant-field params "role") "user")
       (when (%assistant-owner controller
               (lambda ()
                 (when (and (assistant-controller-turn-id controller) (not (assistant-controller-voice-resume-p controller)))
                   (setf (assistant-controller-voice-resume-p controller) t (assistant-controller-blocked controller) t)
                   (when (assistant-controller-session controller)
                     (cu:pause-session (assistant-controller-session controller) "Listening to your correction"))
                   t)))
         (%assistant-interrupt-turn controller))))
    ((and (assistant-controller-voice-active controller) (equal method "thread/realtime/transcript/done"))
     ;; Display only. The app-server's realtime handoff submits speech exactly once.
     (%assistant-owner controller
       (lambda ()
         (%assistant-add-message controller (if (equal (%assistant-field params "role") "user") :you :assistant)
                                 (%assistant-field params "text"))
         (%assistant-refresh controller))))))
