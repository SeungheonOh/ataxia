;;;; Event-loop driven IMU viewport rotation.
;;;;
;;;; The controller reads the documented newline JSON stream from a nonblocking
;;;; serial descriptor on libwayland's owner thread. It changes only World
;;;; camera policy; Runtime and Kernel remain unaware of the device.

(in-package #:ataxia.infinite-world)

(cffi:defcfun ("read" %imu-posix-read) :long
  (file-descriptor :int)
  (buffer :pointer)
  (count :unsigned-long))

(cffi:defcfun ("write" %imu-posix-write) :long
  (file-descriptor :int)
  (buffer :pointer)
  (count :unsigned-long))

(defconstant +imu-minimum-confidence+ 0.15d0)
(defconstant +imu-maximum-line-length+ 16384)
(defconstant +imu-reconnect-delay-ms+ 750)
(defparameter +imu-reset-command+ "set_screen_reference
")
(defconstant +imu-control-width+ 184d0)
(defconstant +imu-control-height+ 32d0)

(defparameter +imu-control-source+
  "export component AtaxiaImuControl inherits Window {
    background: transparent;
    in property <bool> pending: false;
    in property <bool> failed: false;
    in property <bool> connected: false;
    callback reset();

    button := Rectangle {
        border-width: 1px;
        border-color: #171717;
        background: touch.pressed ? #171717 : touch.has-hover ? #d8d8d3 : #f4f4ef;

        Text {
            text: !root.connected ? \"IMU DISCONNECTED\" : root.pending ? \"SETTING REFERENCE\" : root.failed ? \"REFERENCE FAILED\" : \"RESET ORIENTATION\";
            color: touch.pressed ? #f4f4ef : #171717;
            font-size: 11px;
            font-weight: 600;
            horizontal-alignment: center;
            vertical-alignment: center;
        }

        touch := TouchArea {
            enabled: !root.pending;
            clicked => { root.reset(); }
        }
    }
}")

(defclass imu-controller ()
  ((device :initarg :device :reader %imu-device)
   (file-descriptor :initform -1 :accessor %imu-file-descriptor)
   (event-source :initform nil :accessor %imu-event-source)
   (reconnect-timer :initform nil :accessor %imu-reconnect-timer)
   (input :initform (make-array 256 :element-type 'character
                                :adjustable t :fill-pointer 0)
          :reader %imu-input)
   (status :initform :connecting :accessor imu-status)
   (sequence :initform nil :accessor %imu-sequence)
   (dropped-records :initform 0 :accessor %imu-dropped-records)
   (timestamp-ms :initform nil :accessor %imu-timestamp-ms)
   (target-radians :initform 0d0 :accessor %imu-target-radians)
   (reset-pending-p :initform nil :accessor %imu-reset-pending-p)))

(defclass imu-control-overlay (canvas-overlay) ())

(defmethod %overlay-output-changed
    ((overlay imu-control-overlay) output-state)
  (%position-imu-control overlay output-state))

(defmethod %destroy-overlay ((overlay imu-control-overlay))
  (let ((component (canvas-overlay-component overlay)))
    (ataxia.world.slint:set-slint-component-invalidator component nil)
    (when (ataxia.world.slint:slint-component-graphics-attached-p component)
      (ataxia.kernel:drawable-detach-graphics component))
    (ataxia.world.slint:destroy-slint-component component))
  nil)

(defmethod imu-status ((world infinite-world))
  (let ((controller (%world-imu-controller world)))
    (if controller
        (list :state (imu-status controller)
              :device (%imu-device controller)
              :sequence (%imu-sequence controller)
              :timestamp-ms (%imu-timestamp-ms controller)
              :dropped-records (%imu-dropped-records controller)
              :target-radians (%imu-target-radians controller))
        '(:state :detached))))

(defun %normalize-radians (radians)
  (let ((turn (* 2d0 pi)))
    (- (mod (+ radians pi) turn) pi)))

(defun %angle-delta (from to)
  (%normalize-radians (- to from)))

(defun %json-field-start (line name)
  (let* ((needle (format nil "\"~A\"" name))
         (field (search needle line)))
    (when field
      (let ((colon (position #\: line :start (+ field (length needle)))))
        (when colon
          (position-if-not
           (lambda (character)
             (member character '(#\Space #\Tab #\Return #\Newline)))
           line :start (1+ colon)))))))

(defun %json-string (line name)
  (let ((start (%json-field-start line name)))
    (when (and start (char= (char line start) #\"))
      (let ((end (position #\" line :start (1+ start))))
        (when end (subseq line (1+ start) end))))))

(defun %json-number (line name)
  (let ((start (%json-field-start line name)))
    (when start
      (let ((end (or (position-if-not
                      (lambda (character)
                        (or (digit-char-p character)
                            (find character "+-.eE")))
                      line :start start)
                     (length line))))
        (when (> end start)
          (handler-case
              (let ((*read-eval* nil)
                    (*read-default-float-format* 'double-float))
                (let ((value (read-from-string (subseq line start end))))
                  (and (realp value) (coerce value 'double-float))))
            (serious-condition () nil)))))))

(defun %json-boolean (line name)
  (let ((start (%json-field-start line name)))
    (cond
      ((and start (<= (+ start 4) (length line))
            (string= "true" line :start2 start :end2 (+ start 4)))
       t)
      ((and start (<= (+ start 5) (length line))
            (string= "false" line :start2 start :end2 (+ start 5)))
       nil)
      (t :missing))))

(defun %set-imu-target (world controller degrees sequence timestamp-ms)
  (let ((radians (%normalize-radians (* (- degrees) (/ pi 180d0)))))
    (when (or (null (%imu-sequence controller))
              (> sequence (%imu-sequence controller)))
      (when (%imu-sequence controller)
        (incf (%imu-dropped-records controller)
              (max 0 (1- (- sequence (%imu-sequence controller))))))
      (setf (%imu-sequence controller) sequence
            (%imu-timestamp-ms controller) timestamp-ms
            (%imu-target-radians controller) radians
            (imu-status controller) :streaming)
      (dolist (state (%output-states world))
        (unless (< (abs (%angle-delta
                         (%canvas-output-rotation state) radians))
                   1d-7)
          (setf (%canvas-output-rotation state) radians
                (%canvas-output-target-rotation state) radians)
          (%full-damage world state)))
      (%update-all-membership world)))
  controller)

(defun %imu-control-for-output (world output)
  (find-if (lambda (overlay)
             (and (typep overlay 'imu-control-overlay)
                  (eq output (canvas-overlay-output overlay))))
           (world-overlays world)))

(defun %position-imu-control (overlay state)
  (multiple-value-bind (output-width output-height)
      (%output-logical-size state)
    (declare (ignore output-height))
    (setf (canvas-overlay-x overlay)
          (max 12d0 (- output-width +imu-control-width+ 12d0))
          (canvas-overlay-y overlay) 12d0
          (canvas-overlay-width overlay) +imu-control-width+
          (canvas-overlay-height overlay) +imu-control-height+)
    (ataxia.world.slint:resize-slint-component
     (canvas-overlay-component overlay)
     +imu-control-width+ +imu-control-height+
     :scale (ataxia.kernel:output-scale (%canvas-output-output state))))
  overlay)

(defun %set-imu-control-state
    (world &key (pending nil pending-p) (failed nil failed-p)
      (connected nil connected-p))
  (dolist (overlay (world-overlays world))
    (when (typep overlay 'imu-control-overlay)
      (let ((component (canvas-overlay-component overlay)))
        (when pending-p
          (ataxia.world.slint:set-slint-property component "pending" pending))
        (when failed-p
          (ataxia.world.slint:set-slint-property component "failed" failed))
        (when connected-p
          (ataxia.world.slint:set-slint-property
           component "connected" connected)))))
  world)

(defun %write-imu-command (controller command)
  (let ((length (length command)))
    (cffi:with-foreign-string (buffer command :encoding :utf-8)
      (let ((written
              (%imu-posix-write
               (%imu-file-descriptor controller) buffer length)))
        (unless (= written length)
          (error "Failed to write IMU command (~D of ~D bytes)."
                 written length)))))
  controller)

(defun %zero-imu-orientation (world controller)
  (setf (%imu-target-radians controller) 0d0)
  (dolist (state (%output-states world))
    (setf (%canvas-output-rotation state) 0d0
          (%canvas-output-target-rotation state) 0d0)
    (%full-damage world state))
  (%update-all-membership world)
  controller)

(defun %reset-imu-reference (world controller)
  (%zero-imu-orientation world controller)
  (setf (%imu-reset-pending-p controller) t)
  (%set-imu-control-state world :pending t :failed nil)
  (if (minusp (%imu-file-descriptor controller))
      (%schedule-imu-reconnect world controller 0)
      (handler-case
          (%write-imu-command controller +imu-reset-command+)
        (serious-condition (condition)
          (%disconnect-imu-controller world controller)
          (setf (imu-status controller) (list :command-error condition)))))
  controller)

(defun %make-imu-control (world state)
  (let* ((output (%canvas-output-output state))
         (component
           (ataxia.world.slint:make-slint-component
            :source +imu-control-source+
            :source-path "ataxia-imu-control.slint"
            :component-name "AtaxiaImuControl"
            :width +imu-control-width+ :height +imu-control-height+
            :scale (ataxia.kernel:output-scale output)))
         (overlay
           (make-instance
            'imu-control-overlay :component component :output output
            :x 0d0 :y 0d0
            :width +imu-control-width+ :height +imu-control-height+
            :layer 900 :visible-p t)))
    (%position-imu-control overlay state)
    (ataxia.world.slint:set-slint-component-invalidator
     component
     (lambda (ignored)
       (declare (ignore ignored))
       (unless (%world-quiescing-p world)
         (%damage-overlay world overlay)
         (%request-output-state-frame world state)
         (%schedule-component-timer world))))
    (ataxia.world.slint:set-slint-callback
     component "reset"
     (lambda (ignored value)
       (declare (ignore ignored value))
       (let ((controller (%world-imu-controller world)))
         (when controller
           (%reset-imu-reference world controller)))))
    (ataxia.world.slint:set-slint-property
     component "connected"
     (not (minusp (%imu-file-descriptor (%world-imu-controller world)))))
    overlay))

(defun %ensure-imu-control (world state)
  (or (%imu-control-for-output world (%canvas-output-output state))
      (add-overlay world (%make-imu-control world state))))

(defun %remove-imu-controls (world)
  (dolist (overlay (remove-if-not
                    (lambda (candidate)
                      (typep candidate 'imu-control-overlay))
                    (copy-list (world-overlays world))))
    (remove-overlay world overlay))
  world)

(defun %accept-reset-status (world controller valid-p)
  (%set-imu-control-state world :pending nil :failed (not valid-p))
  (setf (%imu-reset-pending-p controller) nil)
  (when valid-p
    (%zero-imu-orientation world controller))
  controller)

(defun %handle-imu-line (world controller line)
  (%set-imu-control-state world :connected t)
  (let ((type (%json-string line "type")))
    (cond
      ((string= type "tilt")
       (let ((version (%json-number line "version"))
             (sequence (%json-number line "sequence"))
             (timestamp (%json-number line "timestamp_ms"))
             (degrees (%json-number line "screen_compensation_deg"))
             (confidence (%json-number line "screen_gravity_confidence"))
             (reference (%json-boolean line "screen_reference_valid")))
         (when (and version (= version 1d0) sequence timestamp degrees confidence
                    (eq reference t) (>= confidence +imu-minimum-confidence+))
           (%set-imu-target
            world controller degrees (truncate sequence) (truncate timestamp)))))
      ((string= type "status")
       (let* ((state-name (or (%json-string line "state") "unknown"))
              (state (intern (string-upcase state-name) :keyword)))
         (setf (imu-status controller) state)
         (when (string= state-name "screen_reference_set")
           (%accept-reset-status
            world controller
            (eq (%json-boolean line "screen_reference_valid") t)))))
      ((string= type "error")
       (setf (imu-status controller)
             (list :device-error (%json-string line "code"))))))
  controller)

(defun %consume-imu-byte (world controller byte)
  (let ((input (%imu-input controller)))
    (cond
      ((= byte 10)
       (let ((line (string-right-trim '(#\Return) (coerce input 'string))))
         (setf (fill-pointer input) 0)
         (unless (zerop (length line))
           (%handle-imu-line world controller line))))
      ((>= (length input) +imu-maximum-line-length+)
       (setf (fill-pointer input) 0
             (imu-status controller) :oversized-record))
      ((<= 0 byte 127)
       (vector-push-extend (code-char byte) input))))
  controller)

(defun %drain-imu (world controller)
  (cffi:with-foreign-object (buffer :uint8 4096)
    (loop
      for count = (%imu-posix-read
                   (%imu-file-descriptor controller) buffer 4096)
      while (plusp count)
      do (dotimes (index count)
           (%consume-imu-byte
            world controller (cffi:mem-aref buffer :uint8 index)))
      while (= count 4096)))
  controller)

(defun %imu-ready (world controller source file-descriptor mask)
  (declare (ignore source file-descriptor))
  (when (logtest ataxia.runtime:+event-readable+ mask)
    (%drain-imu world controller))
  (when (logtest (logior ataxia.runtime:+event-hangup+
                         ataxia.runtime:+event-error+)
                 mask)
    (%disconnect-imu-controller world controller))
  0)

(defun %configure-imu-serial (device)
  (uiop:run-program
   (list "stty" "-F" device "115200" "raw" "-echo")
   :output nil :error-output nil)
  device)

(defun %close-imu-stream (controller)
  (when (%imu-event-source controller)
    (ataxia.runtime:remove-event-loop-source (%imu-event-source controller))
    (setf (%imu-event-source controller) nil))
  (unless (minusp (%imu-file-descriptor controller))
    (ignore-errors (sb-posix:close (%imu-file-descriptor controller)))
    (setf (%imu-file-descriptor controller) -1))
  controller)

(defun %cancel-imu-reconnect (controller)
  (when (%imu-reconnect-timer controller)
    (ataxia.runtime:remove-event-loop-source (%imu-reconnect-timer controller))
    (setf (%imu-reconnect-timer controller) nil))
  controller)

(defun %connect-imu-controller (world controller)
  (%close-imu-stream controller)
  (handler-case
      (progn
        (%configure-imu-serial (%imu-device controller))
        (let ((file-descriptor
                (sb-posix:open
                 (%imu-device controller)
                 (logior sb-posix:o-rdwr sb-posix:o-noctty
                         sb-posix:o-nonblock))))
          (setf (%imu-file-descriptor controller) file-descriptor)
          (setf (%imu-event-source controller)
                (ataxia.runtime:add-event-loop-fd
                 (ataxia.kernel:kernel-runtime
                  (ataxia.kernel:world-kernel world))
                 file-descriptor ataxia.runtime:+event-readable+
                 (lambda (source descriptor mask)
                   (%imu-ready world controller source descriptor mask)))))
        (setf (fill-pointer (%imu-input controller)) 0
              (%imu-sequence controller) nil
              (%imu-timestamp-ms controller) nil
              (%imu-dropped-records controller) 0
              (imu-status controller) :waiting)
        (%set-imu-control-state
         world :failed nil :connected nil)
        (when (%imu-reset-pending-p controller)
          (%write-imu-command controller +imu-reset-command+))
        (format *error-output*
                "[infinite-world] IMU connected: ~A~%"
                (%imu-device controller))
        t)
    (serious-condition ()
      (%close-imu-stream controller)
      (setf (imu-status controller) :reconnecting)
      (%set-imu-control-state
       world :pending nil :failed nil :connected nil)
      nil)))

(defun %schedule-imu-reconnect
    (world controller &optional (delay +imu-reconnect-delay-ms+))
  (when (and (eq controller (%world-imu-controller world))
             (not (%world-quiescing-p world)))
    (unless (%imu-reconnect-timer controller)
      (setf (%imu-reconnect-timer controller)
            (ataxia.runtime:add-event-loop-timer
             (ataxia.kernel:kernel-runtime
              (ataxia.kernel:world-kernel world))
             (lambda (source)
               (if (%connect-imu-controller world controller)
                   (progn
                     (setf (%imu-reconnect-timer controller) nil)
                     (ataxia.runtime:remove-event-loop-source source))
                   (ataxia.runtime:update-event-loop-timer
                    source +imu-reconnect-delay-ms+))
               0))))
    (ataxia.runtime:update-event-loop-timer
     (%imu-reconnect-timer controller) (max 1 delay)))
  controller)

(defun %disconnect-imu-controller (world controller)
  (%close-imu-stream controller)
  (setf (imu-status controller) :reconnecting)
  (%set-imu-control-state
   world :pending nil :failed nil :connected nil)
  (%schedule-imu-reconnect world controller)
  controller)

(defun attach-imu (world device)
  "Attach a version-1 gyro serial stream to WORLD's libwayland event loop."
  (check-type world infinite-world)
  (check-type device string)
  (unless (ataxia.kernel:world-kernel world)
    (error "Cannot attach IMU before the World is attached."))
  (detach-imu world)
  (let ((controller (make-instance 'imu-controller :device device)))
    (setf (%world-imu-controller world) controller)
    (dolist (state (%output-states world))
      (%ensure-imu-control world state))
    (unless (%connect-imu-controller world controller)
      (%schedule-imu-reconnect world controller 0))
    controller))

(defun detach-imu (world)
  "Remove WORLD's IMU event source and close its descriptor."
  (check-type world infinite-world)
  (let ((controller (%world-imu-controller world)))
    (when controller
      (%remove-imu-controls world)
      (%cancel-imu-reconnect controller)
      (%close-imu-stream controller)
      (setf (%world-imu-controller world) nil)))
  world)

(defmethod ataxia.kernel:world-attached :after
    ((world infinite-world) kernel)
  (declare (ignore kernel))
  (let ((device (uiop:getenv "ATAXIA_IMU_DEVICE")))
    (when (and device (plusp (length device)))
      (handler-case
          (attach-imu world device)
        (serious-condition (condition)
          (format *error-output*
                  "[infinite-world] IMU unavailable (~A): ~A~%"
                  device condition)))))
  world)

(defmethod ataxia.kernel:world-quiescing :before
    ((world infinite-world) reason)
  (declare (ignore reason))
  (detach-imu world))

(defmethod ataxia.kernel:world-output-added :after
    ((world infinite-world) output)
  (let ((controller (%world-imu-controller world))
        (state (gethash output (%world-outputs world))))
    (when (and controller state)
      (setf (%canvas-output-rotation state) (%imu-target-radians controller)
            (%canvas-output-target-rotation state) (%imu-target-radians controller))
      (%ensure-imu-control world state)))
  output)
