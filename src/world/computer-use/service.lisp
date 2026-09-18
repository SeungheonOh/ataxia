;;;; Attach one computer-use controller and release its resources as a unit.
(in-package #:ataxia.computer-use)

(defun %computer-start-controller (controller)
  (let* ((world (computer-controller-world controller))
         (runtime (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))))
    (setf (computer-controller-timer controller)
          (ataxia.runtime:add-event-loop-timer
           runtime (lambda (source)
                     (declare (ignore source))
                     (%computer-tick controller))))
    (%computer-create-panels world)))

(defun enable (world &key (start-server t) socket)
  "Enable computer use, optionally starting its local request listener."
  (require-world-capabilities world :ui :desktop :window-capture)
  (let* ((existing (world-service world :computer-use))
         (controller (or existing (%make-computer-controller :world world)))
         (started nil))
    (unless existing
      (attach-world-service world :computer-use controller))
    (unwind-protect
         (progn
           (unless existing (%computer-start-controller controller))
           (when start-server (%computer-start-server world socket))
           (setf started t)
           controller)
      ;; An existing service may have active sessions owned by other callers.
      (unless (or started existing) (disable world)))))

(defun disable (world)
  "Close sessions and detach the service. Safe after partial initialization."
  (let ((controller (world-service world :computer-use)))
    (when controller
      (when (computer-controller-server controller)
        (%computer-stop-server controller))
      (dolist (session (computer-controller-sessions controller))
        (close-session session "Computer use disabled"))
      (when (computer-controller-timer controller)
        (ataxia.runtime:remove-event-loop-source (computer-controller-timer controller))
        (setf (computer-controller-timer controller) nil))
      (dolist (panel (computer-controller-panels controller))
        (remove-agent-widget world panel))
      (when (computer-controller-directory controller)
        (ignore-errors (sb-posix:rmdir (computer-controller-directory controller))))
      (setf (computer-controller-panels controller) nil
            (computer-controller-sessions controller) nil
            (computer-controller-directory controller) nil)
      (detach-world-service world :computer-use)))
  world)

(defmethod service-quiescing ((controller computer-controller) world reason)
  (declare (ignore reason))
  (disable world))

(defmethod service-output-removing ((controller computer-controller) world output)
  (declare (ignore world))
  (dolist (session (computer-controller-sessions controller))
    (when (eq output (computer-session-output session))
      (close-session session "Output disconnected")))
  (setf (computer-controller-panels controller)
        (remove output (computer-controller-panels controller) :key #'overlay-output)))
