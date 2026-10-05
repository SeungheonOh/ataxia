(in-package #:ataxia.assistant)

(defun %assistant-schema (type &rest options)
  (apply #'%assistant-object "type" type options))
(defun %assistant-object-schema (properties &optional (required #()))
  (%assistant-schema "object" "properties" properties "required" required "additionalProperties" :false))
(defun %assistant-tool-spec (name description properties &optional required)
  (%assistant-object "type" "function" "name" name "description" description
                     "inputSchema" (%assistant-object-schema properties (or required #()))))
(defun %assistant-tool-specs (world)
  (declare (ignore world))
  (let ((string (%assistant-schema "string")) (integer (%assistant-schema "integer")))
    (vector
     (%assistant-tool-spec "ataxia_lisp"
       "Evaluate Common Lisp in running Ataxia. This is the desktop interface for World inspection/control and application input/capture. inspect/apply bind WORLD on its owner thread with a 250 ms budget; apply also refreshes it. worker runs off-thread with a 30 s budget and binds WORLD to NIL. All modes bind AGENT to this task. Use worker mode for ataxia.agent:capture-window, click, press-key, type-text, paste and scroll; these handle owner-thread entry and wait for client work. Capture emits an image automatically. Batch related Lisp operations and return compact results. Inspect mode may call World methods that already record damage. Read/compile happens off-thread; never ASDF-reload the live World or install classes on a worker. Errors do not replace the World, roll back partial mutations or replay actions. Never change kernel/runtime/native code."
       (%assistant-object "code" (%assistant-schema "string" "maxLength" 32768)
                          "mode" (%assistant-schema "string" "enum" #("inspect" "apply" "worker"))) #("code" "mode"))
     (%assistant-tool-spec "ataxia_ui_preview"
       "Launch a dedicated process and interactive Wayland window for an RML file. Returns its preview ID and window ID, plus an image. Test behavior with the Lisp application functions. JavaScript, arbitrary callbacks and file saving are unavailable."
       (%assistant-object "path" string "width" integer "height" integer) #("path"))
     (%assistant-tool-spec "ataxia_ui_update"
       "Validate and replace an existing preview document after editing its RML file. Failed updates preserve the working preview; successful updates reset unsaved form values. Test the updated app with Lisp input/capture."
       (%assistant-object "preview" string "path" string) #("preview" "path")))))

(defparameter +assistant-base64-alphabet+ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
(defun %assistant-base64 (bytes)
  (let* ((size (length bytes)) (result (make-string (* 4 (ceiling size 3)) :initial-element #\=)))
    (loop for i from 0 below size by 3 for j from 0 by 4 do
      (let* ((a (aref bytes i)) (b (if (< (1+ i) size) (aref bytes (1+ i)) 0))
             (c (if (< (+ i 2) size) (aref bytes (+ i 2)) 0)) (bits (logior (ash a 16) (ash b 8) c)))
        (setf (char result j) (char +assistant-base64-alphabet+ (ldb (byte 6 18) bits))
              (char result (1+ j)) (char +assistant-base64-alphabet+ (ldb (byte 6 12) bits)))
        (when (< (1+ i) size) (setf (char result (+ j 2)) (char +assistant-base64-alphabet+ (ldb (byte 6 6) bits))))
        (when (< (+ i 2) size) (setf (char result (+ j 3)) (char +assistant-base64-alphabet+ (ldb (byte 6 0) bits))))))
    result))
(defun %assistant-image-bytes (image)
  ;; Capture files may be replaced by the next capture. Copy them on the worker
  ;; before another Lisp operation can invalidate a returned image.
  (or (getf image :bytes)
      (with-open-file (stream (getf image :path) :element-type '(unsigned-byte 8))
        (let* ((size (file-length stream))
               (bytes (progn
                        (when (> size (* 5 1024 1024)) (error "The captured image exceeds 5 MiB."))
                        (make-array size :element-type '(unsigned-byte 8)))))
          (unless (= size (read-sequence bytes stream)) (error "Incomplete screenshot."))
          bytes))))
(defun %assistant-image-metadata (image)
  (let ((copy (copy-list image)))
    (remf copy :path) (remf copy :bytes) copy))
(defun %assistant-tool-result (result)
  (let ((items nil) (metadata (copy-list result)))
    (dolist (image (append (when (getf result :image) (list (getf result :image))) (getf result :images)))
      (push (%assistant-object "type" "inputImage" "imageUrl"
              (concatenate 'string "data:image/png;base64," (%assistant-base64 (%assistant-image-bytes image)))) items))
    (when (getf result :image) (setf (getf metadata :image) (%assistant-image-metadata (getf result :image))))
    (when (getf result :images) (setf (getf metadata :images) (map 'vector #'%assistant-image-metadata (getf result :images))))
    (push (%assistant-object "type" "inputText" "text" (ataxia.world.wire:encode metadata)) items)
    (%assistant-object "success" (if (eq :false (getf result :ok)) :false t)
                       "contentItems" (coerce (nreverse items) 'vector))))
(defun %assistant-tool-failure (cause)
  (%assistant-object "success" :false "contentItems"
    (vector (%assistant-object "type" "inputText" "text" (%assistant-text (princ-to-string cause) 4096)))))
(defun %assistant-require-task (controller)
  (unless (and (assistant-controller-alive controller) (not (assistant-controller-blocked controller)))
    (error "The task is paused. Wait for the user to Send or Resume.")))
(defun %assistant-native-request (controller request)
  (let ((result
         (%assistant-owner controller
           (lambda ()
             (%assistant-require-task controller)
             (let ((session (%assistant-ensure-session controller)))
               (setf (getf request :token) (cu:computer-session-token session)
                     (getf request :sequence) (1+ (cu:computer-session-sequence session)))
               (cu:request-on-owner (assistant-controller-world controller) request))))))
    (cu:finish-request result)))
(defun %assistant-run-tool (controller name arguments)
  (unless (hash-table-p arguments) (error "Tool arguments must be an object."))
  (%assistant-owner controller (lambda () (%assistant-require-task controller)))
  (cond
    ((equal name "ataxia_lisp") (%assistant-evaluate-lisp controller arguments))
    ((equal name "ataxia_ui_preview") (%assistant-preview controller arguments))
    ((equal name "ataxia_ui_update") (%assistant-preview-update controller arguments))
    (t (error "Unknown Ataxia tool ~A." name))))
(defun %assistant-dispatch-tool (controller id params)
  (let* ((name (gethash "tool" params))
         (call-id (gethash "callId" params))
         (key (list (gethash "threadId" params) (gethash "turnId" params) call-id))
         (seen (gethash key (assistant-controller-seen-calls controller))))
    (unless (and (stringp call-id) (equal (gethash "turnId" params) (assistant-controller-turn-id controller)))
      (error "Missing or stale tool-call identity."))
    (when seen
      (%assistant-result controller id (if (eq seen :running) (%assistant-tool-failure "This call is already running.") seen))
      (return-from %assistant-dispatch-tool nil))
    (when (and (assistant-controller-tool-worker controller)
               (sb-thread:thread-alive-p (assistant-controller-tool-worker controller)))
      (%assistant-result controller id (%assistant-tool-failure "A desktop tool is already running. Call tools sequentially."))
      (return-from %assistant-dispatch-tool nil))
    (when (> (incf (assistant-controller-tool-count controller)) *assistant-tool-limit*)
      (%assistant-owner controller (lambda () (%assistant-pause controller (format nil "Paused after ~D operations" *assistant-tool-limit*))))
      (error "The task reached its operation limit."))
    (%assistant-journal controller "accepted" "call" call-id "tool" name)
    (setf (gethash key (assistant-controller-seen-calls controller)) :running)
    (%assistant-state controller :activity
      (or (cdr (assoc name '(("ataxia_lisp" . "Using Lisp")
                            ("ataxia_ui_preview" . "Opening the app preview")
                            ("ataxia_ui_update" . "Updating the app preview")) :test #'equal)) name))
    (let ((epoch (assistant-controller-epoch controller)))
      (setf (assistant-controller-tool-worker controller)
        (sb-thread:make-thread
         (lambda ()
           (let* ((*assistant-operation-epoch* epoch)
                  (result (handler-case
                           (%assistant-tool-result (%assistant-run-tool controller name (gethash "arguments" params)))
                           (serious-condition (cause) (%assistant-tool-failure cause)))))
             ;; The worker alone owns the response cache; the tool thread posts completion.
             (when (= epoch (assistant-controller-epoch controller))
               (ignore-errors (%assistant-queue controller :tool-result (list key id result))))))
         :name "Ataxia assistant tool")))))
