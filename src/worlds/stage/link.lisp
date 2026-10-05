;;;; Director link: newline-delimited JSON over a local stream socket.
;;;;
;;;; The listener and the director connection are owner-thread event sources.
;;;; Reads and writes never block, and both directions are bounded. A newer
;;;; connection replaces the current director, so a restarted runtime takes
;;;; over the live scene; its first commit replaces the old scene in place,
;;;; letting windows animate from where they are.
;;;; docs/STAGE-PROTOCOL.md specifies every message in full.

(in-package #:ataxia.stage-world)

(defconstant +protocol-version+ 1)
(defparameter *max-message-bytes* (* 8 1024 1024))
(defparameter *max-pending-output-bytes* (* 16 1024 1024))

(defstruct (stage-link (:constructor %make-stage-link (world path socket)))
  (world nil :read-only t)
  (path nil :read-only t)
  (socket nil :read-only t)
  (source nil)
  (director nil)
  (buffer (make-array 65536 :element-type '(unsigned-byte 8)) :read-only t))

(defstruct (director (:constructor %make-director (socket)))
  (socket nil :read-only t)
  (source nil)
  (input (make-array 4096 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)
   :read-only t)
  ;; Bytes of INPUT already searched for a newline, so a long message is scanned once.
  (scanned 0 :type fixnum)
  (output nil :type list)
  (output-offset 0 :type integer)
  (output-bytes 0 :type integer)
  (writing-p nil)
  (ready-p nil)
  ;; The director's scene replaces the fallback only after its first commit.
  (committed-p nil)
  (closed-p nil)
  ;; Coalesced messages, (KEY . MESSAGE) in first-arrival order, and their flush.
  (pending nil :type list)
  (flush-source nil)
  (flush-timer nil)
  (flushed-at 0d0 :type double-float))

(defun default-director-socket ()
  "Per-process socket path in $XDG_RUNTIME_DIR."
  (let ((root (uiop:getenv "XDG_RUNTIME_DIR")))
    (unless root (error "Set XDG_RUNTIME_DIR or supply an explicit Stage socket path."))
    (namestring (merge-pathnames (format nil "ataxia-stage-~D.sock" (sb-posix:getpid))
                                 (uiop:ensure-directory-pathname root)))))

(defun %director-scene-active-p (world)
  "True once the connected director has committed a scene, which replaces the fallback layout."
  (let* ((link (%link world))
         (director (and link (stage-link-director link))))
    (and director (director-committed-p director))))

(defun stage-director-connected-p (world)
  "True while a director has completed its handshake."
  (let ((link (%link world)))
    (and link (stage-link-director link) (director-ready-p (stage-link-director link)) t)))

(defun %stale-socket-p (path)
  (let ((probe (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (unwind-protect
         (handler-case (progn (sb-bsd-sockets:socket-connect probe path) nil)
           (sb-bsd-sockets:socket-error () t))
      (sb-bsd-sockets:socket-close probe))))

(defun start-link (world path)
  (let ((runtime (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))))
    (when (probe-file path)
      (if (%stale-socket-p path)
          (delete-file path)
          (error "Another Stage World is listening on ~A." path)))
    (let* ((socket (make-instance 'sb-bsd-sockets:local-socket :type :stream))
           (link (%make-stage-link world path socket))
           (ready-p nil))
      (unwind-protect
           (progn
             (sb-bsd-sockets:socket-bind socket path)
             (sb-posix:chmod path #o600)
             (sb-bsd-sockets:socket-listen socket 4)
             (setf (sb-bsd-sockets:non-blocking-mode socket) t
                   (stage-link-source link)
                   (ataxia.runtime:add-event-loop-fd
                    runtime (sb-bsd-sockets:socket-file-descriptor socket)
                    ataxia.runtime:+event-readable+
                    (%guarded world :stage-accept
                              (lambda (source fd mask)
                                (declare (ignore source fd mask))
                                (%accept-director link))))
                   ready-p t)
             link)
        (unless ready-p
          (ignore-errors (sb-bsd-sockets:socket-close socket))
          (ignore-errors (delete-file path)))))))

(defun stop-link (link)
  (when (stage-link-director link)
    (%close-director link (stage-link-director link)))
  (when (stage-link-source link)
    (ataxia.runtime:remove-event-loop-source (stage-link-source link))
    (setf (stage-link-source link) nil))
  (ignore-errors (sb-bsd-sockets:socket-close (stage-link-socket link)))
  (ignore-errors (delete-file (stage-link-path link)))
  nil)

(defun %log (control &rest arguments)
  (format *error-output* "[stage-world] ~?~%" control arguments)
  (finish-output *error-output*))

(defun %accept-director (link)
  (let ((socket (handler-case (sb-bsd-sockets:socket-accept (stage-link-socket link))
                  (sb-bsd-sockets:socket-error (cause)
                    (%log "accept failed: ~A" cause)
                    nil))))
    (when socket
      ;; The fatal error stops the old director instead of letting it reconnect.
      (when (stage-link-director link)
        (%reject-director link (stage-link-director link) "Replaced by a newer director."))
      (let ((director (%make-director socket))
            (world (stage-link-world link)))
        (setf (sb-bsd-sockets:non-blocking-mode socket) t
              (stage-link-director link) director
              (director-source director)
              (ataxia.runtime:add-event-loop-fd
               (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))
               (sb-bsd-sockets:socket-file-descriptor socket)
               ataxia.runtime:+event-readable+
               (%guarded world :stage-director
                         (lambda (source fd mask)
                           (declare (ignore source fd))
                           (%director-ready link director mask)))))))))

(defun %close-director (link director)
  (unless (director-closed-p director)
    (let ((world (stage-link-world link))
          (was-active-p (director-committed-p director)))
      (setf (director-closed-p director) t
            (director-output director) nil
            (director-pending director) nil)
      (when (director-source director)
        (ataxia.runtime:remove-event-loop-source (director-source director)))
      (when (director-flush-timer director)
        (ataxia.runtime:remove-event-loop-source (director-flush-timer director)))
      (ignore-errors (sb-bsd-sockets:socket-close (director-socket director)))
      (when (eq director (stage-link-director link))
        (setf (stage-link-director link) nil)
        (%director-detached world was-active-p)))))

(defun %director-ready (link director mask)
  (unless (director-closed-p director)
    (when (logtest mask ataxia.runtime:+event-writable+)
      (%flush-director link director))
    (when (logtest mask (logior ataxia.runtime:+event-readable+ ataxia.runtime:+event-hangup+
                                ataxia.runtime:+event-error+))
      (%read-director link director))))

(defun %read-director (link director)
  (let ((buffer (stage-link-buffer link))
        (input (director-input director)))
    (loop
      (let ((count (handler-case
                       (nth-value 1 (sb-bsd-sockets:socket-receive (director-socket director)
                                                                   buffer (length buffer)))
                     (sb-bsd-sockets:socket-error () 0))))
        (cond
          ((null count) (return))
          ((zerop count) (%close-director link director) (return))
          (t
           (let ((end (fill-pointer input)))
             (when (> (+ end count) (array-dimension input 0))
               (setf input (adjust-array input (max (+ end count) (* 2 (array-dimension input 0))))))
             (setf (fill-pointer input) (+ end count))
             (replace input buffer :start1 end :end2 count))
           (%consume-lines link director)
           (when (director-closed-p director) (return))))))))

(defun %consume-lines (link director)
  (let* ((input (director-input director))
         (start 0))
    (loop for newline = (position 10 input :start (max start (director-scanned director)))
          while (and newline (not (director-closed-p director)))
          do (let ((text (handler-case (sb-ext:octets-to-string input :external-format :utf-8
                                                                      :start start :end newline)
                           (error () nil))))
               (setf start (1+ newline))
               (if text
                   (%handle-line link director text)
                   (%reject-director link director "Messages must be UTF-8."))))
    (unless (director-closed-p director)
      (replace input input :start2 start)
      (setf (fill-pointer input) (- (fill-pointer input) start)
            (director-scanned director) (fill-pointer input))
      (when (> (fill-pointer input) *max-message-bytes*)
        (%reject-director link director "Message exceeds the size limit.")))))

(defun %reject-director (link director message)
  (%log "closing director: ~A" message)
  (%send-to director (list :type "error" :message message :fatal t))
  (%flush-director link director)
  (%close-director link director))

(defun %handle-line (link director text)
  (let ((message (handler-case
                     ;; Lines are already bounded, so a string may be as long as one.
                     (ataxia.world.wire:decode text :max-string *max-message-bytes* :max-nodes 1000000
                                                    :max-depth 16)
                   (error (cause)
                     ;; Newline framing survives a bad line, so a ready director is only told.
                     (if (director-ready-p director)
                         (%send-to director (list :type "error" :message (format nil "Invalid JSON: ~A" cause)))
                         (%reject-director link director (format nil "Invalid JSON: ~A" cause)))
                     (return-from %handle-line)))))
    (unless (hash-table-p message)
      (%reject-director link director "Messages must be JSON objects.")
      (return-from %handle-line))
    (let ((type (gethash "type" message)))
      (if (director-ready-p director)
          (handler-case (%dispatch-message link director type message)
            (stage-protocol-error (cause)
              (%send-to director (list :type "error" :message (princ-to-string cause))))
            ;; A message that trips over a World bug is reported, not fatal: the
            ;; director keeps running and the scene stays as far as it applied.
            (error (cause)
              (%log "~A message failed: ~A" type cause)
              (%send-to director (list :type "error" :message (format nil "Internal error: ~A" cause)))
              (%scene-changed (stage-link-world link))))
          (if (and (equal type "hello") (eql (gethash "protocol" message) +protocol-version+))
              (progn
                (%log "director ~A connected" (or (gethash "client" message) "(unnamed)"))
                (setf (director-ready-p director) t)
                (%send-to director (%welcome (stage-link-world link)))
                (%flush-director link director))
              (%reject-director link director
                                (format nil "Expected hello for protocol ~D." +protocol-version+)))))))

(defun %dispatch-message (link director type message)
  (let ((world (stage-link-world link)))
    (cond
      ((equal type "commit")
       (let ((ops (gethash "ops" message)))
         (unless (and (vectorp ops) (not (stringp ops)))
           (protocol-error "commit requires an ops array."))
         ;; From its first commit the director's scene replaces the fallback layout.
         (setf (director-committed-p director) t)
         (let ((errors (%apply-commit world ops)))
           (when errors
             (protocol-error "~D op~:P rejected; first: ~A" (length errors) (first errors))))))
      ((equal type "focus")
       (let ((seat-state (%default-seat-state world))
             (id (gethash "window" message)))
         (when seat-state
           (%focus-window world seat-state
                          (and id (or (gethash id (%windows-by-id world))
                                      (protocol-error "Unknown window ~S." id)))))))
      ((equal type "close")
       (let* ((id (gethash "window" message))
              (window (or (gethash id (%windows-by-id world)) (protocol-error "Unknown window ~S." id))))
         (ataxia.kernel:request-object-state (stage-window-application window) world :close t)))
      ((equal type "camera") (%move-cameras world message))
      ((equal type "share-accept")
       (apply #'accept-share world (gethash "id" message) (%message-source world message)))
      ((equal type "share-cancel") (cancel-share world (gethash "id" message)))
      ((equal type "measure") (%measure-texts link director message))
      ((equal type "capture")
       (let ((id (gethash "id" message)))
         (unless (typep id '(integer 0 #.most-positive-fixnum))
           (protocol-error "capture requires a numeric id."))
         (apply #'capture-for-director world id (%message-source world message))))
      ((equal type "set-clipboard")
       (let ((text (gethash "text" message))
             (seat-state (%default-seat-state world)))
         (unless (stringp text) (protocol-error "set-clipboard requires text."))
         (when seat-state (set-seat-clipboard (stage-seat-seat seat-state) text))))
      (t (protocol-error "Unknown message type ~S." type)))))

(defparameter +text-measure-props+
  '("text" "markup" "font" "fontSize" "fontWeight" "italic" "align" "width" "lineHeight" "maxLines")
  "Text node properties a measure request may give.")

(defun %measure-texts (link director message)
  "Answer a measure request with the size Pango gives each text, as a text node would show it."
  (let ((requests (%json-list (gethash "requests" message) "requests")))
    (when (> (length requests) 1000) (protocol-error "At most 1000 texts per measure request."))
    (%send-to
     director
     (list :type "measured"
           :results
           (map 'vector
                (lambda (request)
                  (unless (hash-table-p request) (protocol-error "Measure requests must be objects."))
                  (let* ((props (or (gethash "props" request) (make-hash-table)))
                         (values (progn
                                   (unless (hash-table-p props) (protocol-error "props must be an object."))
                                   (loop for name in +text-measure-props+
                                         for spec = (gethash name +prop-specs+)
                                         collect (prop-spec-key spec)
                                         collect (decode-prop-value spec (gethash name props)))))
                         (metrics (measure-text (text-style (lambda (key) (getf values key))))))
                    (list :key (gethash "key" request)
                          :width (if metrics (text-metrics-width metrics) 0d0)
                          :height (if metrics (text-metrics-height metrics) 0d0))))
                requests)))
    (%flush-director link director)))

(defun %message-source (world message)
  "Keyword arguments naming the window, or the output and region, MESSAGE picks."
  (let ((output-name (gethash "output" message))
        (window-id (gethash "window" message))
        (region (gethash "region" message)))
    (if window-id
        (list :window (or (gethash window-id (%windows-by-id world))
                          (protocol-error "Unknown window ~S." window-id)))
        (list :output (or (if output-name
                              (find output-name (%outputs world) :key #'%output-name :test #'equal)
                              (first (%outputs world)))
                          (protocol-error "Unknown output ~S." output-name))
              :region (when region
                        (unless (hash-table-p region) (protocol-error "region must be an object."))
                        (mapcar (lambda (key) (%finite-number (gethash key region) key))
                                '("x" "y" "width" "height")))))))

(defun %move-cameras (world message)
  "Apply a programmatic camera move to one output, or to every output."
  (let* ((output (gethash "output" message))
         (targets (or (remove-if-not (lambda (stage-output)
                                       (or (null output) (equal output (%output-name stage-output))))
                                     (%outputs world))
                      (protocol-error "Unknown output ~S." output)))
         (motion (let ((transition (gethash "transition" message)))
                   (and transition (decode-motion transition))))
         (fields (loop for (name key) in '(("x" :x) ("y" :y) ("zoom" :zoom) ("rotation" :rotation))
                       for value = (gethash name message)
                       when value
                         append (list key (decode-prop-value (find-prop-spec key) value)))))
    (dolist (stage-output targets)
      (apply #'camera-move stage-output :motion motion fields))
    (%report-cameras world)
    (%scene-changed world)))

(defun %apply-op (scene op time)
  (unless (hash-table-p op) (protocol-error "Each op must be an object."))
  (let ((name (gethash "op" op)))
    (flet ((field (key) (gethash key op)))
      (cond
        ((equal name "create")
         (scene-create scene (field "id") (field "type")
                       (or (field "props") (make-hash-table :test #'equal)) time))
        ((equal name "set") (scene-update scene (field "id") (field "props") time))
        ((equal name "insert") (scene-insert scene (field "parent") (field "id") (field "before")))
        ((equal name "remove") (scene-remove scene (field "parent") (field "id")))
        ((equal name "reset") (scene-clear scene))
        (t (protocol-error "Unknown op ~S." name))))))

(defun %apply-commit (world ops)
  "Apply OPS as one scene transaction and return the messages of rejected ops.
A rejected op changes nothing; the rest still applies, keeping a live session usable."
  (let ((scene (%scene world))
        (time (%now))
        (errors nil))
    (loop for op across ops
          do (handler-case (%apply-op scene op time)
               (stage-protocol-error (cause) (push (princ-to-string cause) errors))))
    (scene-finish-commit scene time)
    (%reindex world)
    (nreverse errors)))

(defun %welcome (world)
  (list :type "welcome"
        :protocol +protocol-version+
        :display (ataxia.runtime:runtime-socket-name
                  (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world)))
        :outputs (map 'vector (lambda (stage-output) (%output-description world stage-output))
                      (%outputs world))
        :shares (share-descriptions world)
        :windows (map 'vector (lambda (window)
                                (setf (stage-window-report window) (%window-metadata window)))
                      (sort (loop for window being the hash-values of (%windows world)
                                  collect window)
                            #'< :key #'stage-window-id))
        :cameras (map 'vector (lambda (stage-output)
                                (let ((camera (stage-output-camera stage-output)))
                                  (setf (stage-camera-reported camera) nil)
                                  (camera-report stage-output)))
                      (%outputs world))
        :focus (map 'vector (lambda (seat-state)
                              (list :seat (ataxia.kernel:seat-name (stage-seat-seat seat-state))
                                    :window (let ((window (stage-seat-focused seat-state)))
                                              (and window (stage-window-id window)))))
                    (%seat-states world))))

(defun %director-detached (world was-active-p)
  (%release-director-input world)
  (when was-active-p
    (%sync-fallback world)
    (%scene-changed world)))

;;; Output.

(defun %send-to (director message)
  (unless (director-closed-p director)
    (let ((octets (sb-ext:string-to-octets
                   (concatenate 'string (ataxia.world.wire:encode message) (string #\Newline))
                   :external-format :utf-8)))
      (setf (director-output director) (nconc (director-output director) (list octets)))
      (incf (director-output-bytes director) (length octets)))))

(defparameter *coalesce-interval* 0.016d0
  "Minimum seconds between flushes of coalesced drag, pointer and camera updates:
about one frame, so a drag or pan wakes the director at most at display rate.")

(defun %send (world message &key coalesce)
  "Queue MESSAGE for the connected director and start writing it. Messages with
the same COALESCE key replace each other until the next flush; any other
message flushes them first, preserving order."
  (let* ((link (%link world))
         (director (and link (stage-link-director link))))
    (when (and director (director-ready-p director))
      (if coalesce
          (let ((entry (assoc coalesce (director-pending director) :test #'equal)))
            (if entry
                (setf (cdr entry) message)
                (setf (director-pending director)
                      (nconc (director-pending director) (list (cons coalesce message)))))
            (%schedule-coalesced link director))
          (progn
            (%flush-coalesced link director)
            (%send-to director message)
            (%flush-director link director))))))

(defun %flush-coalesced (link director)
  (when (director-pending director)
    (dolist (entry (shiftf (director-pending director) nil))
      (%send-to director (cdr entry)))
    (setf (director-flushed-at director) (%now))
    (%flush-director link director)))

(defun %schedule-coalesced (link director)
  "Flush once the current dispatch settles, at most every *COALESCE-INTERVAL*."
  (unless (director-flush-source director)
    (let* ((runtime (ataxia.kernel:kernel-runtime
                     (ataxia.kernel:world-kernel (stage-link-world link))))
           (wait (- (+ (director-flushed-at director) *coalesce-interval*) (%now)))
           (flush (%guarded (stage-link-world link) :stage-flush
                            (lambda (source)
                              (declare (ignore source))
                              (setf (director-flush-source director) nil)
                              (unless (director-closed-p director)
                                (%flush-coalesced link director))))))
      (if (plusp wait)
          (let ((timer (or (director-flush-timer director)
                           (setf (director-flush-timer director)
                                 (ataxia.runtime:add-event-loop-timer runtime flush)))))
            (setf (director-flush-source director) timer)
            (ataxia.runtime:update-event-loop-timer timer (max 1 (ceiling (* wait 1000)))))
          (setf (director-flush-source director)
                (ataxia.runtime:add-event-loop-idle runtime flush))))))

(defun %watch-writable (director writing-p)
  (unless (eq writing-p (director-writing-p director))
    (setf (director-writing-p director) writing-p)
    (ataxia.runtime:update-event-loop-fd
     (director-source director)
     (logior ataxia.runtime:+event-readable+ (if writing-p ataxia.runtime:+event-writable+ 0)))))

(defun %flush-director (link director)
  (loop while (and (director-output director) (not (director-closed-p director)))
        do (let* ((octets (first (director-output director)))
                  (offset (director-output-offset director))
                  (sent (handler-case
                            (sb-bsd-sockets:socket-send (director-socket director)
                                                        (if (zerop offset)
                                                            octets
                                                            (subseq octets offset))
                                                        nil :nosignal t)
                          (sb-bsd-sockets:socket-error ()
                            (%close-director link director)
                            (return-from %flush-director)))))
             (cond
               ((null sent) (return))
               ((= (+ offset sent) (length octets))
                (pop (director-output director))
                (setf (director-output-offset director) 0)
                (decf (director-output-bytes director) (length octets)))
               (t (setf (director-output-offset director) (+ offset sent))))))
  (unless (director-closed-p director)
    (if (> (director-output-bytes director) *max-pending-output-bytes*)
        (progn (%log "closing director: it stopped reading events")
               (%close-director link director))
        (%watch-writable director (not (null (director-output director)))))))
