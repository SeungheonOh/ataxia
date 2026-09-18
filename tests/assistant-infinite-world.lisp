;;;; Full assistant and shell lifecycle on plain Infinite World, without Metaworld.
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-assistant/infinite-world")

(defpackage #:ataxia.test.assistant-infinite
  (:use #:cl #:ataxia.world)
  (:local-nicknames (#:assistant #:ataxia.assistant) (#:cu #:ataxia.computer-use)))
(in-package #:ataxia.test.assistant-infinite)
(assert (not (find-class (find-symbol "METAWORLD" :ataxia.infinite-world) nil)))
(setf assistant::*assistant-command*
      (list "env" "ATAXIA_EXPECTED_TOOLS=6" "sbcl" "--noinform" "--disable-debugger" "--script"
            (namestring (asdf:system-relative-pathname "ataxia-assistant" "tests/assistant-mock-codex.lisp"))))

(let* ((world (ataxia.infinite-world:make-infinite-world))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                            :headless-width 1100 :headless-height 800))
       (runtime (ataxia.kernel:kernel-runtime kernel))
       (control nil) (controller nil) (phase 0) (frames 0) (baseline 0)
       (original (symbol-function 'ataxia.kernel::%render-output-frame)))
  (unwind-protect
       (progn
         (setf (symbol-function 'ataxia.kernel::%render-output-frame)
               (lambda (output) (incf frames) (funcall original output)))
         (ataxia.kernel:start-kernel kernel)
         (setf control (ataxia.sly-control:start-sly-control kernel :port nil))
         (ataxia.world.shell:enable-rmlui-status-bar world)
         (setf controller (assistant:enable world))
         (assert (= 1 (length (ataxia.world.shell:status-bars world))))
         (assert (not (world-supports-p world :layout)))
         (assert (world-service world :shell))
         (assert (world-service world :computer-use))
         (assert (world-service world :assistant))
         ;; Service-owned shortcuts work without changing the World's bindings.
         (let ((seat (first (world-seats world))))
           (dolist (state '(:pressed :released))
             (ataxia.kernel:world-key-event
              world seat (ataxia.kernel:make-key-input :keycode 30 :keysyms #("a")
                                                      :modifiers '(:logo) :state state))))
         (assert (assistant::assistant-controller-panel controller))
         (assistant:submit world "Inspect this isolated desktop.")
         (let ((timer
                 (ataxia.runtime:add-event-loop-timer
                  runtime
                  (lambda (source)
                    (case phase
                      (0
                       (when (member (assistant::assistant-controller-task controller) '(:done :failed))
                         (assert (eq :done (assistant::assistant-controller-task controller)) ()
                                 "~A" (assistant::assistant-controller-activity controller))
                         (assert (eq :ready (assistant::assistant-controller-connection controller)))
                         (assert (eq :paused (cu:computer-session-state
                                             (assistant::assistant-controller-session controller))))
                         ;; A focused text caret and clock deadline are active
                         ;; UI work. Exclude them from this bounded idle sample.
                         (assistant::%assistant-close-panel controller)
                         (ataxia.runtime:update-event-loop-timer
                          (ataxia.world.shell::shell-service-timer (world-service world :shell)) 0)
                         (setf phase 1)))
                      (1 (setf baseline frames phase 2))
                      (2
                       (assert (= baseline frames))
                       (assistant:disable world)
                       (cu:disable world)
                       (ataxia.world.shell:disable-rmlui-status-bar world)
                       (dolist (key '(:assistant :computer-use :shell))
                         (assert (null (world-service world key))))
                       (setf phase 3)))
                    (ataxia.runtime:update-event-loop-timer source
                                                           (case phase (0 50) (1 1000) (2 300) (t 0)))
                    0))))
           (ataxia.runtime:update-event-loop-timer timer 50))
         (ataxia.kernel:run-kernel kernel :run-for 5d0)
         (assert (= 3 phase))
         (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
         (format t "PASS: assistant, native session, shell, shortcuts, mock tool call, idle rendering and cleanup on plain Infinite World.~%"))
    (setf (symbol-function 'ataxia.kernel::%render-output-frame) original)
    (when control (ataxia.sly-control:stop-sly-control control))
    (ataxia.kernel:destroy-kernel kernel :portable-assistant-test-complete)))
