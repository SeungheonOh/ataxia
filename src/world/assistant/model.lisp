;;;; The owner owns the UI and task state. Only the protocol worker writes to Codex.
(in-package #:ataxia.assistant)

(defparameter *assistant-command* '("codex" "--enable" "realtime_conversation" "app-server" "--stdio"))
(defparameter +assistant-frame-limit+ (* 8 1024 1024))
(defparameter *assistant-time-limit* 1800d0)
(defparameter *assistant-tool-limit* 256)
(defparameter *assistant-idle-timeout* 60d0)
(defvar *assistant-operation-epoch* nil)
(defvar *assistant-operation-process* nil)

(defstruct assistant-model-selection selected default default-effort active)
(defstruct assistant-generation-settings
  effort (fast :inherit) default-tier active-effort active-tier (details nil))

(defstruct (assistant-controller (:constructor %make-assistant-controller))
  ;; Owner-thread attachment, widgets and user preferences.
  world generation (shortcuts (make-shortcut-controller)) (epoch 0) (alive t)
  output seat panel session timer (last-render 0d0)
  (model-selection (make-assistant-model-selection))
  (generation-settings (make-assistant-generation-settings))
  refresh-context
  ;; Task state and conversation.
  (connection :offline) (task :idle) (microphone :off)
  (activity "Ready when you are") (messages nil) (plan nil) (request nil)
  project (blocked t) (started 0d0)
  (models #()) login-url login-id journal-path
  (previews (make-hash-table :test #'equal))
  ;; Protocol worker and its synchronized mailbox.
  worker reader process (queue nil) (queue-bytes 0)
  (lock (sb-thread:make-mutex :name "Ataxia assistant mailbox"))
  (wake (sb-thread:make-semaphore :count 0))
  (next-id 0) (pending (make-hash-table :test #'eql))
  thread-id turn-id (starting-turn nil) (deferred nil)
  (seen-calls (make-hash-table :test #'equal)) tool-worker
  (tool-count 0) (turn-count 0) (audio nil)
  (audio-thread nil) (audio-epoch 0) (voice-active nil) (voice-started-at 0d0)
  (voice-version nil) voice-error (voice-caption "") (voice-caption-role nil)
  (voice-stopping-p nil) (voice-resume-p nil)
  (utterances (make-hash-table :test #'equal)))

(defun %assistant-object (&rest entries)
  (let ((object (make-hash-table :test #'equal)))
    (loop for (key value) on entries by #'cddr do (setf (gethash key object) value))
    object))
(defun %assistant-field (object &rest path)
  (reduce (lambda (value key) (and (hash-table-p value) (gethash key value))) path :initial-value object))
(defun %assistant-text (text &optional (limit 32768))
  (if (stringp text) (subseq text 0 (min limit (length text))) ""))
(defun %assistant-queue (controller kind value &optional (bytes 256) (epoch (or *assistant-operation-epoch* (assistant-controller-epoch controller))))
  (sb-thread:with-mutex ((assistant-controller-lock controller))
    (unless (assistant-controller-alive controller) (return-from %assistant-queue nil))
    (when (or (>= (length (assistant-controller-queue controller)) 512)
              (> (+ bytes (assistant-controller-queue-bytes controller)) (* 16 1024 1024)))
      (error "Assistant mailbox is full; reconnect to continue."))
    (unless (= epoch (assistant-controller-epoch controller)) (return-from %assistant-queue nil))
    ;; The worker drains the whole mailbox. One wake covers the entire batch.
    (let ((empty (null (assistant-controller-queue controller))))
      (push (list epoch kind value) (assistant-controller-queue controller))
      (incf (assistant-controller-queue-bytes controller) bytes)
      (when empty
        (sb-thread:signal-semaphore (assistant-controller-wake controller)))))
  t)
(defun %assistant-take-events (controller &optional epoch)
  (sb-thread:with-mutex ((assistant-controller-lock controller))
    (when (and epoch (/= epoch (assistant-controller-epoch controller))) (return-from %assistant-take-events nil))
    (prog1 (nreverse (assistant-controller-queue controller))
      (setf (assistant-controller-queue controller) nil (assistant-controller-queue-bytes controller) 0))))
(defun %assistant-owner (controller function &optional (epoch (or *assistant-operation-epoch* (assistant-controller-epoch controller))))
  (ataxia.sly-control:agent-inspect
   (lambda (kernel world)
     (declare (ignore kernel))
     (unless (and (assistant-controller-alive controller)
                  (= epoch (assistant-controller-epoch controller))
                  (eq world (assistant-controller-world controller))
                  (eq controller (world-service world :assistant)))
       (error "This assistant conversation has ended."))
     (funcall function))
   :expected-generation (assistant-controller-generation controller) :timeout 5d0))
(defun %assistant-add-message (controller role text &optional id)
  (let ((entry (and id (find id (assistant-controller-messages controller) :key (lambda (m) (getf m :id)) :test #'equal))))
    (if entry (setf (getf entry :text) (%assistant-text text))
        (setf (assistant-controller-messages controller)
              (append (last (assistant-controller-messages controller) 39)
                      (list (list :role role :text (%assistant-text text) :id id)))))))
(defun %assistant-state (controller &rest fields)
  (%assistant-owner controller
    (lambda ()
      (loop for (key value) on fields by #'cddr do
            (ecase key
              (:connection (setf (assistant-controller-connection controller) value))
              (:task (setf (assistant-controller-task controller) value))
              (:microphone (setf (assistant-controller-microphone controller) value))
              (:voice-error (setf (assistant-controller-voice-error controller) value))
              (:activity (setf (assistant-controller-activity controller) (%assistant-text value 1024)))
              (:plan (setf (assistant-controller-plan controller) value))
              (:request (setf (assistant-controller-request controller) value))))
      (%assistant-refresh controller))))
(defun %assistant-fail (controller cause)
  (when (and *assistant-operation-epoch* (/= *assistant-operation-epoch* (assistant-controller-epoch controller)))
    (return-from %assistant-fail nil))
  (ignore-errors (%assistant-voice-close controller))
  (ignore-errors
    (%assistant-owner controller
      (lambda ()
        (setf (assistant-controller-blocked controller) t
              (assistant-controller-connection controller) :error
              (assistant-controller-task controller) :failed
              (assistant-controller-microphone controller) :off
              (assistant-controller-activity controller) (%assistant-text (princ-to-string cause) 1024))
        (when (assistant-controller-session controller)
          (cu:pause-session (assistant-controller-session controller) "Assistant disconnected"))
        (%assistant-refresh controller)))))

(defstruct assistant-preview id process app-id path (revision 1))
