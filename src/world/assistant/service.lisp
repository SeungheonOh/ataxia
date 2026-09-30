;;;; World attachment, shortcuts and lifecycle events for the assistant service.
(in-package #:ataxia.assistant)

(defun %assistant-bind-bar (controller bar)
  (let ((world (assistant-controller-world controller)))
    (ataxia.world.shell:set-shell-style bar "assistant" "display" "block")
    (ataxia.world.shell:set-shell-text bar "assistant" (%assistant-label controller))
    (bind-agent-widget-event
     bar "assistant"
     (lambda (widget event)
       (declare (ignore event))
       ;; A retained bar must not keep a disabled conversation alive.
       (let ((current (world-service world :assistant)))
         (when current
           (%assistant-ui-call
            current
            (lambda ()
              (%assistant-open current (world-seat-on-output world (overlay-output widget)))))))))))

(defun %assistant-install-shortcuts (controller)
  (dolist (entry '((:assistant-open "a" (:logo))
                   (:assistant-talk "A" (:logo :shift))))
    (destructuring-bind (id key modifiers) entry
      (add-shortcut
       (assistant-controller-shortcuts controller)
       (make-shortcut-binding
        :id id :key (list :keysym key) :modifiers modifiers
        :press-handler
        (lambda (world seat input)
          (declare (ignore world input))
          (%assistant-ui-call
           controller
           (lambda ()
             (%assistant-open controller seat)
             (when (eq id :assistant-talk) (%assistant-toggle-talk controller))))))
       :if-exists :replace)))
  (%assistant-install-dismiss-shortcut controller))

(defun %assistant-start-controller (controller)
  (let* ((world (assistant-controller-world controller))
         (runtime (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))))
    (setf (assistant-controller-timer controller)
          (ataxia.runtime:add-event-loop-timer
           runtime (lambda (source)
                     (declare (ignore source))
                     (%assistant-refresh controller t)
                     0)))
    (dolist (bar (status-bars world)) (%assistant-bind-bar controller bar))
    (%assistant-install-shortcuts controller)
    (%assistant-refresh controller t)))

(defun %assistant-enable (world &key project)
  (require-world-capabilities world :ui :desktop :window-capture)
  (or (world-service world :assistant)
      (let* ((kernel (ataxia.kernel:world-kernel world))
             (existing-input (world-service world :computer-use))
             (controller
               (%make-assistant-controller
                :world world :generation (ataxia.kernel:kernel-world-generation kernel)
                :project (namestring (uiop:ensure-directory-pathname
                                     (or project (user-homedir-pathname))))))
             (started nil))
        (cu:enable world :start-server nil)
        (attach-world-service world :assistant controller)
        (unwind-protect
             (progn
               (%assistant-start-controller controller)
               (setf started t)
               controller)
          (unless started
            (unwind-protect (%assistant-disable world)
              ;; Roll back only the dependency created by this failed enable.
              (unless existing-input (cu:disable world))))))))

(defun %assistant-disable (world)
  (let ((controller (world-service world :assistant)))
    (when controller
      (%assistant-stop controller)
      (%assistant-close-panel controller)
      (%assistant-close-previews controller)
      (setf (assistant-controller-alive controller) nil)
      (incf (assistant-controller-epoch controller))
      (when (assistant-controller-process controller)
        (ignore-errors (uiop:terminate-process (assistant-controller-process controller))))
      (sb-thread:signal-semaphore (assistant-controller-wake controller))
      (when (assistant-controller-timer controller)
        (ataxia.runtime:remove-event-loop-source (assistant-controller-timer controller))
        (setf (assistant-controller-timer controller) nil))
      (clear-shortcuts (assistant-controller-shortcuts controller))
      (dolist (bar (status-bars world))
        (ataxia.world.shell:set-shell-style bar "assistant" "display" "none"))
      (detach-world-service world :assistant)))
  world)

(defmethod initialize-status-bar-controls
    ((world ataxia.kernel:world) (bar shell-status-bar))
  (let ((controller (world-service world :assistant)))
    (when controller (%assistant-bind-bar controller bar))))

(defmethod service-quiescing ((controller assistant-controller) world reason)
  (declare (ignore reason))
  (%assistant-disable world))

(defmethod service-output-removing ((controller assistant-controller) world output)
  (declare (ignore world))
  (when (or (eq output (assistant-controller-output controller))
            (and (assistant-controller-panel controller)
                 (eq output (overlay-output (assistant-controller-panel controller)))))
    (%assistant-stop controller)
    (%assistant-close-panel controller)))

(defmethod service-output-changed ((controller assistant-controller) world output change)
  (declare (ignore world output))
  (unless (eq :backend-damage (ataxia.kernel:object-change-kind change))
    (%assistant-refresh controller)))

(defmethod service-key-event ((controller assistant-controller) world seat input)
  (eq :consumed (handle-shortcut-input (assistant-controller-shortcuts controller) world seat input)))

(defmethod service-seat-removing ((controller assistant-controller) world seat)
  (declare (ignore world))
  (forget-shortcut-seat (assistant-controller-shortcuts controller) seat))

(defmethod cu:emergency-stop :after ((world ataxia.kernel:world))
  (let ((controller (world-service world :assistant)))
    (when controller (%assistant-pause controller "Paused · emergency shortcut"))))

(defmethod cu:session-state-changed :after ((session cu:computer-session))
  (let ((controller (world-service (cu:computer-session-world session) :assistant)))
    (when (and controller (eq session (assistant-controller-session controller))
               (eq :working (assistant-controller-task controller))
               (not (assistant-controller-blocked controller))
               (member (cu:computer-session-state session) '(:paused :closed)))
      (%assistant-pause controller (cu:computer-session-message session)))))

(defun enable (world &key project) (%assistant-enable world :project project))
(defun disable (world) (%assistant-disable world))
(defun open-panel (world &optional seat) (%assistant-open (enable world) seat))
(defun submit (world text) (%assistant-submit (enable world) text))
(defun pause (world) (%assistant-pause (enable world)))
(defun stop (world) (%assistant-stop (enable world)))
