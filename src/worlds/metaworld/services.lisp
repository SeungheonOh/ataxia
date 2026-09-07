(in-package #:ataxia.infinite-world)

(defvar *meta-launch-mailbox* nil)
(defvar *meta-launch-wakeup* (sb-thread:make-semaphore :count 0))
(defvar *meta-launch-worker* nil)
(defvar *meta-launch-sequence* 0)

(defstruct (%meta-launch (:constructor %make-meta-launch))
  expires app-id group-id below-id workspace)

(defun %meta-queue-launch (command)
  ;; Bounded FIFO, immutable copied arguments. Process creation and filesystem
  ;; lookup happen on the worker, never in an input or render callback.
  (let ((copy (mapcar #'copy-seq command)))
    (loop for old = *meta-launch-mailbox*
          when (>= (length old) 16) return nil
          when (eq old (sb-ext:compare-and-swap *meta-launch-mailbox* old (cons copy old)))
            do (when (null old) (sb-thread:signal-semaphore *meta-launch-wakeup*))
               (return t))))

(defun %meta-launch-worker-loop ()
  (loop
    (sb-thread:wait-on-semaphore *meta-launch-wakeup*)
    (let ((batch (loop for old = *meta-launch-mailbox*
                       when (eq old (sb-ext:compare-and-swap *meta-launch-mailbox* old nil))
                         return old)))
      (dolist (command (reverse batch))
        (handler-case
            (uiop:launch-program command :input #P"/dev/null" :output #P"/dev/null"
                                        :error-output #P"/dev/null" :wait nil)
          (serious-condition (cause)
            (format *error-output* "[metaworld] Terminal launch failed: ~A~%" cause)))))))

(unless (and *meta-launch-worker* (sb-thread:thread-alive-p *meta-launch-worker*))
  (setf *meta-launch-worker*
        (sb-thread:make-thread #'%meta-launch-worker-loop :name "Ataxia terminal launcher")))
