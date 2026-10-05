;;;; The clipboard, for the director and desktop services.
;;;;
;;;; Text a client copies is sent to the director, which keeps the history a
;;;; menu shows, and the director can set the clipboard. Reads are non-blocking
;;;; pipe transfers on the owner thread, bounded in size and time; selections
;;;; that password managers mark as secret are never read.

(in-package #:ataxia.stage-world)

(defparameter +clipboard-limit+ (* 256 1024)
  "Longest text, in bytes, that is read from a selection.")
(defparameter +text-types+
  '("text/plain;charset=utf-8" "text/plain;charset=UTF-8" "UTF8_STRING" "text/plain"))
(defparameter +secret-types+
  '("x-kde-passwordManagerHint" "application/x-kde-passwordManagerHint" "application/x-keepassxc"))

(defstruct (selection-read (:constructor %make-selection-read (world fd callback)))
  (world nil :read-only t)
  (fd nil)
  (callback nil :read-only t)
  (source nil)
  (timer nil)
  (bytes (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0) :read-only t))

(defun %finish-selection-read (read text)
  (when (selection-read-fd read)
    (let ((world (selection-read-world read)))
      (setf (%selection-reads world) (remove read (%selection-reads world))))
    (dolist (source (list (selection-read-source read) (selection-read-timer read)))
      (when source (ataxia.runtime:remove-event-loop-source source)))
    (sb-posix:close (shiftf (selection-read-fd read) nil))
    (funcall (selection-read-callback read) text)))

(defun stop-selection-reads (world)
  "Give up the reads still in flight, e.g. as WORLD is replaced."
  (dolist (read (%selection-reads world))
    (%finish-selection-read read nil)))

(defun %selection-readable (read)
  (cffi:with-foreign-object (buffer :uint8 16384)
    (loop repeat 4
          for count = (cffi:foreign-funcall "read" :int (selection-read-fd read) :pointer buffer
                                                   :size 16384 :long)
          do (cond
               ((plusp count)
                (let ((bytes (selection-read-bytes read)))
                  (when (> (+ count (length bytes)) +clipboard-limit+)
                    (return (%finish-selection-read read nil)))
                  (dotimes (index count) (vector-push-extend (cffi:mem-aref buffer :uint8 index) bytes))))
               ((zerop count)
                (return (%finish-selection-read
                         read (sb-ext:octets-to-string (selection-read-bytes read)
                                                       :external-format '(:utf-8 :replacement #\?)))))
               ;; EAGAIN: the rest arrives with the next readable event.
               (t (return))))))

(defun read-selection-text (world seat callback)
  "Call CALLBACK with SEAT's selection as text, or with NIL when it holds no text, is
marked secret, is too large or does not arrive within two seconds."
  (let* ((runtime-seat (ataxia.kernel:seat-runtime-object seat))
         (types (ataxia.runtime:seat-selection-mime-types runtime-seat))
         (mime (find-if (lambda (type) (member type types :test #'equal)) +text-types+)))
    (if (or (null mime) (intersection types +secret-types+ :test #'equal))
        (funcall callback nil)
        (multiple-value-bind (read-fd write-fd) (sb-posix:pipe)
          (sb-posix:fcntl read-fd sb-posix:f-setfl sb-posix:o-nonblock)
          (sb-posix:fcntl read-fd sb-posix:f-setfd 1) ; FD_CLOEXEC
          (let* ((runtime (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world)))
                 (read (%make-selection-read world read-fd callback)))
            (push read (%selection-reads world))
            (setf (selection-read-source read)
                  (ataxia.runtime:add-event-loop-fd
                   runtime read-fd ataxia.runtime:+event-readable+
                   (%guarded world :stage-clipboard
                             (lambda (source fd mask)
                               (declare (ignore source fd mask))
                               (%selection-readable read))))
                  (selection-read-timer read)
                  (ataxia.runtime:add-event-loop-timer
                   runtime (%guarded world :stage-clipboard
                                     (lambda (source)
                                       (declare (ignore source))
                                       (%finish-selection-read read nil)))))
            (ataxia.runtime:update-event-loop-timer (selection-read-timer read) 2000)
            ;; The selection owner writes into, and the runtime closes, WRITE-FD.
            (unless (ataxia.runtime:seat-selection-receive runtime-seat mime write-fd)
              (%finish-selection-read read nil)))))))

(defmethod ataxia.kernel:world-seat-selection-changed ((world stage-world) seat)
  (let ((runtime-seat (ataxia.kernel:seat-runtime-object seat)))
    ;; Text the director set itself is already in its history.
    (when (and (stage-director-connected-p world) (not (ataxia.world:agent-seat-p seat))
               (not (ataxia.runtime:seat-clipboard-owned-p runtime-seat)))
      (read-selection-text world seat
                           (lambda (text)
                             (when (and text (plusp (length text)))
                               (%send world (list :type "clipboard" :text text)))))))
  seat)

(defun set-seat-clipboard (seat text)
  (ataxia.runtime:seat-set-clipboard-text (ataxia.kernel:seat-runtime-object seat) text))

(defmethod ataxia.world:request-clipboard-text ((world stage-world) seat callback)
  (if (ataxia.world:agent-seat-p seat)
      (funcall callback nil)
      (read-selection-text world seat callback))
  t)

(defmethod ataxia.world:set-clipboard-text ((world stage-world) seat text)
  (unless (ataxia.world:agent-seat-p seat)
    (set-seat-clipboard seat text)
    t))
