(load (merge-pathnames "support.lisp" *load-truename*))
(in-package #:ataxia.kernel)
;;; Frames that follow a flip start as late as they can still meet the next vblank;
;;; a frame on a still screen and the two after it, or one that may not fit, starts
;;; at once.
(let* ((kernel (make-instance 'kernel :world (make-instance 'world)))
       (output (make-instance 'kernel-output :kernel kernel :runtime-object :output))
       (refresh 16666667))
  (flet ((delay-after-vblank (ago)
           (setf (%output-vblank output) (- (%monotonic-nanoseconds) ago)
                 (%output-refresh output) refresh)
           (%frame-delay output)))
    (assert (zerop (%frame-delay output)))
    (assert (zerop (delay-after-vblank 500000000)))
    ;; 3 ms of CPU, 2 ms of GPU and the margin leave 9.7 ms to wait, once a few
    ;; frames in a row have followed flips.
    (setf (%output-frame-cost output) 3000000 (%output-gpu-cost output) 2000000)
    (assert (zerop (delay-after-vblank 0)))
    (assert (zerop (delay-after-vblank 0)))
    (assert (= 9 (delay-after-vblank 0)))
    ;; Flips report their vblank a moment ahead; the frame still aims at the next one.
    (assert (= 9 (delay-after-vblank -300000)))
    ;; A frame that came out a vblank late makes the frames after it start earlier.
    (let ((cost (%output-frame-cost output)))
      (%note-presentation output (+ (%output-target-vblank output) refresh) refresh t)
      (assert (> (%output-frame-cost output) cost)))
    ;; A frame that may not fit before the next vblank starts at once, aiming at none.
    (setf (%output-frame-cost output) 9000000 (%output-gpu-cost output) 7000000)
    (assert (zerop (delay-after-vblank 0)))
    (assert (null (%output-target-vblank output)))
    ;; Without vsync there is no vblank to aim for.
    (%note-presentation output (%monotonic-nanoseconds) refresh nil)
    (assert (zerop (%frame-delay output)))))
(format t "PASS: frames following a flip start as late as still meets the next vblank; still screens and frames that may not fit start at once; misses start frames earlier.~%")
