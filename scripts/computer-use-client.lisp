;;;; The client uses the same local data protocol as any other agent.
(require :sb-bsd-sockets)
(load (merge-pathnames "../src/world/computer-use/json.lisp" *load-truename*))

(defun computer-use-client-main ()
  (let* ((arguments (rest sb-ext:*posix-argv*))
         (path (when (equal (first arguments) "--socket") (pop arguments) (pop arguments)))
         (command (pop arguments))
         (json (pop arguments)))
    (unless (and (equal command "request") (null arguments))
      (error "Usage: ataxia-computer-use [--socket PATH] request [JSON]; defaults to stdin."))
    (unless path
      (let ((root (sb-ext:posix-getenv "XDG_RUNTIME_DIR")))
        (unless root (error "Set XDG_RUNTIME_DIR or pass --socket."))
        (setf path (concatenate 'string (string-right-trim "/" root) "/ataxia-computer-use.sock"))))
    (unless json
      (setf json (with-output-to-string (out)
                   (loop for count from 0 for c = (read-char *standard-input* nil nil) while c do
			 (when (>= count 65536) (error "Request is too large."))
			 (write-char c out)))))
    (when (> (length (sb-ext:string-to-octets json :external-format :utf-8)) 65536)
      (error "Request is too large."))
    (let ((request (ataxia.computer-use.wire:decode json))
          (socket (make-instance 'sb-bsd-sockets:local-socket :type :stream :protocol 0)))
      (unless (hash-table-p request) (error "Expected a JSON request object."))
      (unwind-protect
           (progn
             (sb-bsd-sockets:socket-connect socket path)
             (with-open-stream (stream (sb-bsd-sockets:socket-make-stream socket :input t :output t
									  :element-type '(unsigned-byte 8) :buffering :full :timeout 40))
               (ataxia.computer-use.wire:write-line-bytes stream (ataxia.computer-use.wire:encode request))
               (let* ((reply (ataxia.computer-use.wire:read-line-bytes stream 262144))
                      (data (ataxia.computer-use.wire:decode reply :max-string 65536 :max-nodes 16384)))
                 (write-line reply)
                 (if (eq t (gethash "ok" data)) 0 1))))
        (ignore-errors (sb-bsd-sockets:socket-close socket))))))

(handler-case (sb-ext:exit :code (computer-use-client-main))
  (error (cause) (format *error-output* "~A~%" cause) (sb-ext:exit :code 1)))
