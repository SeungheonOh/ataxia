;;;; Check the encoded image independently of capture and coordinate helpers.
(load (merge-pathnames "support.lisp" *load-truename*))
(asdf:load-system "ataxia-computer-use/metaworld")
(in-package #:ataxia.infinite-world)
(cffi:load-foreign-library "libz.so.1")

(defun test-png-u32 (bytes offset)
  (loop for i from offset below (+ offset 4)
        for value = (aref bytes i) then (+ (* value 256) (aref bytes i))
        finally (return value)))
(defun test-png-rows (path)
  (let* ((bytes (with-open-file (in path :element-type '(unsigned-byte 8))
                  (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
                    (read-sequence bytes in) bytes)))
         (width (test-png-u32 bytes 16)) (height (test-png-u32 bytes 20))
         (offset 8) (parts nil))
    (assert (equalp #(137 80 78 71 13 10 26 10) (subseq bytes 0 8)))
    (loop while (< offset (length bytes)) for size = (test-png-u32 bytes offset) do
          (let ((body (subseq bytes (+ offset 4) (+ offset 8 size))))
            (sb-sys:with-pinned-objects (body)
              (assert (= (test-png-u32 bytes (+ offset 8 size))
                         (cffi:foreign-funcall "crc32" :ulong 0 :pointer (sb-sys:vector-sap body) :uint (length body) :ulong)))))
          (when (equalp #(73 68 65 84) (subseq bytes (+ offset 4) (+ offset 8)))
            (push (subseq bytes (+ offset 8) (+ offset 8 size)) parts))
          (incf offset (+ size 12)))
    (let ((input (apply #'concatenate '(simple-array (unsigned-byte 8) (*)) (nreverse parts)))
          (rows (make-array (* height (1+ (* width 4))) :element-type '(unsigned-byte 8))))
      (cffi:with-foreign-object (size :ulong)
        (setf (cffi:mem-ref size :ulong) (length rows))
        (sb-sys:with-pinned-objects (input rows)
          (assert (zerop (cffi:foreign-funcall "uncompress" :pointer (sb-sys:vector-sap rows) :pointer size
                                              :pointer (sb-sys:vector-sap input) :ulong (length input) :int))))
        (assert (= (length rows) (cffi:mem-ref size :ulong))))
      (dotimes (y height) (assert (zerop (aref rows (* y (1+ (* width 4)))))))
      (values rows width height))))

(let ((directory (merge-pathnames (format nil "ataxia-png-~A/" (ataxia.computer-use:random-token)) (uiop:temporary-directory))))
  (unwind-protect
       (progn
         (sb-posix:mkdir directory #o700)
         ;; Each label is a distinct RGBA pixel. These literal expectations
         ;; cover all rotations/reflections without using the production math.
         (loop for transform below 8
               for expected in '(((1 2 3) (4 5 6)) ((3 6) (2 5) (1 4))
                                 ((6 5 4) (3 2 1)) ((4 1) (5 2) (6 3))
                                 ((3 2 1) (6 5 4)) ((6 3) (5 2) (4 1))
                                 ((4 5 6) (1 2 3)) ((1 4) (2 5) (3 6))) do
               (let* ((width (length (first expected))) (height (length expected))
                      (source (make-array 24 :element-type '(unsigned-byte 8)
                                            :initial-contents '(1 44 55 255 2 44 55 255 3 44 55 255
                                                                4 44 55 255 5 44 55 255 6 44 55 255)))
                      (ticket (ataxia.computer-use::make-computer-capture :width 3 :height 2 :logical-width width :logical-height height
                                                     :pixels source :transform transform :mode :desktop :timestamp 0
                                                     :path (merge-pathnames (format nil "transform-~D.png" transform) directory))))
                 (ataxia.computer-use::%computer-write-png ticket)
                 (multiple-value-bind (rows actual-width actual-height) (test-png-rows (ataxia.computer-use::computer-capture-path ticket))
                   (assert (= width actual-width)) (assert (= height actual-height))
                   (loop for row in expected for y from 0 do
                         (loop for label in row for x from 0
                               for start = (+ 1 (* y (1+ (* width 4))) (* x 4)) do
                               (assert (equalp (vector label 44 55 255) (subseq rows start (+ start 4)))))))))
         ;; Oversized desktop images still use nearest sampling within the cap.
         (let* ((source (make-array (* 2560 4) :element-type '(unsigned-byte 8)))
                (ticket (ataxia.computer-use::make-computer-capture :width 2560 :height 1 :logical-width 2560 :logical-height 1
                                               :pixels source :transform 0 :mode :desktop :timestamp 0
                                               :path (merge-pathnames "scaled.png" directory))))
           (dotimes (x 2560)
             (setf (aref source (* x 4)) (mod x 251) (aref source (+ 3 (* x 4))) 255))
           (ataxia.computer-use::%computer-write-png ticket)
           (multiple-value-bind (rows width height) (test-png-rows (ataxia.computer-use::computer-capture-path ticket))
             (assert (= width 1280)) (assert (= height 1))
             (dotimes (x width) (assert (= (mod (1+ (* x 2)) 251) (aref rows (1+ (* x 4))))))))
         ;; Avoid regressing to per-pixel float allocation for an unchanged image.
         (let* ((source (make-array (* 1280 915 4) :element-type '(unsigned-byte 8) :initial-element 42))
                (ticket (ataxia.computer-use::make-computer-capture :width 1280 :height 915 :logical-width 1280 :logical-height 915
                                               :pixels source :transform 0 :mode :window :timestamp 0
                                               :path (merge-pathnames "large.png" directory)))
                (before (sb-ext:get-bytes-consed)))
           (ataxia.computer-use::%computer-write-png ticket)
           (assert (< (- (sb-ext:get-bytes-consed) before) (* 32 1024 1024)))
           (multiple-value-bind (rows width height) (test-png-rows (ataxia.computer-use::computer-capture-path ticket))
             (assert (= width 1280)) (assert (= height 915))
             (assert (= 42 (aref rows 1) (aref rows (1- (length rows)))))))
         (format t "PASS: PNG pixels, CRCs, all eight output transforms, downscaling and bounded allocation for unchanged images.~%"))
    (uiop:delete-directory-tree directory :validate t :if-does-not-exist :ignore)))
