;;;; Explicit opt-in integration check against the installed, signed-in Codex CLI.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-assistant/metaworld")
(in-package #:ataxia.infinite-world)
(unless (equal "1" (uiop:getenv "ATAXIA_TEST_CODEX")) (error "Set ATAXIA_TEST_CODEX=1 to run a real model turn."))
(setf ataxia.assistant::*assistant-idle-timeout* .5d0)
(let* ((world (make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless :headless-width 1100 :headless-height 800))
       (project (merge-pathnames (format nil "ataxia-codex-test-~A/" (ataxia.computer-use::random-token)) (uiop:temporary-directory)))
       (controller nil) (control nil) (test-thread nil) (done nil) (failure nil))
  (unwind-protect
       (progn
         (ensure-directories-exist (merge-pathnames "work/" project))
         (ataxia.kernel:start-kernel kernel)
         (setf control (ataxia.sly-control:start-sly-control kernel :port nil))
         (setf controller (ataxia.assistant::%assistant-enable world :project (namestring (merge-pathnames "work/" project)))
               (ataxia.assistant::assistant-controller-seat controller) (%canvas-seat-seat (first (%seat-states world))))
         (ataxia.assistant::%assistant-submit controller (format nil "Remember the phrase copper otter for the next turn. This is an isolated integration test with an empty desktop. Call ataxia_desktop_snapshot exactly once, then call ataxia_lisp with mode inspect and code (length (ataxia.world:world-windows world)). Use a shell command to write exactly full-access into the disposable fixture file ~A, which is outside the working directory. Reply with one short sentence stating how many windows there are. Do not change other files, change the desktop, or delegate to agents." (namestring (merge-pathnames "outside-cwd.txt" project))))
         (setf test-thread
           (sb-thread:make-thread
            (lambda ()
              (handler-case
                  (loop repeat 600 do
                    (when (ataxia.sly-control:agent-inspect
                           (lambda (k w) (declare (ignore k w))
                             (when (member (ataxia.assistant::assistant-controller-task controller) '(:done :failed :needs-input))
                               (assert (eq :done (ataxia.assistant::assistant-controller-task controller)) () "Codex integration: ~A" (ataxia.assistant::assistant-controller-activity controller))
                               (assert (equal "full-access" (string-trim '(#\Space #\Newline #\Return) (uiop:read-file-string (merge-pathnames "outside-cwd.txt" project)))))
                               (assert (>= (hash-table-count (ataxia.assistant::assistant-controller-seen-calls controller)) 2))
                               (assert (some (lambda (m) (eq (getf m :role) :assistant)) (ataxia.assistant::assistant-controller-messages controller)))
                               (format t "PASS: installed Codex completed a real turn using World discovery, live Lisp and a shell write outside cwd without approvals.~%")
                               (finish-output)
                               t)) :timeout 5d0)
                      (let ((thread-id (ataxia.assistant::assistant-controller-thread-id controller))
                            (process (ataxia.assistant::assistant-controller-process controller))
                            (worker (ataxia.assistant::assistant-controller-worker controller)))
                        (loop repeat 200 until (eq :sleeping (ataxia.assistant::assistant-controller-connection controller))
                              do (sleep .05d0)
                              finally (assert (eq :sleeping (ataxia.assistant::assistant-controller-connection controller))))
                        (sb-thread:join-thread worker :timeout 5d0 :default :stuck)
                        (assert (not (uiop:process-alive-p process)))
                        (ataxia.sly-control:agent-inspect
                         (lambda (k w) (declare (ignore k w))
                           (ataxia.assistant::%assistant-submit controller
                             "Call ataxia_lisp with mode inspect and code (length (ataxia.world:world-windows world)). Reply only with the remembered phrase and window count. Do not run other tools or delegate.")))
                        (loop repeat 900
                              when (member (ataxia.assistant::assistant-controller-task controller) '(:done :failed :needs-input)) return t
                              do (sleep .1d0)
                              finally (error "Resumed model turn timed out"))
                        (ataxia.sly-control:agent-inspect
                         (lambda (k w) (declare (ignore k w))
                           (assert (eq :done (ataxia.assistant::assistant-controller-task controller)))
                           (assert (equal thread-id (ataxia.assistant::assistant-controller-thread-id controller)))
                           (assert (plusp (hash-table-count (ataxia.assistant::assistant-controller-seen-calls controller))))
                           (assert (search "copper otter" (string-downcase
                             (getf (car (last (ataxia.assistant::assistant-controller-messages controller))) :text))))))
                        (format t "PASS: real Codex child exited idle; a replacement resumed the same thread, remembered context and called live Lisp.~%")
                        (finish-output))
                      (setf done t) (return))
                    (sleep .1d0)
                    finally (error "Codex integration timed out: ~A" (ataxia.assistant::assistant-controller-activity controller)))
                (error (cause) (setf failure cause done t)))) :name "Codex live protocol check"))
         (ataxia.kernel:run-kernel kernel :run-for 100d0)
         (assert done)
         (when failure (error failure))
         (when (ataxia.assistant::assistant-controller-voice-error controller)
           (format t "VOICE BACKEND: ~A~%" (ataxia.assistant::assistant-controller-activity controller))))
    (when controller (ataxia.assistant::%assistant-disable world))
    (when control (ataxia.sly-control:stop-sly-control control))
    (ataxia.kernel:destroy-kernel kernel :codex-integration-test-complete)
    (when (and test-thread (sb-thread:thread-alive-p test-thread)) (sb-thread:terminate-thread test-thread))
    (uiop:delete-directory-tree project :validate t :if-does-not-exist :ignore)))
