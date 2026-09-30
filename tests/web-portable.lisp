;;;; No Slint, RmlUi, Infinite World, or Metaworld loaded in this process.
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-web")
(asdf:load-system "ataxia-fullscreen-world")
(dolist (package '(:ataxia.infinite-world :ataxia.metaworld :ataxia.world.slint :ataxia.world.rmlui))
  (assert (not (find-package package))))
(defclass web-fixture-world (ataxia.fullscreen-world:fullscreen-world)
  ((component :initform nil :accessor fixture-component)))
(defmethod ataxia.kernel:world-render :before ((world web-fixture-world) lease)
  (declare (ignore lease))
  (when (fixture-component world)
    (ataxia.kernel:drawable-prepare-frame (fixture-component world))))
(let* ((world (make-instance 'web-fixture-world))
       (kernel (ataxia.kernel:create-kernel world :backend :headless :headless-width 320 :headless-height 200))
       (component nil) (ready nil) (failed nil) (phase 0) (attempts 0) (done nil))
  (unwind-protect
       (progn
         (ataxia.kernel:start-kernel kernel)
         (setf component (ataxia.world.web:make-web-component
                          :world world :source "<body><script>ataxia.postMessage('ready',true)</script>Portable</body>"
                          :width 200d0 :height 100d0)
               (fixture-component world) component)
         (ataxia.world:ui-set-callback component "ready" (lambda (c v) (declare (ignore c v)) (setf ready t)))
         (ataxia.world:ui-set-callback component "error" (lambda (c v) (declare (ignore c v)) (setf failed t)))
         (let ((timer
                 (ataxia.runtime:add-event-loop-timer
                  (ataxia.kernel:kernel-runtime kernel)
                  (lambda (source)
                    (incf attempts) (assert (< attempts 100))
                    (case phase
                      (0 (when ready
                           (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
                           ;; A helper failure must only fail this component, never the owner.
                           (cffi:foreign-funcall "kill" :int (ataxia.world.web:web-engine-pid world) :int 9 :int)
                           (incf phase)))
                      (1 (when failed
                           (assert (null (ataxia.world:world-service world :web-ui)))
                           (assert (eq :unavailable (ataxia.kernel:interaction-result-status
                                                    (ataxia.kernel:interactable-focus component world nil :keyboard))))
                           (setf (fixture-component world) nil)
                           (ataxia.runtime:call-with-egl-context (ataxia.runtime:runtime-egl (ataxia.kernel:kernel-runtime kernel))
                             (lambda () (ataxia.kernel:drawable-detach-graphics component)))
                           (ataxia.world:ui-destroy component) (setf component nil)
                           ;; A new component restarts a fresh helper after the failure.
                           (setf ready nil failed nil
                                 component (ataxia.world.web:make-web-component
                                            :world world :source "<script>ataxia.postMessage('ready',true)</script>Restarted"))
                           (ataxia.world:ui-set-callback component "ready" (lambda (c v) (declare (ignore c v)) (setf ready t)))
                           (incf phase)))
                      (2 (when ready
                           (ataxia.world:ui-destroy component) (setf component nil)
                           (assert (null (ataxia.world:world-service world :web-ui)))
                           (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
                           (setf done t))))
                    (ataxia.runtime:update-event-loop-timer source (if done 0 100)) 0))))
           (ataxia.runtime:update-event-loop-timer timer 100))
         (ataxia.kernel:run-kernel kernel :run-for 5d0)
         (assert done)
         (format t "PASS: standalone web adapter, unrelated World without UI host, helper failure containment/restart and cleanup.~%"))
    (when component
      (ataxia.runtime:call-with-egl-context (ataxia.runtime:runtime-egl (ataxia.kernel:kernel-runtime kernel)) (lambda () (ataxia.kernel:drawable-detach-graphics component)))
      (ataxia.world:ui-destroy component))
    (ataxia.kernel:destroy-kernel kernel :web-portability-test)))
