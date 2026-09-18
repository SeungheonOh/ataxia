;;;; Actual output commits, desktop PNGs and Wayland input agree on geometry.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-computer-use/metaworld")
(in-package #:ataxia.infinite-world)

(defun transform-test-image (path)
  (labels ((u32 (bytes offset)
             (loop for i from offset below (+ offset 4)
                   for value = (aref bytes i) then (+ (* value 256) (aref bytes i))
                   finally (return value))))
    (let* ((bytes (with-open-file (in path :element-type '(unsigned-byte 8))
                    (let ((v (make-array (file-length in) :element-type '(unsigned-byte 8))))
                      (read-sequence v in) v)))
           (width (u32 bytes 16)) (height (u32 bytes 20)) (parts nil))
      (loop for offset = 8 then (+ offset size 12) while (< offset (length bytes))
            for size = (u32 bytes offset) do
            (when (equalp #(73 68 65 84) (subseq bytes (+ offset 4) (+ offset 8)))
              (push (subseq bytes (+ offset 8) (+ offset 8 size)) parts)))
      (let ((compressed (apply #'concatenate '(simple-array (unsigned-byte 8) (*)) (nreverse parts)))
            (rows (make-array (* height (1+ (* width 4))) :element-type '(unsigned-byte 8))))
        (cffi:with-foreign-object (size :ulong)
          (setf (cffi:mem-ref size :ulong) (length rows))
          (sb-sys:with-pinned-objects (compressed rows)
            (assert (zerop (cffi:foreign-funcall "uncompress" :pointer (sb-sys:vector-sap rows)
                                                :pointer size :pointer (sb-sys:vector-sap compressed)
                                                :ulong (length compressed) :int)))))
        (values width height rows)))))

(let* ((world (make-metaworld :state-file nil))
       (kernel (ataxia.kernel:create-kernel world :backend :headless :headless-width 1600 :headless-height 1200))
       (runtime (ataxia.kernel:kernel-runtime kernel))
       (directory (merge-pathnames (format nil "ataxia-transforms-~A/" (ataxia.computer-use:random-token)) (uiop:temporary-directory)))
       (socket-path (namestring (merge-pathnames "api.sock" directory)))
       (log (merge-pathnames "client.log" directory))
       (control nil) (client nil) (driver nil) (session nil) (window nil) (sequence 0)
       (failure nil) (complete nil) (cases 0) (lw 0d0) (lh 0d0) (wx 0d0) (wy 0d0)
       (angle .25d0)
       (points '((45d0 55d0 (239 96 72 255)) (300d0 100d0 (55 123 153 255))
                 (450d0 300d0 (34 65 91 255)))))
  (labels ((owner-call (function)
             (ataxia.sly-control:agent-inspect
              (lambda (k w) (declare (ignore k w)) (funcall function)) :timeout 3d0))
           (field (object &rest names)
             (reduce (lambda (value name) (gethash name value)) names :initial-value object))
           (request (op &rest fields)
             (let ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream :protocol 0)))
               (unwind-protect
                    (progn
                      (sb-bsd-sockets:socket-connect socket socket-path)
                      (with-open-stream (stream (sb-bsd-sockets:socket-make-stream
                                                socket :input t :output t :element-type '(unsigned-byte 8)
                                                :buffering :full :timeout 10))
                        (ataxia.computer-use.wire:write-line-bytes
                         stream (ataxia.computer-use.wire:encode
                                 (append (list :op op :token (ataxia.computer-use::computer-session-token session)
                                               :sequence (1+ sequence)) fields)))
                        (let ((reply (ataxia.computer-use.wire:decode
                                      (ataxia.computer-use.wire:read-line-bytes stream 262144))))
                          (when (field reply "session") (setf sequence (field reply "session" "sequence")))
                          (assert (eq t (field reply "ok")) () "~A" (ataxia.computer-use.wire:encode reply))
                          reply)))
                 (ignore-errors (sb-bsd-sockets:socket-close socket)))))
           (screen-point (x y)
             ;; Independent reference: the client is shown at half its native
             ;; size, then the canvas rotates around the logical output center.
             (let ((dx (- (+ wx (* .5d0 x)) (/ lw 2d0)))
                   (dy (- (+ wy (* .5d0 y)) (/ lh 2d0))))
               (list (+ (/ lw 2d0) (* (cos angle) dx) (- (* (sin angle) dy)))
                     (+ (/ lh 2d0) (* (sin angle) dx) (* (cos angle) dy)))))
           (check-image (reply desktop-p)
             (multiple-value-bind (width height rows) (transform-test-image (field reply "image" "path"))
               (let ((cw (if desktop-p lw 600d0)) (ch (if desktop-p lh 360d0)))
                 (assert (< (abs (- cw (field reply "image" "coordinate-width"))) 1d-5))
                 (assert (< (abs (- ch (field reply "image" "coordinate-height"))) 1d-5))
                 (dolist (point points)
                   (destructuring-bind (x y color) point
                     (when desktop-p
                       (destructuring-bind (sx sy) (screen-point x y) (setf x sx y sy)))
                     (let ((offset (+ 1 (* (floor (* y (/ height ch))) (1+ (* width 4)))
                                      (* 4 (floor (* x (/ width cw)))))))
                       (assert (equal color (coerce (subseq rows offset (+ offset 4)) 'list)) ()
                               "Case ~D ~A pixel (~F,~F): expected ~S, got ~S" cases
                               (if desktop-p "desktop" "window") x y color
                               (coerce (subseq rows offset (+ offset 4)) 'list))))))))
           (check-input (desktop-p)
             (let* ((before (length (uiop:read-file-lines log)))
                    (point (if desktop-p (screen-point 45d0 55d0) '(45d0 55d0))))
               (request "batch" :capture :false
                        :actions (vector (list :op "move" :x (first point) :y (second point) :duration .016d0)
                                         '(:op "button")))
               (loop repeat 100
                     for events = (nthcdr before (uiop:read-file-lines log))
                     when (find "button agent-1 272 0" events :test #'equal)
                       do (let* ((line (find-if (lambda (line)
                                                (or (uiop:string-prefix-p "motion agent-1 " line)
                                                    (uiop:string-prefix-p "pointer-enter agent-1 " line)))
                                              (reverse events)))
                                 (values (and line (uiop:split-string line :separator " "))))
                            (assert values () "No pointer coordinates in ~S" events)
                            (assert (< (abs (- 45d0 (read-from-string (third values)))) .15d0))
                            (assert (< (abs (- 55d0 (read-from-string (fourth values)))) .15d0)))
                          (return t)
                     do (sleep .01d0) finally (error "Missing delivered pointer release")))))
    (unwind-protect
         (progn
           (sb-posix:mkdir directory #o700)
           (ataxia.kernel:start-kernel kernel)
           (setf control (ataxia.sly-control:start-sly-control kernel :port 4007))
           (slynk:stop-server 4007)
           (ataxia.computer-use:enable world :socket socket-path)
           (ataxia.computer-use:request-on-owner world '(:op "connect" :name "Transform agent" :purpose "Verify display geometry"))
           (setf session (first (ataxia.computer-use::computer-controller-sessions (ataxia.computer-use::%computer-controller world))))
           (ataxia.computer-use:activate-session session)
           (setf client (uiop:launch-program
                         (list "env" (format nil "WAYLAND_DISPLAY=~A" (ataxia.runtime:runtime-socket-name runtime))
                               "ATAXIA_TEST_TITLE=Transform target"
                               "ATAXIA_TEST_SECONDS=90"
                               (namestring (asdf:system-relative-pathname "ataxia-computer-use" "build/computer-use-client"))
                               (namestring log)) :output :interactive :error-output :interactive))
           (setf driver
                 (sb-thread:make-thread
                  (lambda ()
                    (handler-case
                        (progn
                          ;; Mapping precedes the opening animation. Wait for
                          ;; settled geometry before installing reference poses.
                          (loop repeat 150 when (owner-call (lambda () (and (%world-stacking world)
                                                                                  (%window-visible-p (first (%world-stacking world)))
                                                                                  (not (ataxia.world:animations-active-p (%world-animator world))))))
                                  return t do (sleep .02d0) finally (error "Client did not map"))
                          (owner-call (lambda () (setf window (first (%world-stacking world)))))
                          (dotimes (transform 8)
                            (dolist (scale '(1d0 1.5d0 2d0))
                              (owner-call
                               (lambda ()
                                 (let* ((output (ataxia.computer-use::computer-session-output session))
                                        (native (ataxia.kernel:output-runtime-object output))
                                        (state (ataxia.runtime:create-output-state native)))
                                   (unwind-protect
                                        (progn
                                          (cffi:foreign-funcall "wlr_output_state_set_scale"
                                                               :pointer (ataxia.runtime::%object-pointer state) :float (coerce scale 'single-float) :void)
                                          (cffi:foreign-funcall "wlr_output_state_set_transform"
                                                               :pointer (ataxia.runtime::%object-pointer state) :int transform :void)
                                          (ataxia.runtime:output-request-state kernel native state))
                                     (ataxia.runtime:destroy-output-state state))
                                   (assert (= scale (ataxia.kernel:output-scale output)))
                                   (assert (= transform (ataxia.kernel:output-transform output)))
                                   (setf lw (/ (if (oddp transform) 1200d0 1600d0) scale)
                                         lh (/ (if (oddp transform) 1600d0 1200d0) scale)
                                         wx (- (/ lw 2d0) 150d0) wy (- (* lh .65d0) 90d0))
                                   (let ((canvas (gethash output (%world-outputs world))))
                                     (setf (%canvas-output-camera-x canvas) 0d0 (%canvas-output-camera-y canvas) 0d0
                                           (%canvas-output-zoom canvas) 1d0 (%canvas-output-rotation canvas) angle
                                           (%canvas-output-target-rotation canvas) angle
                                           (canvas-window-width window) 300d0 (canvas-window-height window) 180d0
                                           (canvas-window-scale window) 1d0)
                                     (set-window-position world window wx wy)
                                     (%full-damage world canvas)))))
                              (let ((id (ataxia.kernel:object-id (canvas-window-application window))))
                                (check-image (request "batch" :actions
                                                      (vector (list :op "view" :mode "desktop" :window id)
                                                              (list :op "move" :x 5d0 :y (- lh 20d0) :duration .016d0))) t)
                                (check-input t)
                                (check-image (request "batch" :actions (vector (list :op "view" :mode "window" :window id))) nil)
                                (check-input nil))
                              (incf cases)
                              (format t "Verified transform ~D scale ~F (desktop and window).~%" transform scale)))
                          (request "disconnect")
                          (setf complete t))
                      (error (cause) (setf failure cause)))
                    (ignore-errors (owner-call (lambda () (ataxia.kernel:request-kernel-stop kernel :checks-complete)))))
                  :name "Computer-use transform checks"))
           (ataxia.kernel:run-kernel kernel :run-for 90d0)
           (when failure (error failure))
           (assert complete) (assert (= cases 24))
           (assert (eq :running (ataxia.kernel:kernel-world-status kernel)))
           (format t "PASS: actual desktop and window PNGs and clicks agree across eight output transforms and three scales with a rotated canvas.~%"))
      (ignore-errors (ataxia.computer-use:disable world))
      (dolist (state (%seat-states world)) (%focus-target world state nil))
      (when control (ataxia.sly-control:stop-sly-control control))
      (when driver (ignore-errors (sb-thread:join-thread driver :timeout 3d0 :default nil)))
      (when client (ignore-errors (uiop:terminate-process client)))
      (ataxia.kernel:destroy-kernel kernel :computer-use-transforms-test-complete)
      (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore))))
