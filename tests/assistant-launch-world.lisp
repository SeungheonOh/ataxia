;;;; A catalog entry named Firefox starts a disposable native test client.
;;;; Set ATAXIA_TEST_CODEX=1 to exercise discovery/launch/verification by a real
;;;; model as well; the normal suite directly exercises the same public tools.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-assistant/metaworld")
(in-package #:ataxia.infinite-world)
(let* ((world (make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless :headless-width 1000 :headless-height 700))
       (root (merge-pathnames (format nil "ataxia-launch-test-~A/" (ataxia.computer-use::random-token)) (uiop:temporary-directory)))
       (entry (merge-pathnames "applications/firefox_fixture.desktop" root))
       (real (equal "1" (uiop:getenv "ATAXIA_TEST_CODEX")))
       (controller nil) (control nil) (worker nil) (done nil) (failure nil))
  (labels ((owner (f) (ataxia.sly-control:agent-inspect (lambda (k w) (declare (ignore k w)) (funcall f)) :timeout 5d0))
           (observe () (ataxia.assistant::%assistant-run-tool controller "ataxia_observe" (ataxia.assistant::%assistant-object)))
           (fixture-window () (find "ataxia.agent-test" (ataxia.world:world-windows world)
                                     :key (lambda (window) (ataxia.kernel:application-app-id (canvas-window-application window))) :test #'equal)))
    (unwind-protect
         (progn
           (ensure-directories-exist entry)
           (with-open-file (out entry :direction :output)
             (format out "[Desktop Entry]~%Type=Application~%Name=Firefox~%Exec=env ATAXIA_TEST_SECONDS=90 ATAXIA_TEST_TITLE=Firefox ~A ~A~%"
                     (asdf:system-relative-pathname "ataxia-assistant" "build/computer-use-client")
                     (merge-pathnames "client.log" root)))
           (ataxia.kernel:start-kernel kernel)
           (setf control (ataxia.sly-control:start-sly-control kernel :port nil)
                 controller (ataxia.assistant::%assistant-enable world :project (namestring root))
                 (ataxia.assistant::assistant-controller-seat controller) (%canvas-seat-seat (first (%seat-states world))))
           (setf (%launcher-desktop-entries (%launcher-for-output world (first (ataxia.world:world-outputs world))))
                 (%load-desktop-entries (list root)))
           (if real
               (ataxia.assistant::%assistant-submit controller "Open Firefox and verify that its window appeared. This isolated desktop's Firefox catalog entry is a disposable test client. Use ataxia_lisp to discover the catalog, launch and verify via the public World protocol. Do not use native input/capture, shell commands, files or external tools. Finish with one short sentence.")
               (ataxia.assistant::%assistant-start-task controller))
           (setf worker
                 (sb-thread:make-thread
                  (lambda ()
                    (handler-case
                        (progn
                          (if real
                              (loop repeat 700
                                    when (owner (lambda () (member (ataxia.assistant::assistant-controller-task controller) '(:done :failed :needs-input))))
                                      do (return)
                                    do (sleep .1d0)
                                    finally (error "Real model launch timed out."))
                              (let ((inventory (observe)))
                                (assert (null (getf inventory :image)))
                                (assert (find "firefox_fixture" (getf inventory :applications) :key (lambda (app) (getf app :id)) :test #'equal))
                                (let ((result
                                        (ataxia.assistant::%assistant-run-tool controller "ataxia_act"
                                          (ataxia.assistant::%assistant-object "capture" :false "actions"
                                            (vector (ataxia.assistant::%assistant-object "op" "launch" "application" "firefox_fixture")
                                                    (ataxia.assistant::%assistant-object "op" "wait-window" "app-id" "ataxia.agent-test" "timeout" 10))))))
                                  (assert (eq t (getf result :ok)))
                                  (assert (= 2 (getf result :completed))))))
                          (owner (lambda ()
                                   (when real
                                     (assert (eq :done (ataxia.assistant::assistant-controller-task controller)) ()
                                             "Model launch failed: ~A" (ataxia.assistant::assistant-controller-activity controller))
                                     (assert (plusp (ataxia.assistant::assistant-controller-tool-count controller)))
                                     (assert (null (ataxia.assistant::assistant-controller-session controller))))
                                   (assert (= 1 (length (ataxia.world:world-windows world))))
                                   (assert (fixture-window))))
                          (unless real
                            (let* ((id (owner (lambda () (ataxia.kernel:object-id (canvas-window-application (fixture-window))))))
                                   (snapshot (ataxia.assistant::%assistant-run-tool controller "ataxia_observe" (ataxia.assistant::%assistant-object "window" id))))
                              (assert (getf snapshot :image))
                              ;; Discovery remains lightweight even after selecting an app.
                              (assert (null (getf (observe) :image)))))
                          (format t "PASS: ~A discovered Firefox in the catalog, launched once, and verified its mapped native window.~%"
                                  (if real "Real Codex" "Assistant tools"))
                          (setf done t))
                      (error (cause) (setf failure cause done t)))) :name "Assistant launch check"))
           (ataxia.kernel:run-kernel kernel :run-for (if real 80d0 8d0))
           (assert done)
           (when failure (error failure)))
      (when controller (ataxia.assistant::%assistant-disable world))
      (when control (ataxia.sly-control:stop-sly-control control))
      (ataxia.kernel:destroy-kernel kernel :assistant-launch-test-complete)
      (when (and worker (sb-thread:thread-alive-p worker)) (sb-thread:terminate-thread worker))
      (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore))))
