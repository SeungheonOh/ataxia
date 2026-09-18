;;;; The mailbox is the worker's only wake source when no deadline is pending.
;;;; Each connection owns its semaphore, so retiring workers cannot consume a
;;;; replacement connection's wakeups.
(in-package #:ataxia.assistant)

(defun %assistant-worker-current-p (controller epoch)
  (and (assistant-controller-alive controller)
       (= epoch (assistant-controller-epoch controller))))

(defun %assistant-voice-deadline (controller)
  (when (and (assistant-controller-voice-active controller)
             (eq :starting (assistant-controller-microphone controller)))
    (+ (assistant-controller-voice-started-at controller) 20d0)))

(defun %assistant-task-deadline (controller)
  (when (assistant-controller-turn-id controller)
    (+ (assistant-controller-started controller) *assistant-time-limit*)))

(defun %assistant-worker-timeout (controller &optional (now (monotonic-time)) expired-task-deadline)
  "Seconds until the next deadline, or NIL to sleep until a mailbox event."
  (let ((deadline nil))
    (flet ((include-deadline (time)
             (when time (setf deadline (if deadline (min deadline time) time)))))
      (maphash (lambda (id pending)
                 (declare (ignore id))
                 (include-deadline (second pending)))
               (assistant-controller-pending controller))
      (include-deadline (%assistant-voice-deadline controller))
      (let ((task-deadline (%assistant-task-deadline controller)))
        (unless (eql task-deadline expired-task-deadline)
          (include-deadline task-deadline))))
    (when deadline (max 0d0 (- deadline now)))))

(defun %assistant-check-deadlines (controller &optional (now (monotonic-time)) expired-task-deadline)
  (maphash (lambda (id pending)
             (declare (ignore id))
             (when (>= now (second pending))
               (error "Codex timed out during ~A." (third pending))))
           (assistant-controller-pending controller))
  (let ((deadline (%assistant-voice-deadline controller)))
    (when (and deadline (>= now deadline))
      (%assistant-voice-close controller)
      (%assistant-state controller :activity "Voice startup timed out. You can keep typing.")))
  (let ((deadline (%assistant-task-deadline controller)))
    (when (and deadline (not (eql deadline expired-task-deadline)) (>= now deadline))
      (%assistant-owner controller
        (lambda ()
          (%assistant-pause controller
                            (format nil "Paused after ~D minutes" (round (/ *assistant-time-limit* 60))))))
      (setf expired-task-deadline deadline)))
  expired-task-deadline)

(defun %assistant-worker-event (controller kind value)
  (case kind
    (:message (%assistant-receive controller value))
    (:submit (%assistant-send-task controller value))
    (:retry (%assistant-account controller))
    (:login (%assistant-login controller))
    (:interrupt (%assistant-interrupt controller))
    (:response (%assistant-result controller (first value) (second value)))
    (:rpc (apply #'%assistant-rpc controller value))
    (:tool-result
     (destructuring-bind (key id result) value
       (when (> (hash-table-count (assistant-controller-seen-calls controller)) 512)
         (clrhash (assistant-controller-seen-calls controller)))
       (setf (gethash key (assistant-controller-seen-calls controller))
             (%assistant-cache-result result))
       (%assistant-journal controller "completed" "call" (third key) "success" (gethash "success" result))
       (%assistant-result controller id result)))
    (:voice (%assistant-voice-start controller))
    (:voice-stop (%assistant-voice-close controller))
    (:audio (%assistant-voice-send controller value))
    (:mic-ready
     (when (= value (assistant-controller-audio-epoch controller))
       (%assistant-state controller :microphone :listening :activity "Listening")))
    (:voice-error
     (%assistant-voice-close controller)
     (%assistant-state controller :activity value))
    (:failure (error "~A" value))))

(defun %assistant-worker-loop (controller epoch wake)
  (loop with expired-task-deadline = nil
        while (%assistant-worker-current-p controller epoch) do
        (sb-thread:wait-on-semaphore
         wake :timeout (%assistant-worker-timeout controller (monotonic-time) expired-task-deadline))
        ;; Reset/shutdown also signal WAKE. Never inspect the new connection's state.
        (unless (%assistant-worker-current-p controller epoch) (return))
        (dolist (event (%assistant-take-events controller epoch))
          (destructuring-bind (event-epoch kind value) event
            (when (and (= epoch event-epoch) (%assistant-worker-current-p controller epoch))
              (%assistant-worker-event controller kind value))))
        (when (%assistant-worker-current-p controller epoch)
          ;; Interrupt an expired task once. Resuming grants it a new start time.
          (setf expired-task-deadline
                (%assistant-check-deadlines controller (monotonic-time) expired-task-deadline)))))

(defun %assistant-reader-main (controller epoch process)
  (handler-case
      (loop while (%assistant-worker-current-p controller epoch)
            for line = (ataxia.computer-use.wire:read-line-bytes
                        (uiop:process-info-output process) +assistant-frame-limit+)
            do (%assistant-queue controller :message
                                 (ataxia.computer-use.wire:decode line :max-string +assistant-frame-limit+
                                                                  :max-nodes 100000 :max-depth 32)
                                 (length line) epoch))
    (error (cause)
      (ignore-errors (%assistant-queue controller :failure (princ-to-string cause) 256 epoch)))))

(defun %assistant-worker-main (controller epoch wake)
  (let ((*assistant-operation-epoch* epoch)
        (*assistant-operation-process* nil)
        (process nil))
    (unwind-protect
         (handler-case
             (progn
               (setf process
                     (uiop:launch-program *assistant-command* :input :stream :output :stream
                                          :error-output "/dev/null" :if-error-output-exists :append
                                          :element-type '(unsigned-byte 8)))
               (unless (%assistant-worker-current-p controller epoch)
                 (return-from %assistant-worker-main nil))
               (setf (assistant-controller-process controller) process
                     *assistant-operation-process* process
                     (assistant-controller-reader controller)
                     (sb-thread:make-thread
                      (lambda () (%assistant-reader-main controller epoch process))
                      :name "Ataxia Codex reader"))
               (%assistant-handshake controller)
               (%assistant-worker-loop controller epoch wake))
           (error (cause) (%assistant-fail controller cause)))
      (when (%assistant-worker-current-p controller epoch)
        (ignore-errors (%assistant-voice-close controller)))
      (when process
        (ignore-errors (close (uiop:process-info-input process)))
        (ignore-errors (uiop:terminate-process process))))))

(defun %assistant-connect (controller)
  ;; Owner thread: process creation and all pipe I/O happen in the worker.
  (unless (and (assistant-controller-worker controller)
               (sb-thread:thread-alive-p (assistant-controller-worker controller)))
    (incf (assistant-controller-epoch controller))
    (setf (assistant-controller-thread-id controller) nil
          (assistant-controller-turn-id controller) nil
          (assistant-controller-starting-turn controller) nil
          (assistant-controller-connection controller) :connecting)
    (clrhash (assistant-controller-pending controller))
    (%assistant-take-events controller)
    (let ((epoch (assistant-controller-epoch controller))
          (wake (sb-thread:make-semaphore :count 0)))
      (setf (assistant-controller-wake controller) wake
            (assistant-controller-worker controller)
            (sb-thread:make-thread (lambda () (%assistant-worker-main controller epoch wake))
                                   :name "Ataxia Codex worker"))))
  (%assistant-refresh controller))
