;;;; Stage World screen sharing through the public portal, PipeWire and a real client.
;;;; Run: make test-screencast (needs xdg-desktop-portal, Python GI/GStreamer and PipeWire)
(load (merge-pathnames "system-support.lisp" *load-truename*))
(asdf:load-system "ataxia-stage-world")
(in-package #:ataxia.stage-world)

(defclass stage-test-world (stage-world)
  ((frames :initform 0 :accessor test-frames)))

(defmethod ataxia.kernel:world-render :after ((world stage-test-world) lease)
  (declare (ignore lease))
  (incf (test-frames world)))

(let* ((root (uiop:ensure-directory-pathname
              (format nil "/tmp/ataxia-stage-share-~D" (sb-posix:getpid))))
       (log (namestring (merge-pathnames "client.log" (ensure-directories-exist root))))
       (world (make-instance 'stage-test-world :socket-path (namestring (merge-pathnames "stage.sock" root))))
       (kernel (ataxia.kernel:create-kernel world :backend :headless
                                                  :headless-width 1000 :headless-height 700))
       (runtime (ataxia.kernel:kernel-runtime kernel))
       (tick (symbol-function '%share-tick))
       (app nil) (portal nil) (answered 0) (ticks 0) (frames nil))
  (unwind-protect
       (progn
         (setf (symbol-function '%share-tick)
               (lambda (world controller) (incf ticks) (funcall tick world controller)))
         (ataxia.kernel:start-kernel kernel)
         (enable-screen-sharing world)
         (setf app (uiop:launch-program
                    (list "env" (format nil "WAYLAND_DISPLAY=~A" (ataxia.runtime:runtime-socket-name runtime))
                          "ATAXIA_TEST_REPAINT_SIGNAL=1" "ATAXIA_TEST_SECONDS=60" "build/computer-use-client" log))
               portal (uiop:launch-program
                       (list "/usr/bin/python3" "tests/screencast-client.py"
                             (princ-to-string (uiop:process-info-pid app)))
                       :output (namestring (merge-pathnames "portal.log" root)) :error-output :output))
         ;; Answer requests as a director would: a window, a screen region, then a refusal.
         (let ((timer (ataxia.runtime:add-event-loop-timer
                       runtime
                       (lambda (source)
                         (let ((share (find nil (share-controller-shares (%sharing world))
                                            :key #'share-source))
                               (window (loop for window being the hash-values of (%windows world)
                                             when (ataxia.kernel:application-mapped-p
                                                   (stage-window-application window))
                                               return window)))
                           (when (and share (or window (/= 2 (share-types share))))
                             (case (share-types share)
                               (2 (accept-share world (share-id share) :window window))
                               (1 (accept-share world (share-id share) :output (first (%outputs world))
                                                                       :region '(40d0 40d0 400d0 300d0)))
                               (t (cancel-share world (share-id share))))
                             (incf answered)))
                         (cond ((< answered 3) (ataxia.runtime:update-event-loop-timer source 100))
                               ((and (null frames) (not (uiop:process-alive-p portal))
                                     (null (share-controller-shares (%sharing world))))
                                (setf frames (test-frames world) ticks 0)
                                (ataxia.runtime:update-event-loop-timer source 1500))
                               ((null frames) (ataxia.runtime:update-event-loop-timer source 100))
                               (t (ataxia.kernel:request-kernel-stop kernel)))
                         0))))
           (ataxia.runtime:update-event-loop-timer timer 300))
         (ataxia.kernel:run-kernel kernel :run-for 40d0)
         (format t "~A" (uiop:read-file-string (merge-pathnames "portal.log" root)))
         (assert (zerop (uiop:wait-process portal)))
         (assert (= 3 answered))
         ;; With every share stopped, sharing costs nothing.
         (assert frames () "The shares never all stopped.")
         (assert (zerop ticks) () "~D capture ticks after sharing stopped" ticks)
         (assert (= frames (test-frames world)) () "~D frames after sharing stopped"
                 (- (test-frames world) frames))
         ;; The replaced World releases the portal so its successor can own it.
         (let ((replacement (make-stage-world :screen-sharing-p t
                                              :socket-path (namestring (merge-pathnames "next.sock" root)))))
           (ataxia.kernel:install-world kernel replacement)
           (assert (null (%sharing world)))
           (assert (%sharing replacement))))
    (setf (symbol-function '%share-tick) tick)
    (when (and portal (uiop:process-alive-p portal)) (uiop:terminate-process portal))
    (when (and app (uiop:process-alive-p app)) (uiop:terminate-process app))
    (ataxia.kernel:destroy-kernel kernel :test)
    (uiop:delete-directory-tree root :validate t :if-does-not-exist :ignore)))
(format t "PASS: Stage window and region shares, refusal, idle once stopped, and World replacement.~%")
