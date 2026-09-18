;;;; Explicit window controls, separate from reversible layout transactions.
(in-package #:ataxia.assistant)

(defun %assistant-control-target (controller id)
  (%assistant-require-task controller)
  (unless (and (integerp id) (plusp id)) (error "Supply a stable application window ID."))
  (let* ((world (assistant-controller-world controller))
         (window (find id (world-windows world)
                       :key (lambda (w) (ataxia.kernel:object-id (window-application w))))))
    (unless (and window (ataxia.kernel:application-mapped-p (ataxia.world:window-application window)))
      (error "Window ~A is no longer open. Observe the desktop again." id))
    (ecase (assistant-controller-scope controller)
      (:desktop
       (unless (getf (assistant-controller-grant controller) :layout)
         (error "This task has no Desktop grant.")))
      (:application
       (unless (eql id (getf (assistant-controller-grant controller) :window))
         (error "This task is limited to the selected application.")))
      (:project
       (unless (%assistant-preview-window-p controller id)
         (error "Project window controls are limited to this assistant's previews."))))
    window))

(defun %assistant-control-window (controller arguments)
  (let* ((action (gethash "action" arguments))
         (world (assistant-controller-world controller))
         (window (%assistant-control-target controller (gethash "window" arguments)))
         (application (window-application window)))
    (unless (member action '("close" "minimize" "restore" "maximize" "fullscreen") :test #'equal)
      (error "Unknown window action. Use close, minimize, restore, maximize, or fullscreen."))
    (%assistant-layout-idle controller)
    (ataxia.world:control-world-window
     world window (intern (string-upcase action) :keyword) (assistant-controller-output controller))
    ;; These controls are not layout transactions. Never replay an earlier plan
    ;; or offer an Undo that could imply reopening a client after close.
    (clrhash (assistant-controller-plans controller))
    (setf (assistant-controller-undo controller) nil)
    (%assistant-refresh controller)
    (list :ok t :window (ataxia.kernel:object-id application) :action action
          :status (if (equal action "close") "close-requested" "applied")
          :message (if (equal action "close")
                       "Close requested. Observe again: the application may close or ask to save changes."
                       "Window state updated.")
          :snapshot (%assistant-layout-snapshot controller))))
