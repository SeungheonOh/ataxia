;;;; Exercise partial service startup and controller replacement with real UI/timers.
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-assistant/infinite-world")
(asdf:load-system "ataxia-rmlui/status-bar")

(defpackage #:ataxia.test.service-lifecycle
  (:use #:cl #:ataxia.world)
  (:local-nicknames (#:assistant #:ataxia.assistant)
                    (#:cu #:ataxia.computer-use)
                    (#:shell #:ataxia.world.shell)))
(in-package #:ataxia.test.service-lifecycle)

(defun call-with-function (name replacement function)
  (let ((original (symbol-function name)))
    (unwind-protect
         (progn (setf (symbol-function name) replacement) (funcall function))
      (setf (symbol-function name) original))))

(defun expect-failure (function message)
  (let ((cause (handler-case (progn (funcall function) nil) (error (cause) cause))))
    (assert cause)
    (assert (search message (princ-to-string cause)))))

(defun assert-removed (world baseline)
  (assert (null (world-service world :computer-use)))
  (assert (equal baseline (world-overlays world))))

(let* ((world (ataxia.infinite-world:make-infinite-world))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                            :headless-width 1100 :headless-height 800))
       (retired-panels nil))
  (unwind-protect
       (progn
         (ataxia.kernel:start-kernel kernel)
         (shell:enable-rmlui-status-bar world)
         (let ((baseline (copy-list (world-overlays world))))
           ;; Failure before a timer exists must not call removal with NIL.
           (call-with-function
            'ataxia.runtime:add-event-loop-timer
            (lambda (&rest arguments)
              (declare (ignore arguments)) (error "Injected timer failure"))
            (lambda ()
              (expect-failure (lambda () (cu:enable world :start-server nil))
                              "Injected timer failure")))
           (assert-removed world baseline)

           ;; A later failure must release both the actual timer and attached UI.
           (let ((create-panels (symbol-function 'cu::%computer-create-panels))
                 (timer nil) (controller nil))
             (call-with-function
              'cu::%computer-create-panels
              (lambda (world)
                (funcall create-panels world)
                (setf controller (world-service world :computer-use)
                      timer (cu::computer-controller-timer controller)
                      retired-panels (copy-list (cu::computer-controller-panels controller)))
                (error "Injected panel failure"))
              (lambda ()
                (expect-failure (lambda () (cu:enable world :start-server nil))
                                "Injected panel failure")))
             (assert timer)
             (assert (not (ataxia.runtime:native-object-live-p timer)))
             (assert (null (cu::computer-controller-timer controller)))
             (assert (null (cu::computer-controller-panels controller))))
           (assert-removed world baseline)

           ;; Listener failure rolls back a new controller, but preserves an
           ;; already enabled service and its sessions for other callers.
           (let ((invalid-path (make-string 120 :initial-element #\a)))
             (expect-failure (lambda () (cu:enable world :socket invalid-path))
                             "socket path is invalid")
             (assert-removed world baseline)
             (let* ((controller (cu:enable world :start-server nil))
                    (session (cu:connect-session world "Existing caller" "Keep this session"
                                                 (first (world-outputs world))))
                    (timer (cu::computer-controller-timer controller)))
               (expect-failure (lambda () (cu:enable world :socket invalid-path))
                               "socket path is invalid")
               (assert (eq controller (world-service world :computer-use)))
               (assert (eq controller (cu:enable world :start-server nil)))
               (assert (ataxia.runtime:native-object-live-p timer))
               (assert (eq :active (cu:computer-session-state session)))
               ;; Automatic activation must report seat failure and keep other sessions usable.
               (call-with-function
                'ataxia.kernel:create-logical-seat
                (lambda (&rest arguments)
                  (declare (ignore arguments)) (error "Injected seat failure"))
                (lambda ()
                  (expect-failure
                   (lambda () (cu:connect-session world "Failed caller" "Test failed activation"
                                                  (first (world-outputs world))))
                   "Could not start this computer-use session.")))
               (assert (eq :active (cu:computer-session-state session)))
               (assert (eq :closed (cu:computer-session-state
                                    (car (last (cu::computer-controller-sessions controller))))))
               (cu:disable world)
               (assert (eq :closed (cu:computer-session-state session)))))
           (assert-removed world baseline))

         ;; Assistant rollback releases only dependencies it created itself.
         (dolist (keep-input '(nil t))
           (let ((existing (when keep-input (cu:enable world :start-server nil)))
                 (install (symbol-function 'assistant::%assistant-install-shortcuts))
                 (controller nil) (timer nil))
             (call-with-function
              'assistant::%assistant-install-shortcuts
              (lambda (candidate)
                (funcall install candidate)
                (setf controller candidate timer (assistant::assistant-controller-timer candidate))
                (error "Injected shortcut failure"))
              (lambda ()
                (expect-failure (lambda () (assistant:enable world))
                                "Injected shortcut failure")))
             (assert (null (world-service world :assistant)))
             (assert (eq existing (world-service world :computer-use)))
             (assert (not (assistant::assistant-controller-alive controller)))
             (assert (null (assistant::assistant-controller-timer controller)))
             (assert (not (ataxia.runtime:native-object-live-p timer)))
             (assert (null (list-shortcuts (assistant::assistant-controller-shortcuts controller))))
             (cu:disable world)))

         ;; A retained shell callback resolves the current service. It cannot
         ;; revive a disabled controller or open a panel in the old conversation.
         (let* ((first (assistant:enable world))
                (bar (first (shell:status-bars world)))
                (component (overlay-component bar))
                (callback (gethash "assistant" (ataxia.world.rmlui::%component-callbacks component))))
           (assert (eq first (assistant:enable world)))
           (assistant:disable world)
           (funcall callback component "")
           (assert (null (assistant::assistant-controller-panel first)))
           (let ((second (assistant:enable world)))
             (assert (not (eq first second)))
             (funcall callback component "")
             (assert (assistant::assistant-controller-panel second))
             (assert (null (assistant::assistant-controller-panel first)))
             (assistant:disable world))
           (assistant:disable world)
           (cu:disable world)
           (cu:disable world))

         ;; Graphics retirement remains the host's responsibility.
         (ataxia.kernel:run-kernel kernel :run-for .2d0)
         (dolist (panel retired-panels)
           (assert (ataxia.world.web::%destroyed (overlay-component panel))))
         (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
         (format t "PASS: failed service startup releases timers/UI, preserves existing callers, and allows clean replacement.~%"))
    (ataxia.kernel:destroy-kernel kernel :service-lifecycle-test-complete)))
