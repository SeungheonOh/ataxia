;;;; Thread-safe event delivery from a World to external agents.
;;;;
;;;; World callbacks publish small copied values without blocking. A SLY worker
;;;; may wait on the stream independently of the compositor owner thread.

(in-package #:ataxia.world)

(defstruct (agent-event
             (:constructor %make-agent-event
                 (sequence source name value timestamp)))
  sequence source name value timestamp)

(defclass agent-event-stream ()
  ((limit :initarg :limit :reader %agent-event-limit)
   (events :initform nil :accessor %agent-event-list)
   (next-sequence :initform 0 :accessor %agent-event-next-sequence)
   (closed-reason :initform nil :accessor %agent-event-closed-reason)
   (lock
    :initform (sb-thread:make-mutex :name "Ataxia agent event stream")
    :reader %agent-event-lock)
   (waitqueue
    :initform (sb-thread:make-waitqueue :name "Ataxia agent event stream")
    :reader %agent-event-waitqueue)))

(defgeneric world-agent-event-stream (world)
  (:documentation "Return WORLD's optional thread-safe external agent event stream."))

(defmethod world-agent-event-stream ((world ataxia.kernel:world))
  (declare (ignore world))
  nil)

(defun make-agent-event-stream (&key (limit 256))
  (check-type limit (integer 1 *))
  (make-instance 'agent-event-stream :limit limit))

(defun %agent-event-time ()
  (/ (get-internal-real-time)
     (coerce internal-time-units-per-second 'double-float)))

(defun %copy-agent-event-value (value)
  (if (stringp value) (copy-seq value) value))

(defun publish-agent-event
    (stream source name value &key (timestamp (%agent-event-time)))
  "Append one event and wake every external waiter without blocking on it."
  (check-type stream agent-event-stream)
  (let ((event nil))
    (sb-thread:with-mutex ((%agent-event-lock stream))
      (when (%agent-event-closed-reason stream)
        (return-from publish-agent-event nil))
      (setf event
            (%make-agent-event
             (incf (%agent-event-next-sequence stream))
             source name (%copy-agent-event-value value) timestamp))
      (push event (%agent-event-list stream))
      (when (> (length (%agent-event-list stream))
               (%agent-event-limit stream))
        (setf (%agent-event-list stream)
              (subseq (%agent-event-list stream)
                      0 (%agent-event-limit stream))))
      (sb-thread:condition-notify
       (%agent-event-waitqueue stream) most-positive-fixnum))
    event))

(defun %agent-event-batch (stream after)
  (let* ((stored (%agent-event-list stream))
         (oldest (if stored
                     (agent-event-sequence (car (last stored)))
                     (1+ (%agent-event-next-sequence stream))))
         (latest (%agent-event-next-sequence stream))
         (events
           (nreverse
            (remove-if-not
             (lambda (event) (> (agent-event-sequence event) after))
             (copy-list stored)))))
    (values events oldest latest (< after (1- oldest)))))

(defun wait-agent-events (stream &key (after 0) timeout)
  "Wait for events after AFTER, returning a bounded delivery batch plist."
  (check-type stream agent-event-stream)
  (check-type after (integer 0 *))
  (when timeout (check-type timeout (real 0 *)))
  (let ((deadline
          (and timeout
               (+ (%agent-event-time) (coerce timeout 'double-float)))))
    (sb-thread:with-mutex ((%agent-event-lock stream))
      (loop
        (multiple-value-bind (events oldest latest overflow-p)
            (%agent-event-batch stream after)
          (when events
            (return
              (list :status :events
                    :after after
                    :oldest oldest
                    :latest latest
                    :overflow-p overflow-p
                    :events events)))
          (when (%agent-event-closed-reason stream)
            (return
              (list :status :closed
                    :after after
                    :oldest oldest
                    :latest latest
                    :overflow-p overflow-p
                    :reason (%agent-event-closed-reason stream)
                    :events nil)))
          (let ((remaining (and deadline (- deadline (%agent-event-time)))))
            (when (and remaining (not (plusp remaining)))
              (return
                (list :status :timeout
                      :after after
                      :oldest oldest
                      :latest latest
                      :overflow-p overflow-p
                      :events nil)))
            (sb-thread:condition-wait
             (%agent-event-waitqueue stream)
             (%agent-event-lock stream)
             :timeout remaining)))))))

(defun close-agent-event-stream (stream reason)
  "Close STREAM and wake waiters so they can reacquire the active World."
  (check-type stream agent-event-stream)
  (sb-thread:with-mutex ((%agent-event-lock stream))
    (unless (%agent-event-closed-reason stream)
      (setf (%agent-event-closed-reason stream) reason)
      (sb-thread:condition-notify
       (%agent-event-waitqueue stream) most-positive-fixnum)))
  stream)
