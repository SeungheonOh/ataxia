;;;; Exercise real worker waits without a compositor, network, or Codex process.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-assistant/metaworld")
(in-package #:ataxia.infinite-world)

;; Bursts require one wake and retain FIFO order. A later burst wakes again.
(let ((controller (ataxia.assistant::%make-assistant-controller)))
  (dotimes (i 100) (ataxia.assistant::%assistant-queue controller :fixture i))
  (assert (sb-thread:try-semaphore (ataxia.assistant::assistant-controller-wake controller)))
  (assert (not (sb-thread:try-semaphore (ataxia.assistant::assistant-controller-wake controller))))
  (assert (equal (loop for i below 100 collect i)
                 (mapcar #'third (ataxia.assistant::%assistant-take-events controller))))
  (ataxia.assistant::%assistant-queue controller :fixture :next)
  (assert (sb-thread:try-semaphore (ataxia.assistant::assistant-controller-wake controller)))
  (assert (equal '(0 :fixture :next) (first (ataxia.assistant::%assistant-take-events controller)))))

;; An idle worker neither polls nor scans deadlines, but responds to a message.
(let* ((controller (ataxia.assistant::%make-assistant-controller))
       (wake (ataxia.assistant::assistant-controller-wake controller))
       (ready (sb-thread:make-semaphore))
       (received (sb-thread:make-semaphore))
       (original (symbol-function 'ataxia.assistant::%assistant-check-deadlines))
       (checks 0) (failure nil) (thread nil))
  (unwind-protect
       (progn
         (setf (symbol-function 'ataxia.assistant::%assistant-check-deadlines)
               (lambda (&rest args) (incf checks) (apply original args)))
         (setf (gethash 1 (ataxia.assistant::assistant-controller-pending controller))
               (list (lambda (result error)
                       (assert (not error))
                       (assert (equal "delivered" result))
                       (sb-thread:signal-semaphore received))
                     (+ (%now) 60d0) "fixture"))
         (setf thread
               (sb-thread:make-thread
                (lambda ()
                  (handler-case
                      (progn (sb-thread:signal-semaphore ready)
                             (ataxia.assistant::%assistant-worker-loop controller 0 wake)
                             :exited)
                    (error (cause) (setf failure cause))))))
         (assert (sb-thread:wait-on-semaphore ready :timeout 2d0))
         (sleep 2.2d0)
         (assert (zerop checks))
         (ataxia.assistant::%assistant-queue controller :message (ataxia.assistant::%assistant-object "id" 1 "result" "delivered"))
         (assert (sb-thread:wait-on-semaphore received :timeout 2d0))
         ;; Reset must wake a worker even after its last RPC has completed.
         (ataxia.assistant::%assistant-reset-conversation controller)
         (assert (eq :exited (sb-thread:join-thread thread :timeout 2d0 :default :stuck)))
         (assert (null failure)))
    (setf (symbol-function 'ataxia.assistant::%assistant-check-deadlines) original
          (ataxia.assistant::assistant-controller-alive controller) nil)
    (sb-thread:signal-semaphore wake)
    (when thread (sb-thread:join-thread thread :timeout 2d0 :default nil))))

;; A real deadline interrupts an otherwise empty mailbox.
(let* ((controller (ataxia.assistant::%make-assistant-controller))
       (start (%now)) (failure nil))
  (setf (gethash 1 (ataxia.assistant::assistant-controller-pending controller))
        (list #'identity (+ start .05d0) "fixture-timeout"))
  (let ((thread (sb-thread:make-thread
                 (lambda ()
                   (handler-case (ataxia.assistant::%assistant-worker-loop controller 0 (ataxia.assistant::assistant-controller-wake controller))
                     (error (cause) (setf failure (princ-to-string cause))))))))
    (unwind-protect
         (progn
           (sb-thread:join-thread thread :timeout 2d0 :default nil)
           (assert (and failure (search "fixture-timeout" failure)))
           (assert (>= (- (%now) start) .04d0)))
      (setf (ataxia.assistant::assistant-controller-alive controller) nil)
      (sb-thread:signal-semaphore (ataxia.assistant::assistant-controller-wake controller))
      (sb-thread:join-thread thread :timeout 2d0 :default nil))))

;; Startup and task deadlines compete with RPCs; inactive work has no deadline.
(let ((ataxia.assistant::*assistant-time-limit* 100d0)
      (controller (ataxia.assistant::%make-assistant-controller :voice-active t :microphone :starting
                                              :voice-started-at 10d0 :turn-id "turn"
                                              :blocked nil :started 0d0)))
  (assert (= 5d0 (ataxia.assistant::%assistant-worker-timeout controller 25d0)))
  (setf (ataxia.assistant::assistant-controller-microphone controller) :listening)
  (assert (= 75d0 (ataxia.assistant::%assistant-worker-timeout controller 25d0)))
  (setf (ataxia.assistant::assistant-controller-turn-id controller) nil)
  (assert (null (ataxia.assistant::%assistant-worker-timeout controller 25d0))))

;; Each task expires once; a later task and coincident voice deadline still run.
(let* ((ataxia.assistant::*assistant-time-limit* 100d0)
       (controller (ataxia.assistant::%make-assistant-controller :turn-id "turn" :started 0d0))
       (names '(ataxia.assistant::%assistant-owner ataxia.assistant::%assistant-pause ataxia.assistant::%assistant-voice-close ataxia.assistant::%assistant-state))
       (originals (mapcar #'symbol-function names))
       (pauses 0) (voice-closes 0))
  (unwind-protect
       (progn
         (setf (symbol-function 'ataxia.assistant::%assistant-owner)
               (lambda (c function) (assert (eq c controller)) (funcall function))
               (symbol-function 'ataxia.assistant::%assistant-pause)
               (lambda (c reason) (declare (ignore reason))
                 (incf pauses) (setf (ataxia.assistant::assistant-controller-blocked c) t))
               (symbol-function 'ataxia.assistant::%assistant-voice-close)
               (lambda (c) (incf voice-closes) (setf (ataxia.assistant::assistant-controller-voice-active c) nil))
               (symbol-function 'ataxia.assistant::%assistant-state)
               (lambda (&rest args) (declare (ignore args))))
         (let ((expired (ataxia.assistant::%assistant-check-deadlines controller 100d0)))
           (assert (= 1 pauses))
           (assert (null (ataxia.assistant::%assistant-worker-timeout controller 150d0 expired)))
           (assert (= expired (ataxia.assistant::%assistant-check-deadlines controller 150d0 expired)))
           (assert (= 1 pauses))
           (setf (ataxia.assistant::assistant-controller-started controller) 60d0)
           (assert (= 10d0 (ataxia.assistant::%assistant-worker-timeout controller 150d0 expired)))
           (setf expired (ataxia.assistant::%assistant-check-deadlines controller 160d0 expired))
           (assert (= 2 pauses))
           (setf (ataxia.assistant::assistant-controller-voice-active controller) t
                 (ataxia.assistant::assistant-controller-microphone controller) :starting
                 (ataxia.assistant::assistant-controller-voice-started-at controller) 140d0)
           (ataxia.assistant::%assistant-check-deadlines controller 160d0 expired)
           (assert (= 2 pauses))
           (assert (= 1 voice-closes))))
    (loop for name in names for original in originals
          do (setf (symbol-function name) original))))

;; Producers racing with the drain cannot lose the empty-to-nonempty wake.
(let* ((controller (ataxia.assistant::%make-assistant-controller))
       (completed (sb-thread:make-semaphore))
       (received (make-array 256 :initial-element nil))
       (worker nil) (producers nil) (failure nil))
  (dotimes (i 256)
    (let ((index i))
      (setf (gethash (1+ i) (ataxia.assistant::assistant-controller-pending controller))
            (list (lambda (value error)
                    (assert (null error)) (assert (= index value))
                    (setf (aref received index) t)
                    (sb-thread:signal-semaphore completed))
                  (+ (%now) 60d0) "concurrent-message"))))
  (unwind-protect
       (progn
         (setf worker (sb-thread:make-thread
                       (lambda ()
                         (handler-case
                             (ataxia.assistant::%assistant-worker-loop controller 0 (ataxia.assistant::assistant-controller-wake controller))
                           (error (cause) (setf failure cause))))))
         (dotimes (producer 4)
           (let ((base (* producer 64)))
             (push (sb-thread:make-thread
                    (lambda ()
                      (dotimes (i 64)
                        (ataxia.assistant::%assistant-queue controller :message
                          (ataxia.assistant::%assistant-object "id" (+ base i 1) "result" (+ base i)))
                        (sb-thread:thread-yield)))) producers)))
         (dotimes (i 256)
           (assert (sb-thread:wait-on-semaphore completed :timeout 2d0)))
         (assert (every #'identity received))
         (assert (null failure)))
    (dolist (thread producers) (sb-thread:join-thread thread :timeout 2d0 :default nil))
    (setf (ataxia.assistant::assistant-controller-alive controller) nil)
    (sb-thread:signal-semaphore (ataxia.assistant::assistant-controller-wake controller))
    (when worker (sb-thread:join-thread worker :timeout 2d0 :default nil))))

(format t "PASS: coalesced FIFO wakeups, no idle polling, prompt delivery/reset, RPC and voice/task deadlines.~%")
