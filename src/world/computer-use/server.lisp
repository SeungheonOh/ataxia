;;;; A local Lisp listener. Accept on the event loop; decode/wait/encode on workers.
(in-package #:ataxia.computer-use)

(defstruct computer-server world generation socket path source
           (clients nil) (lock (sb-thread:make-mutex :name "Computer-use connections")))

(defparameter +computer-json-fields+
  (mapcar (lambda (key) (cons (string-downcase (symbol-name key)) key))
          +computer-request-fields+))

(defun decode-request (object)
  (unless (and (hash-table-p object) (<= (hash-table-count object) 24))
    (%computer-reject "invalid-request" "Expected a bounded JSON object."))
  (let ((request nil))
    (maphash
     (lambda (name value)
       (let ((key (cdr (assoc name +computer-json-fields+ :test #'equal))))
         (unless key (%computer-reject "unknown-field" "Unrecognized request field."))
         (case key
           (:actions
            (unless (and (vectorp value) (not (stringp value)) (<= (length value) 16))
              (%computer-reject "invalid-batch" "actions must be a bounded array."))
            (setf value (map 'vector #'decode-request value)))
           (:operations (%computer-desktop-operations value))
           (:modifiers
            (unless (and (vectorp value) (not (stringp value)) (<= (length value) 4)
                         (every #'stringp value))
              (%computer-reject "invalid-modifiers" "Expected a bounded modifier array."))
            (setf value (coerce value 'list)))
           (otherwise
            (unless (or (stringp value) (numberp value) (member value '(t nil :false)))
              (%computer-reject "invalid-request" "Unexpected structured field value."))))
         (setf request (list* key value request)))) object)
    request))

(defun %computer-serve-connection (server socket)
  (unwind-protect
       (handler-case
           (let ((stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
                                                            :element-type '(unsigned-byte 8) :buffering :full :timeout 5)))
             (let ((reply
                    (handler-case
                        (ataxia.computer-use::%request
                         (decode-request
                          (ataxia.world.wire:decode (ataxia.world.wire:read-line-bytes stream)))
                         :expected-world (computer-server-world server)
                         :expected-generation (computer-server-generation server)
                         :expected-server server)
                      (computer-use-rejected (cause)
                        (list :ok :false :error (%computer-error-code cause) :message (%computer-error-message cause)))
                      (error (cause) (list :ok :false :error "invalid-request" :message (princ-to-string cause))))))
               (ataxia.world.wire:write-line-bytes stream (%computer-json reply))))
         (error () nil))
    (sb-thread:with-mutex ((computer-server-lock server))
      (ignore-errors (sb-bsd-sockets:socket-close socket :abort t))
      (setf (computer-server-clients server) (delete socket (computer-server-clients server))))))

(defun %computer-server-ready (server)
  (handler-case
      (let ((socket (sb-bsd-sockets:socket-accept (computer-server-socket server))))
        (when socket
          (setf (sb-bsd-sockets:non-blocking-mode socket) nil)
          (let ((admitted nil))
            (sb-thread:with-mutex ((computer-server-lock server))
              (when (< (length (computer-server-clients server)) 8)
                (push socket (computer-server-clients server)) (setf admitted t)))
            (if admitted
                (handler-case
                    (sb-thread:make-thread (lambda () (%computer-serve-connection server socket)) :name "Computer-use request")
                  (error (cause)
                    (sb-thread:with-mutex ((computer-server-lock server))
                      (sb-bsd-sockets:socket-close socket :abort t)
                      (setf (computer-server-clients server) (delete socket (computer-server-clients server))))
                    (error cause)))
                (sb-bsd-sockets:socket-close socket)))))
    (error (cause) (format *error-output* "[computer-use] Accept failed: ~A~%" cause)))
  0)

(defun %computer-start-server (world requested-path)
  (let* ((controller (%computer-controller world))
         (path (or requested-path
                   (let ((root (uiop:getenv "XDG_RUNTIME_DIR")))
                     (unless root (error "Set XDG_RUNTIME_DIR or supply :socket."))
                     (namestring (merge-pathnames "ataxia-computer-use.sock" (uiop:ensure-directory-pathname root))))))
         (kernel (ataxia.kernel:world-kernel world)))
    (when (computer-controller-server controller)
      (unless (equal path (computer-server-path (computer-controller-server controller)))
        (error "Computer use already listens on another socket."))
      (return-from %computer-start-server (computer-controller-server controller)))
    (unless (and (stringp path) (< (length (sb-ext:string-to-octets path :external-format :utf-8)) 108))
      (error "The local socket path is invalid or too long."))
    (let ((parent (sb-posix:stat (uiop:pathname-directory-pathname path))))
      (unless (and (= (sb-posix:stat-uid parent) (sb-posix:getuid))
                   (zerop (logand #o022 (sb-posix:stat-mode parent))))
        (error "The local socket needs a directory owned by you and not writable by others.")))
    (when (probe-file path) (error "Socket path is already in use: ~A" path))
    (let* ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream :protocol 0))
           (server (make-computer-server :world world :generation (ataxia.kernel:kernel-world-generation kernel)
                                         :socket socket :path path))
           (bound nil) (ready nil))
      (unwind-protect
           (progn
             (sb-bsd-sockets:socket-bind socket path) (setf bound t)
             (sb-posix:chmod path #o600)
             (sb-bsd-sockets:socket-listen socket 8)
             (setf (sb-bsd-sockets:non-blocking-mode socket) t
                   (computer-server-source server)
                   (ataxia.runtime:add-event-loop-fd
                    (ataxia.kernel:kernel-runtime kernel) (sb-bsd-sockets:socket-file-descriptor socket)
                    ataxia.runtime:+event-readable+
                    (lambda (source fd mask)
                      (declare (ignore source fd))
                      (when (logtest ataxia.runtime:+event-readable+ mask) (%computer-server-ready server)) 0))
                   (computer-controller-server controller) server
                   ready t)
             server)
        (unless ready
          (ignore-errors (sb-bsd-sockets:socket-close socket))
          (when bound (ignore-errors (delete-file path))))))))

(defun %computer-stop-server (controller)
  (let ((server (computer-controller-server controller)))
    (when server
      (setf (computer-controller-server controller) nil)
      (ataxia.runtime:remove-event-loop-source (computer-server-source server))
      (sb-bsd-sockets:socket-close (computer-server-socket server))
      ;; Wake blocked readers. Serialize shutdown with worker cleanup so a
      ;; descriptor cannot be closed and reused between lookup and shutdown.
      (sb-thread:with-mutex ((computer-server-lock server))
        (dolist (socket (computer-server-clients server))
          (ignore-errors (sb-bsd-sockets:socket-shutdown socket :direction :io))))
      (ignore-errors (delete-file (computer-server-path server)))))
  nil)
