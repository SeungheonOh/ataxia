;;;; Custom UIs are separate processes and windows, with native editable input.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-assistant/metaworld")
(in-package #:ataxia.infinite-world)
(let* ((world (make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless :headless-width 1100 :headless-height 800))
       (project (merge-pathnames (format nil "ataxia-notepad-test-~A/" (ataxia.computer-use::random-token)) (uiop:temporary-directory)))
       (control nil) (controller nil) (worker nil) (done nil) (failure nil))
  (labels ((owner (f)
             (ataxia.sly-control:agent-inspect (lambda (k w) (declare (ignore k w)) (funcall f)) :timeout 5d0))
           (bytes (path)
             (with-open-file (stream path :element-type '(unsigned-byte 8))
               (let ((data (make-array (file-length stream) :element-type '(unsigned-byte 8))))
                 (read-sequence data stream) data))))
    (unwind-protect
         (progn
           (ensure-directories-exist project)
           (uiop:copy-file (asdf:system-relative-pathname "ataxia-assistant" "examples/assistant/notepad.rml")
                           (merge-pathnames "notepad.rml" project))
           (ataxia.kernel:start-kernel kernel)
           (setf control (ataxia.sly-control:start-sly-control kernel :port nil)
                 controller (ataxia.assistant::%assistant-enable world :project (namestring project))

                 (ataxia.assistant::assistant-controller-seat controller) (%canvas-seat-seat (first (%seat-states world))))
           (ataxia.assistant::%assistant-start-task controller)
           (setf worker
                 (sb-thread:make-thread
                  (lambda ()
                    (handler-case
                        (let* ((first (ataxia.assistant::%assistant-run-tool controller "ataxia_ui_preview"
                                        (ataxia.assistant::%assistant-object "path" "notepad.rml" "width" 640 "height" 480)))
                               (before (bytes (getf (getf first :image) :path)))
                               (first-preview (gethash (getf first :preview) (ataxia.assistant::assistant-controller-previews controller)))
                               (second (ataxia.assistant::%assistant-run-tool controller "ataxia_ui_preview"
                                         (ataxia.assistant::%assistant-object "path" "notepad.rml" "width" 320 "height" 360)))
                               (second-preview (gethash (getf second :preview) (ataxia.assistant::assistant-controller-previews controller))))
                          (assert (and (integerp (getf first :pid)) (plusp (getf first :pid))))
                          (assert (/= (getf first :pid) (getf second :pid) (sb-posix:getpid)))
                          (assert (/= (getf first :window) (getf second :window)))
                          ;; Captures survive the backend replacing its temporary PNG.
                          (let* ((typed (ataxia.assistant::%assistant-run-tool controller "ataxia_lisp"
                                          (ataxia.assistant::%assistant-object "mode" "worker" "code"
                                            (format nil "(progn (ataxia.agent:capture-window agent ~D) (ataxia.agent:click agent ~D 60 125) (ataxia.agent:type-text agent ~D ~S) (ataxia.agent:capture-window agent ~D))"
                                                    (getf first :window) (getf first :window) (getf first :window)
                                                    (format nil "First line~%Second line") (getf first :window)))))
                                 (captures (getf typed :images))
                                 (after (getf (second captures) :bytes)))
                            (assert (= 2 (length captures)))
                            (assert (not (equalp before after)))
                            (assert (not (equalp (getf (first captures) :bytes) after)))
                            (let* ((response (ataxia.assistant::%assistant-tool-result typed))
                                   (items (gethash "contentItems" response)))
                              (assert (= 3 (length items)))
                              (assert (every (lambda (item) (equal "inputImage" (gethash "type" item))) (subseq items 0 2))))
                            (with-open-file (out (asdf:system-relative-pathname "ataxia-assistant" "build/assistant-notepad-wayland.png")
                                                 :direction :output :if-exists :supersede :element-type '(unsigned-byte 8))
                              (write-sequence after out)))
                          (owner (lambda () (ataxia.world:control-world-window world
                                              (ataxia.world:find-world-window world (getf first :window)) :close
                                              (first (ataxia.world:world-outputs world)))))
                          (loop repeat 100 while (uiop:process-alive-p (ataxia.assistant::assistant-preview-process first-preview)) do (sleep .05d0))
                          (assert (not (uiop:process-alive-p (ataxia.assistant::assistant-preview-process first-preview))))
                          (assert (uiop:process-alive-p (ataxia.assistant::assistant-preview-process second-preview)))
                          (owner (lambda () (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))))
                          (format t "PASS: two notepads have distinct processes and windows, native editing changes the document, closing one preserves the other and compositor.~%")
                          (setf done t))
                      (error (cause) (setf failure cause done t))))
                  :name "Notepad process and input test"))
           (ataxia.kernel:run-kernel kernel :run-for 14d0)
           (assert done)
           (when failure (error failure)))
      (when controller (ataxia.assistant::%assistant-disable world))
      (when control (ataxia.sly-control:stop-sly-control control))
      (ataxia.kernel:destroy-kernel kernel :assistant-notepad-test-complete)
      (when (and worker (sb-thread:thread-alive-p worker)) (sb-thread:terminate-thread worker))
      (uiop:delete-directory-tree project :validate t :if-does-not-exist :ignore))))
