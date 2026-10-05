;;;; The mailbox is the worker's only wake source when no deadline is pending.
;;;; Each connection owns its semaphore, so retiring workers cannot consume a
;;;; replacement connection's wakeups.
(in-package #:ataxia.assistant)

(defun %assistant-worker-current-p (controller epoch)
  (and (assistant-controller-alive controller)
       (= epoch (assistant-controller-epoch controller))))

(defun %assistant-idle-p (controller)
  (and (eq :ready (assistant-controller-connection controller))
       (not (eq :working (assistant-controller-task controller)))
       (null (assistant-controller-turn-id controller))
       (null (assistant-controller-starting-turn controller))
       (null (assistant-controller-deferred controller))
       (null (assistant-controller-request controller))
       (null (assistant-controller-login-url controller))
       (not (assistant-controller-voice-active controller))
       (eq :off (assistant-controller-microphone controller))
       (zerop (hash-table-count (assistant-controller-pending controller)))
       (not (and (assistant-controller-tool-worker controller)
                 (sb-thread:thread-alive-p (assistant-controller-tool-worker controller))))))

(defun %assistant-park (controller)
  ;; Recheck on the owner: a human submission racing the deadline must win.
  (%assistant-owner controller
    (lambda ()
      (sb-thread:with-mutex ((assistant-controller-lock controller))
        (when (and (%assistant-idle-p controller) (null (assistant-controller-queue controller)))
          ;; Empty threads have no persisted rollout in Codex yet.
          (when (zerop (assistant-controller-turn-count controller))
            (setf (assistant-controller-thread-id controller) nil))
          (incf (assistant-controller-epoch controller))
          (setf (assistant-controller-connection controller) :sleeping
                (assistant-controller-worker controller) nil
                (assistant-controller-reader controller) nil
                (assistant-controller-process controller) nil)
          t)))))

(defun %assistant-voice-deadline (controller)
  (when (assistant-controller-voice-active controller)
    (let ((host (assistant-controller-audio controller)))
      (if host (assistant-voice-host-deadline host)
          (when (eq :starting (assistant-controller-microphone controller))
            (+ (assistant-controller-voice-started-at controller) 20d0))))))

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
      (%assistant-state controller :voice-error t :activity "Voice connection or audio control timed out. You can keep typing.")))
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
    ((:voice :voice-host :voice-control)
     ;; Optional voice failures must leave typed tasks and their connection usable.
     (handler-case
         (ecase kind
           (:voice (%assistant-voice-start controller))
           (:voice-host (apply #'%assistant-voice-host-event controller value))
           (:voice-control (apply #'%assistant-voice-control controller value)))
       (error (cause) (%assistant-voice-fail controller (princ-to-string cause)))
       (sb-ext:timeout () (%assistant-voice-fail controller "Voice runtime did not accept a control request"))))
    (:voice-stop (%assistant-voice-close controller))
    (:failure (error "~A" value))))

(defun %assistant-worker-loop (controller epoch wake)
  (loop with expired-task-deadline = nil and idle-since = nil
        while (%assistant-worker-current-p controller epoch) do
        (let* ((now (monotonic-time))
               (timeout (%assistant-worker-timeout controller now expired-task-deadline)))
          (setf idle-since (and *assistant-idle-timeout* (%assistant-idle-p controller)
                                (or idle-since now)))
          (when idle-since
            (let ((remaining (max 0d0 (- (+ idle-since *assistant-idle-timeout*) now))))
              (setf timeout (if timeout (min timeout remaining) remaining))))
          (sb-thread:wait-on-semaphore wake :timeout timeout))
        ;; Reset/shutdown also signal WAKE. Never inspect the new connection's state.
        (unless (%assistant-worker-current-p controller epoch) (return))
        (dolist (event (%assistant-take-events controller epoch))
          (destructuring-bind (event-epoch kind value) event
            (when (and (= epoch event-epoch) (%assistant-worker-current-p controller epoch))
              (%assistant-worker-event controller kind value))))
        (when (%assistant-worker-current-p controller epoch)
          ;; Interrupt an expired task once. Resuming sets a new start time.
          (setf expired-task-deadline
                (%assistant-check-deadlines controller (monotonic-time) expired-task-deadline))
          (when (and idle-since *assistant-idle-timeout*
                     (>= (monotonic-time) (+ idle-since *assistant-idle-timeout*)))
            (when (%assistant-park controller) (return))
            (setf idle-since nil)))))

(defun %assistant-reader-main (controller epoch process)
  (handler-case
      (loop while (%assistant-worker-current-p controller epoch)
            for line = (ataxia.world.wire:read-line-bytes
                        (uiop:process-info-output process) +assistant-frame-limit+)
            do (%assistant-queue controller :message
                                 (ataxia.world.wire:decode line :max-string +assistant-frame-limit+
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
        ;; EOF lets Codex flush the rollout and stop its children. Never block
        ;; the compositor owner while reaping an unresponsive child.
        (handler-case (sb-ext:with-timeout 3d0 (uiop:wait-process process))
          (serious-condition ()
            (ignore-errors (uiop:terminate-process process :urgent t))
            (handler-case (sb-ext:with-timeout 1d0 (uiop:wait-process process))
              (serious-condition () nil))))))))

(defun %assistant-connect (controller)
  ;; Owner thread: process creation and all pipe I/O happen in the worker.
  (unless (and (assistant-controller-worker controller)
               (sb-thread:thread-alive-p (assistant-controller-worker controller)))
    (incf (assistant-controller-epoch controller))
    (unless (eq :sleeping (assistant-controller-connection controller))
      (setf (assistant-controller-thread-id controller) nil))
    (setf (assistant-controller-turn-id controller) nil
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
