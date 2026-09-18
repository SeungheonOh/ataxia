;;;; Explicit opt-in integration check against the installed, signed-in Codex CLI.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-assistant/metaworld")
(in-package #:ataxia.infinite-world)
(unless (equal "1" (uiop:getenv "ATAXIA_TEST_CODEX")) (error "Set ATAXIA_TEST_CODEX=1 to run a real model turn."))
(let* ((world (make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless :headless-width 1100 :headless-height 800))
       (project (merge-pathnames (format nil "ataxia-codex-test-~A/" (ataxia.computer-use::random-token)) (uiop:temporary-directory)))
       (controller nil) (control nil) (test-thread nil) (done nil) (failure nil))
  (unwind-protect
       (progn
         (ensure-directories-exist project)
         (ataxia.kernel:start-kernel kernel)
         (setf control (ataxia.sly-control:start-sly-control kernel :port nil))
         (setf controller (ataxia.assistant::%assistant-enable world :project (namestring project))
               (ataxia.assistant::assistant-controller-seat controller) (%canvas-seat-seat (first (%seat-states world))))
         (ataxia.assistant::%assistant-submit controller "This is an isolated integration test with an empty desktop. Call ataxia_desktop_snapshot exactly once, then reply with one short sentence stating how many groups it returned. Do not run shell commands, edit files, change the desktop, use other tools, or delegate to agents.")
         (setf test-thread
           (sb-thread:make-thread
            (lambda ()
              (handler-case
                  (loop repeat 600 do
                    (when (ataxia.sly-control:agent-inspect
                           (lambda (k w) (declare (ignore k w))
                             (when (member (ataxia.assistant::assistant-controller-task controller) '(:done :failed :needs-input))
                               (assert (eq :done (ataxia.assistant::assistant-controller-task controller)) () "Codex integration: ~A" (ataxia.assistant::assistant-controller-activity controller))
                               (assert (plusp (hash-table-count (ataxia.assistant::assistant-controller-seen-calls controller))))
                               (assert (some (lambda (m) (eq (getf m :role) :assistant)) (ataxia.assistant::assistant-controller-messages controller)))
                               (format t "PASS: installed Codex completed a real turn using the registered Ataxia desktop tool; public reply was received.~%")
                               (finish-output)
                               ;; Negotiate voice without opening any microphone or playback device.
                               (ataxia.assistant::%assistant-queue controller :rpc
                                 (list "thread/realtime/start"
                                   (ataxia.assistant::%assistant-object "threadId" (ataxia.assistant::assistant-controller-thread-id controller) "outputModality" "audio"
                                                      "version" "v2" "transport" (ataxia.assistant::%assistant-object "type" "websocket"))
                                   (lambda (result error)
                                     (declare (ignore result))
                                     (if error
                                         (format t "VOICE PROBE: backend unavailable: ~A~%" (ataxia.assistant::%assistant-field error "message"))
                                         (progn (format t "VOICE PROBE: realtime start accepted; no microphone was opened.~%")
                                                (ataxia.assistant::%assistant-rpc controller "thread/realtime/stop"
                                                  (ataxia.assistant::%assistant-object "threadId" (ataxia.assistant::assistant-controller-thread-id controller))
                                                  (lambda (r e) (declare (ignore r e))))))
                                     (finish-output))))
                               t)) :timeout 5d0)
                      (setf done t) (return))
                    (sleep .1d0)
                    finally (error "Codex integration timed out: ~A" (ataxia.assistant::assistant-controller-activity controller)))
                (error (cause) (setf failure cause done t)))) :name "Codex live protocol check"))
         (ataxia.kernel:run-kernel kernel :run-for 75d0)
         (assert done)
         (when failure (error failure)))
    (when controller (ataxia.assistant::%assistant-disable world))
    (when control (ataxia.sly-control:stop-sly-control control))
    (ataxia.kernel:destroy-kernel kernel :codex-integration-test-complete)
    (when (and test-thread (sb-thread:thread-alive-p test-thread)) (sb-thread:terminate-thread test-thread))
    (uiop:delete-directory-tree project :validate t :if-does-not-exist :ignore)))
