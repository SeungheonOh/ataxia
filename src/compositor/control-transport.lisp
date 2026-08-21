;;;; Local agent control transport.
;;;;
;;;; A mode-0600 Unix socket accepts newline-delimited, read-eval-disabled Lisp
;;;; data. Requests decode into the same capability-checked actions used by
;;;; in-process callers; arbitrary forms are never evaluated.

(in-package #:ataxia.compositor)

(defconstant +address-family-unix+ 1)
(defconstant +socket-stream+ 1)
(defconstant +socket-nonblock+ #x800)
(defconstant +socket-cloexec+ #x80000)
(defconstant +socket-level+ 1)
(defconstant +socket-peer-credentials+ 17)
(defconstant +message-no-signal+ #x4000)
(defconstant +try-again+ 11)

(defparameter *trace-control-p*
  (not (null (uiop:getenv "ATAXIA_TRACE_CONTROL"))))

(defun trace-control (control &rest arguments)
  (when *trace-control-p*
    (apply #'format *error-output* control arguments)
    (finish-output *error-output*)))

(cffi:defcstruct unix-socket-address
  (family :unsigned-short)
  (path (:array :char 108)))

(cffi:defcstruct peer-credentials
  (process-id :int)
  (user-id :uint32)
  (group-id :uint32))

(cffi:defcfun ("socket" %posix-socket) :int
  (domain :int) (type :int) (protocol :int))
(cffi:defcfun ("bind" %posix-bind) :int
  (file-descriptor :int) (address :pointer) (length :uint32))
(cffi:defcfun ("listen" %posix-listen) :int
  (file-descriptor :int) (backlog :int))
(cffi:defcfun ("accept4" %posix-accept4) :int
  (file-descriptor :int) (address :pointer) (length :pointer) (flags :int))
(cffi:defcfun ("recv" %posix-receive) :long
  (file-descriptor :int) (buffer :pointer) (length :unsigned-long)
  (flags :int))
(cffi:defcfun ("send" %posix-send) :long
  (file-descriptor :int) (buffer :pointer) (length :unsigned-long)
  (flags :int))
(cffi:defcfun ("chmod" %posix-chmod) :int
  (path :string) (mode :uint32))
(cffi:defcfun ("getpid" %posix-get-process-id) :int)
(cffi:defcfun ("getsockopt" %posix-get-socket-option) :int
  (file-descriptor :int) (level :int) (option :int)
  (value :pointer) (length :pointer))
(cffi:defcfun ("__errno_location" %errno-location) :pointer)

(defun current-errno ()
  (cffi:mem-ref (%errno-location) :int))

(defclass control-connection ()
  ((file-descriptor :initarg :file-descriptor
                    :reader connection-file-descriptor)
   (source :initform nil :accessor connection-source)
   (principal :initarg :principal :reader connection-principal)
   (input :initform (make-array 0 :element-type '(unsigned-byte 8)
                                  :adjustable t :fill-pointer 0)
          :accessor connection-input)
   (output :initform (make-array 0 :element-type '(unsigned-byte 8)
                                   :adjustable t :fill-pointer 0)
           :accessor connection-output)
   (closed-p :initform nil :accessor connection-closed-p)))

(defgeneric decode-control-action (control principal specification))
(defgeneric decode-control-placement (policy specification))

(defun default-control-socket-path ()
  (or (uiop:getenv "ATAXIA_CONTROL_SOCKET")
      (format nil "~A/ataxia-control-~D.sock"
              (or (uiop:getenv "XDG_RUNTIME_DIR") "/tmp")
              (%posix-get-process-id))))

(defun string-octets (string)
  #+sbcl (sb-ext:string-to-octets string :external-format :utf-8)
  #-sbcl (map '(vector (unsigned-byte 8)) #'char-code string))

(defun octets-string (octets)
  #+sbcl (sb-ext:octets-to-string octets :external-format :utf-8)
  #-sbcl (map 'string #'code-char octets))

(defun append-octets (target octets &optional (start 0))
  (loop for index from start below (length octets)
        do (vector-push-extend (aref octets index) target))
  target)

(defun peer-control-principal (file-descriptor)
  (cffi:with-foreign-objects ((credentials '(:struct peer-credentials))
                              (length :uint32))
    (setf (cffi:mem-ref length :uint32)
          (cffi:foreign-type-size '(:struct peer-credentials)))
    (if (zerop (%posix-get-socket-option
                file-descriptor +socket-level+ +socket-peer-credentials+
                credentials length))
        (make-instance
         'control-principal
         :identity
         (list :pid
               (cffi:foreign-slot-value
                credentials '(:struct peer-credentials) 'process-id)
               :uid
               (cffi:foreign-slot-value
                credentials '(:struct peer-credentials) 'user-id)
               :gid
               (cffi:foreign-slot-value
                credentials '(:struct peer-credentials) 'group-id))
         :capabilities
         '(:observe :focus :move :seat :behavior-policy :viewport :launch
           :animation :shader))
        (error 'control-request-rejected
               :action :connect :reason :peer-credentials-unavailable))))

(defun control-view-by-id (control identifier)
  (or (find identifier
            (desktop-views
             (compositor-desktop (component-compositor control)))
            :key #'view-id :test #'eql)
      (error 'control-request-rejected
             :action :decode :reason (list :unknown-view identifier))))

(defun control-seat-by-name (control name)
  (or (find name
            (interaction-seats
             (compositor-interaction (component-compositor control)))
            :key #'seat-name :test #'string=)
      (error 'control-request-rejected
             :action :decode :reason (list :unknown-seat name))))

(defun control-output-by-name (control name)
  (or (find name
            (compositor-outputs-list
             (compositor-outputs (component-compositor control)))
            :key (lambda (output)
                   (ataxia.runtime:output-name (output-native output)))
            :test #'string=)
      (error 'control-request-rejected
             :action :decode :reason (list :unknown-output name))))

(defun control-device-by-name (control name)
  (let ((matches nil))
    (maphash
     (lambda (device seat)
       (declare (ignore seat))
       (when (string= name (ataxia.runtime:input-device-name device))
         (push device matches)))
     (interaction-device-seats
      (compositor-interaction (component-compositor control))))
    (if (= 1 (length matches))
        (first matches)
        (error 'control-request-rejected
               :action :decode
               :reason (list :input-device-match-count name
                             (length matches))))))

(defun required-command-value (properties key)
  (let ((marker (list :missing)))
    (let ((value (getf properties key marker)))
      (if (eq value marker)
          (error 'control-request-rejected
                 :action :decode :reason (list :missing key))
          value))))

(defun decode-animation-property (specification)
  (typecase specification
    (keyword
     (ecase specification
       (:opacity 'opacity) (:scale 'scale)
       (:offset-x 'offset-x) (:offset-y 'offset-y)))
    (cons
     (ecase (first specification)
       (:uniform
        (make-instance 'shader-uniform-binding
                       :name (second specification)))
       (:effect
        (make-instance 'effect-parameter-binding
                       :name (second specification)))))
    (t
     (error 'control-request-rejected
            :action :decode :reason :invalid-animation-property))))

(defun decode-animation-definition (specification)
  (let ((duration (required-command-value specification :duration))
        (tracks (required-command-value specification :tracks)))
    (unless (and (realp duration) (not (minusp duration)) (listp tracks))
      (error 'control-request-rejected
             :action :decode :reason :invalid-animation-definition))
    (make-instance
     'animation-definition
     :name (getf specification :name)
     :duration (coerce duration 'double-float)
     :tracks
     (mapcar
      (lambda (track)
        (let ((easing (getf track :easing :ease-out-cubic)))
          (make-instance
           'animation-track
           :property
           (decode-animation-property
            (required-command-value track :property))
           :from (required-command-value track :from)
           :to (required-command-value track :to)
           :interpolator
           (ecase easing
             (:linear #'linear-interpolation)
             (:ease-out-cubic #'ease-out-cubic)))))
      tracks))))

(defun control-transition-class (name)
  (ecase name
    (:visibility 'visibility-transition)
    (:placement 'placement-transition)
    (:interaction 'interaction-transition)
    (:content 'content-transition)))

(defmethod decode-control-placement
    ((policy planar-behavior-policy) specification)
  (make-instance
   'planar-placement
   :x (coerce (required-command-value specification :x) 'double-float)
   :y (coerce (required-command-value specification :y) 'double-float)
   :width (coerce (required-command-value specification :width) 'double-float)
   :height (coerce (required-command-value specification :height) 'double-float)
   :z (coerce (getf specification :z 0d0) 'double-float)))

(defmethod decode-control-placement
    ((policy spherical-behavior-policy) specification)
  (make-instance
   'spherical-placement
   :longitude
   (coerce (required-command-value specification :longitude) 'double-float)
   :latitude
   (coerce (required-command-value specification :latitude) 'double-float)
   :angular-width
   (coerce (required-command-value specification :angular-width) 'double-float)
   :angular-height
   (coerce (required-command-value specification :angular-height) 'double-float)
   :depth (coerce (getf specification :depth 0d0) 'double-float)))

(defmethod decode-control-action
    ((control control-system) (principal control-principal) specification)
  (unless (and (consp specification) (keywordp (first specification)))
    (error 'control-request-rejected
           :action :decode :reason :invalid-action))
  (let* ((kind (first specification))
         (properties (rest specification))
         (compositor (component-compositor control)))
    (flet ((view ()
             (control-view-by-id
              control (required-command-value properties :view)))
           (seat ()
             (control-seat-by-name
              control (required-command-value properties :seat)))
           (output ()
             (control-output-by-name
              control (required-command-value properties :output))))
      (ecase kind
        (:observe
         (make-instance 'observe-compositor-action :principal principal))
        (:focus
         (make-instance
          'focus-view-action :principal principal :seat (seat)
          :view (let ((identifier (getf properties :view)))
                  (and identifier (control-view-by-id control identifier)))))
        (:move
         (make-instance
          'move-view-action :principal principal :view (view)
          :x (required-command-value properties :x)
          :y (required-command-value properties :y)))
        (:place
         (make-instance
          'place-view-action :principal principal :view (view)
          :placement
          (decode-control-placement
           (compositor-behavior-policy compositor)
           (required-command-value properties :placement))))
        (:create-seat
         (make-instance
          'create-seat-action :principal principal
          :name (required-command-value properties :name)
          :pointer-x (getf properties :pointer-x 160d0)
          :pointer-y (getf properties :pointer-y 100d0)))
        (:destroy-seat
         (make-instance 'destroy-seat-action :principal principal :seat (seat)))
        (:assign-input
         (make-instance
          'assign-input-device-action :principal principal :seat (seat)
          :device
          (control-device-by-name
           control (required-command-value properties :device))))
        (:replace-behavior
         (make-instance
          'replace-behavior-policy-action :principal principal
          :policy
          (make-instance
           (ecase (required-command-value properties :kind)
             (:planar 'planar-behavior-policy)
             (:spherical 'spherical-behavior-policy))
           :compositor compositor)))
        (:pan
         (make-instance
          'pan-viewport-action :principal principal :output (output)
          :delta-x (required-command-value properties :delta-x)
          :delta-y (required-command-value properties :delta-y)))
        (:zoom
         (make-instance
          'zoom-viewport-action :principal principal :output (output)
          :factor (required-command-value properties :factor)
          :anchor-x (required-command-value properties :anchor-x)
          :anchor-y (required-command-value properties :anchor-y)))
        (:launch
         (make-instance
          'launch-application-action :principal principal
          :command (required-command-value properties :command)))
        (:set-animation
         (make-instance
          'set-view-animation-action :principal principal :view (view)
          :descriptor-class
          (control-transition-class
           (required-command-value properties :transition))
          :definition
          (decode-animation-definition
           (required-command-value properties :definition))))
        (:install-shader
         (make-instance
          'install-shader-program-action :principal principal
          :name (required-command-value properties :name)
          :descriptor
          (let ((fragment
                  (required-command-value properties :fragment-source))
                (uniforms
                  (required-command-value properties :uniforms))
                (kind (getf properties :kind :material))
                (vertex (getf properties :vertex-source)))
            (if (eq kind :material)
                (make-material-program-descriptor
                 fragment uniforms :vertex-source
                 (or vertex +builtin-vertex-shader+))
                (make-texture-program-descriptor
                 fragment uniforms kind :vertex-source
                 (or vertex +builtin-vertex-shader+))))))
        (:configure-shader
         (make-instance
          'configure-view-shader-action :principal principal :view (view)
          :program-name (getf properties :program-name)
          :uniforms (getf properties :uniforms)))))))

(defun serializable-control-value (value)
  (typecase value
    ((or null string number) value)
    ((eql t) t)
    (keyword value)
    (symbol (symbol-name value))
    (view (list :view (view-id value)))
    (logical-seat (list :seat (seat-name value)))
    (compositor-output
     (list :output (ataxia.runtime:output-name (output-native value))))
    (behavior-policy
     (list :behavior-policy
           (symbol-name (class-name (class-of value)))))
    (animation-definition
     (list :animation (animation-definition-name value)
           :duration (animation-definition-duration value)))
    (shader-program
     (list :shader-program (shader-program-state value)))
    (cons
     (cons (serializable-control-value (car value))
           (serializable-control-value (cdr value))))
    (vector (map 'vector #'serializable-control-value value))
    (t :submitted)))

(defun parse-control-request (line)
  (let ((*read-eval* nil))
    (multiple-value-bind (form position)
        (read-from-string line nil :end-of-input)
      (when (eq form :end-of-input)
        (error 'control-request-rejected
               :action :decode :reason :empty-request))
      (unless (every (lambda (character)
                       (find character " \t\r\n"))
                     (subseq line position))
        (error 'control-request-rejected
               :action :decode :reason :trailing-data))
      form)))

(defun execute-control-request (control connection line)
  (let ((identifier nil))
    (handler-case
        (let* ((request (parse-control-request line))
               (action-specification
                 (progn
                   (unless (listp request)
                     (error 'control-request-rejected
                            :action :decode :reason :invalid-request))
                   (setf identifier (getf request :id))
                   (required-command-value request :action)))
               (action
                 (decode-control-action
                  control (connection-principal connection)
                  action-specification))
               (result (submit-control-action control action)))
          (list :id identifier :ok t
                :result (serializable-control-value result)))
      (serious-condition (condition)
        (list :id identifier :ok nil
              :error (princ-to-string condition))))))

(defun update-control-connection-mask (connection)
  (when (and (connection-source connection)
             (ataxia.runtime:native-object-live-p
              (connection-source connection)))
    (ataxia.runtime:update-event-loop-fd
     (connection-source connection)
     (logior ataxia.runtime:+event-readable+
             (if (plusp (length (connection-output connection)))
                 ataxia.runtime:+event-writable+
                 0)))))

(defun queue-control-response (control connection response)
  (append-octets
   (connection-output connection)
   (string-octets (format nil "~S~%" response)))
  (flush-control-output control connection))

(defun close-control-connection (control connection)
  (unless (connection-closed-p connection)
    (setf (connection-closed-p connection) t)
    (when (and (connection-source connection)
               (ataxia.runtime:native-object-live-p
                (connection-source connection)))
      (ataxia.runtime:remove-event-loop-source
       (connection-source connection)))
    (%posix-close (connection-file-descriptor connection))
    (remhash (connection-file-descriptor connection)
             (control-connections control)))
  nil)

(defun flush-control-output (control connection)
  (let ((output (connection-output connection)))
    (when (plusp (length output))
      (let ((packet
              (make-array
               (length output) :element-type '(unsigned-byte 8)
               :initial-contents output)))
        (cffi:with-pointer-to-vector-data (pointer packet)
        (let ((written
                (%posix-send
                 (connection-file-descriptor connection) pointer
                 (length packet) +message-no-signal+)))
          (trace-control "[control] send fd=~D bytes=~D errno=~D~%"
                         (connection-file-descriptor connection)
                         written (if (minusp written) (current-errno) 0))
          (cond
            ((plusp written)
             (let ((remaining (subseq packet written)))
               (setf (connection-output connection)
                     (make-array
                      (length remaining) :element-type '(unsigned-byte 8)
                      :adjustable t :fill-pointer (length remaining)
                      :initial-contents remaining))))
            ((and (minusp written) (/= (current-errno) +try-again+))
             (close-control-connection control connection)))))))
  (unless (connection-closed-p connection)
    (update-control-connection-mask connection))))

(defun consume-control-lines (control connection)
  (loop
    for input = (connection-input connection)
    for newline = (position 10 input)
    while newline
    do (let* ((line-octets (subseq input 0 newline))
              (remaining (subseq input (1+ newline))))
         (setf (connection-input connection)
               (make-array
                (length remaining) :element-type '(unsigned-byte 8)
                :adjustable t :fill-pointer (length remaining)
                :initial-contents remaining))
         (queue-control-response
          control connection
          (execute-control-request
           control connection (octets-string line-octets))))))

(defun receive-control-input (control connection)
  (cffi:with-foreign-object (buffer :uint8 8192)
    (loop
      for count = (%posix-receive
                   (connection-file-descriptor connection) buffer 8192 0)
      do (trace-control "[control] receive fd=~D bytes=~D errno=~D~%"
                        (connection-file-descriptor connection)
                        count (if (minusp count) (current-errno) 0))
         (cond
           ((plusp count)
            (dotimes (index count)
              (vector-push-extend
               (cffi:mem-aref buffer :uint8 index)
               (connection-input connection)))
            (when (> (length (connection-input connection))
                     (control-request-byte-limit control))
              (queue-control-response
               control connection
               (list :id nil :ok nil :error "request byte limit exceeded"))
              (close-control-connection control connection)
              (return))
            (consume-control-lines control connection))
           ((zerop count)
            (close-control-connection control connection)
            (return))
           ((= (current-errno) +try-again+) (return))
           (t
            (close-control-connection control connection)
            (return)))))
  (unless (connection-closed-p connection)
    (consume-control-lines control connection)))

(defun dispatch-control-connection (control connection mask)
  (when (logtest ataxia.runtime:+event-readable+ mask)
    (receive-control-input control connection))
  (when (and (not (connection-closed-p connection))
             (logtest ataxia.runtime:+event-writable+ mask))
    (flush-control-output control connection))
  (when (and (not (connection-closed-p connection))
             (logtest (logior ataxia.runtime:+event-hangup+
                              ataxia.runtime:+event-error+)
                      mask))
    (close-control-connection control connection))
  0)

(defun register-control-connection (control file-descriptor)
  (when (>= (hash-table-count (control-connections control))
            (control-connection-limit control))
    (%posix-close file-descriptor)
    (return-from register-control-connection nil))
  (let ((connection
          (make-instance
           'control-connection :file-descriptor file-descriptor
           :principal (peer-control-principal file-descriptor))))
    (trace-control "[control] accepted fd=~D~%" file-descriptor)
    (setf (gethash file-descriptor (control-connections control)) connection
          (connection-source connection)
          (ataxia.runtime:add-event-loop-fd
           (compositor-runtime (component-compositor control))
           file-descriptor ataxia.runtime:+event-readable+
           (lambda (source descriptor mask)
             (declare (ignore source descriptor))
             (dispatch-control-connection control connection mask))))
    file-descriptor))

(defun accept-control-connections (control)
  (loop
    for file-descriptor =
      (%posix-accept4
       (control-listen-file-descriptor control)
       (cffi:null-pointer) (cffi:null-pointer)
       (logior +socket-nonblock+ +socket-cloexec+))
    do (cond
         ((not (minusp file-descriptor))
          (handler-case
              (register-control-connection control file-descriptor)
            (serious-condition (condition)
              (format *error-output*
                      "[control] rejected connection: ~A~%" condition)
              (finish-output *error-output*)
              (%posix-close file-descriptor))))
         ((= (current-errno) +try-again+) (return))
         (t
          (error 'control-request-rejected
                 :action :accept :reason (current-errno)))))
  0)

(defun bind-control-socket (file-descriptor path)
  (let ((octets (string-octets path)))
    (when (>= (length octets) 108)
      (error 'control-request-rejected
             :action :listen :reason :socket-path-too-long))
    (cffi:with-foreign-object (address '(:struct unix-socket-address))
      (setf (cffi:foreign-slot-value
             address '(:struct unix-socket-address) 'family)
            +address-family-unix+)
      (let ((path-pointer
              (cffi:foreign-slot-pointer
               address '(:struct unix-socket-address) 'path)))
        (dotimes (index 108)
          (setf (cffi:mem-aref path-pointer :uint8 index) 0))
        (dotimes (index (length octets))
          (setf (cffi:mem-aref path-pointer :uint8 index)
                (aref octets index))))
      (unless (zerop
               (%posix-bind
                file-descriptor address
                (cffi:foreign-type-size '(:struct unix-socket-address))))
        (error 'control-request-rejected
               :action :listen :reason (list :bind (current-errno)))))))

(defun start-control-transport (control)
  (let* ((path (or (control-socket-path control)
                   (default-control-socket-path)))
         (file-descriptor
           (%posix-socket
            +address-family-unix+
            (logior +socket-stream+ +socket-nonblock+ +socket-cloexec+) 0)))
    (when (minusp file-descriptor)
      (error 'control-request-rejected
             :action :listen :reason (list :socket (current-errno))))
    (setf (control-socket-path control) path
          (control-listen-file-descriptor control) file-descriptor)
    (handler-case
        (progn
          (bind-control-socket file-descriptor path)
          (unless (zerop (%posix-chmod path #o600))
            (error 'control-request-rejected
                   :action :listen :reason (list :chmod (current-errno))))
          (unless (zerop (%posix-listen file-descriptor 16))
            (error 'control-request-rejected
                   :action :listen :reason (list :listen (current-errno))))
          (setf
           (control-listen-source control)
           (ataxia.runtime:add-event-loop-fd
            (compositor-runtime (component-compositor control))
            file-descriptor ataxia.runtime:+event-readable+
            (lambda (source descriptor mask)
              (declare (ignore source descriptor))
              (handler-case
                  (if (logtest ataxia.runtime:+event-readable+ mask)
                      (accept-control-connections control)
                      0)
                (serious-condition (condition)
                  (format *error-output*
                          "[control] listener failed: ~A~%" condition)
                  (finish-output *error-output*)
                  0))))))
      (serious-condition (condition)
        (ignore-errors (stop-control-transport control))
        (error condition))))
  control)

(defun stop-control-transport (control)
  (let ((connections nil))
    (maphash (lambda (descriptor connection)
               (declare (ignore descriptor))
               (push connection connections))
             (control-connections control))
    (dolist (connection connections)
      (close-control-connection control connection)))
  (when (and (control-listen-source control)
             (ataxia.runtime:native-object-live-p
              (control-listen-source control)))
    (ataxia.runtime:remove-event-loop-source
     (control-listen-source control)))
  (setf (control-listen-source control) nil)
  (unless (minusp (control-listen-file-descriptor control))
    (%posix-close (control-listen-file-descriptor control))
    (setf (control-listen-file-descriptor control) -1))
  (let ((path (control-socket-path control)))
    (when (and path (probe-file path))
      (delete-file path)))
  control)
