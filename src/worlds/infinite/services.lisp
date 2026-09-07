(in-package #:ataxia.infinite-world)

(defvar *program-launch-mailbox* nil)
(defvar *program-launch-wakeup* (sb-thread:make-semaphore :count 0))
(defvar *program-launch-worker* nil)

(defun %queue-program-launch (command)
  ;; Bounded FIFO, immutable copied arguments. Process creation and filesystem
  ;; lookup happen on the worker, never in an input or render callback.
  (let ((copy (mapcar #'copy-seq command)))
    (loop for old = *program-launch-mailbox*
          when (>= (length old) 16) return nil
          when (eq old (sb-ext:compare-and-swap *program-launch-mailbox* old (cons copy old)))
            do (when (null old) (sb-thread:signal-semaphore *program-launch-wakeup*))
               (return t))))

(defun %program-launch-worker-loop ()
  (loop
    (sb-thread:wait-on-semaphore *program-launch-wakeup*)
    (let ((batch (loop for old = *program-launch-mailbox*
                       when (eq old (sb-ext:compare-and-swap *program-launch-mailbox* old nil))
                         return old)))
      (dolist (command (reverse batch))
        (handler-case
            (uiop:launch-program command :input #P"/dev/null" :output #P"/dev/null"
                                        :error-output :interactive :wait nil)
          (serious-condition (cause)
            (format *error-output* "[infinite-world] Application launch failed: ~A~%" cause)))))))

(unless (and *program-launch-worker* (sb-thread:thread-alive-p *program-launch-worker*))
  (setf *program-launch-worker*
        (sb-thread:make-thread #'%program-launch-worker-loop :name "Ataxia application launcher")))
