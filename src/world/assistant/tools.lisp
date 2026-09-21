(in-package #:ataxia.assistant)

(defun %assistant-schema (type &rest options)
  (apply #'%assistant-object "type" type options))
(defun %assistant-object-schema (properties &optional (required #()))
  (%assistant-schema "object" "properties" properties "required" required "additionalProperties" :false))
(defun %assistant-tool-spec (name description properties &optional required)
  (%assistant-object "type" "function" "name" name "description" description
                     "inputSchema" (%assistant-object-schema properties (or required #()))))
(defun %assistant-tool-specs (world)
  (multiple-value-bind (operation description)
      (when (world-supports-p world :layout) (world-layout-schema world))
    (let* ((string (%assistant-schema "string")) (integer (%assistant-schema "integer"))
           (number (%assistant-schema "number")) (boolean (%assistant-schema "boolean"))
           (action (%assistant-object-schema
                  (%assistant-object
                    "op" (%assistant-schema "string" "enum"
                           (coerce (remove-if (lambda (op)
                                                (and (equal op "launch")
                                                     (not (world-supports-p world :launcher))))
                                              (mapcar #'car cu:+batch-action-fields+)) 'vector))
                    "window" integer "mode" (%assistant-schema "string" "enum" #("window" "desktop"))
                    "x" number "y" number "duration" number "button" string "state" string
                    "key" string "modifiers" (%assistant-schema "array" "items" string "maxItems" 4)
                    "text" (%assistant-schema "string" "maxLength" 256) "application" string
                    "title" string "app-id" string "timeout" number "focus" boolean "settle" number) #("op"))))
      (coerce
       (append
        (list
         (%assistant-tool-spec "ataxia_observe"
       "Discover approved mapped applications across the World, including offscreen windows. Select an available window by stable ID for its own PNG and local input coordinates, independent of monitor cameras or occlusion. Unavailable windows remain in discovery; inspect their World state. capture defaults true; without a selected window only the window list is returned. The token and sequence are managed by Ataxia."
       (%assistant-object "window" integer "capture" boolean))
         (%assistant-tool-spec "ataxia_act"
       "Execute 1–16 native input actions in order and return a settled screenshot. Observe a window before input. Key names are XKB names, e.g. Return; modifiers are Control_L, Shift_L, Alt_L, Super_L. Window coordinates apply to the last image. This seat cannot invoke desktop shortcuts or click World controls. Human takeover pauses the session."
       (%assistant-object "actions" (%assistant-schema "array" "items" action "minItems" 1 "maxItems" 16)
                          "capture" boolean "settle" number) #("actions"))
         (%assistant-tool-spec "ataxia_window"
       "Control an application window by its stable ID from observe or desktop_snapshot. Actions: close, minimize, restore, maximize, fullscreen. Close sends the normal application close request; it has no Undo and may open a save dialog, so verify afterward. Restore unminimizes and exits maximized/fullscreen presentation. Maximize and fullscreen follow the current World's placement policy. Application scope permits only its selected window; Project scope permits only this assistant's previews."
       (%assistant-object "window" integer "action" (%assistant-schema "string" "enum" #("close" "minimize" "restore" "maximize" "fullscreen"))) #("window" "action"))
         (%assistant-tool-spec "ataxia_desktop_snapshot" "Read structured state across the infinite World: stable window IDs, availability, placement, groups/workspaces and independent monitor cameras, plus the layout revision. Includes minimized and hidden-workspace windows. World geometry is not screenshot or click coordinates; each monitor is only a viewport."
                          (%assistant-object)))
        (when operation
          (list
           (%assistant-tool-spec "ataxia_layout_preview"
       (format nil "Validate a layout plan without changing the desktop. Use the revision from snapshot. ~A" description)
       (%assistant-object "revision" integer "operations" (%assistant-schema "array" "items" operation "minItems" 1 "maxItems" 64)) #("revision" "operations"))
           (%assistant-tool-spec "ataxia_layout_apply" "Apply a validated plan once. Rejects intervening human layout changes. Returns an Undo token."
                          (%assistant-object "plan" string) #("plan"))
           (%assistant-tool-spec "ataxia_layout_undo" "Undo the last assistant arrangement if no later layout change would be overwritten."
                          (%assistant-object "undo" string) #("undo"))))
        (list
         (%assistant-tool-spec "ataxia_ui_preview"
       "Launch a dedicated process and separate interactive Wayland window for a project-relative RML file. Each new custom UI gets its own process and window. Use for small apps such as a notepad with a native textarea. Follow the UI authoring instructions and test behavior with observe/act. Returns preview ID, process PID and application window ID. Project scope only. JavaScript, arbitrary callbacks and file saving are unavailable."
       (%assistant-object "path" string "width" integer "height" integer) #("path"))
         (%assistant-tool-spec "ataxia_ui_update"
       "Validate and replace an existing preview document after editing its project RML file. A failed update preserves the previous working preview; a successful update resets unsaved form values. Test the updated UI with observe/act."
       (%assistant-object "preview" string "path" string) #("preview" "path"))))
       'vector))))

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
(defun %assistant-tool-result (result)
  (let* ((image (getf result :image)) (path (getf image :path)) (items nil))
    (when path
      ;; This path comes exclusively from native capture, never a tool argument.
      (with-open-file (stream path :element-type '(unsigned-byte 8))
        (let ((size (file-length stream)))
          (when (> size (* 5 1024 1024)) (error "The captured image exceeds 5 MiB."))
          (let ((bytes (make-array size :element-type '(unsigned-byte 8))))
            (unless (= size (read-sequence bytes stream)) (error "Incomplete screenshot."))
            (push (%assistant-object "type" "inputImage" "imageUrl"
                    (concatenate 'string "data:image/png;base64," (%assistant-base64 bytes))) items))))
      (remf image :path))
    (push (%assistant-object "type" "inputText" "text" (ataxia.computer-use.wire:encode result)) items)
    (%assistant-object "success" (if (eq :false (getf result :ok)) :false t) "contentItems" (coerce items 'vector))))
(defun %assistant-tool-failure (cause)
  (%assistant-object "success" :false "contentItems"
    (vector (%assistant-object "type" "inputText" "text" (%assistant-text (princ-to-string cause) 4096)))))
(defun %assistant-require-task (controller)
  (unless (and (assistant-controller-grant controller) (not (assistant-controller-blocked controller)))
    (error "The task is paused or has no human authorization. Wait for the user to Run or Resume.")))
(defun %assistant-cu-call (controller request)
  (let ((result
         (%assistant-owner controller
           (lambda ()
             (%assistant-require-task controller)
             (let ((session (assistant-controller-session controller)))
               (unless session (error "This task has no computer-use session."))
               (setf (getf request :token) (cu:computer-session-token session)
                     (getf request :sequence) (1+ (cu:computer-session-sequence session)))
               (cu:request-on-owner (assistant-controller-world controller) request))))))
    (cu:finish-request result)))
(defun %assistant-preview-window-p (controller id)
  (let ((window (find id (world-windows (assistant-controller-world controller))
                      :key (lambda (w) (ataxia.kernel:object-id (window-application w))))))
    (and window (loop for preview being the hash-values of (assistant-controller-previews controller)
                      thereis (equal (assistant-preview-app-id preview)
                                     (ataxia.kernel:application-app-id (window-application window)))))))
(defun %assistant-check-action-scope (controller actions)
  (when (eq (assistant-controller-scope controller) :project)
    (%assistant-owner controller
      (lambda ()
        (loop for action across actions do
          (when (or (and (getf action :window) (not (%assistant-preview-window-p controller (getf action :window))))
                    (and (getf action :mode) (not (equal "window" (getf action :mode))))
                    (member (getf action :op) '("launch" "wait-window") :test #'equal))
            (error "Project input is limited to this assistant's app previews."))))))
  (when (eq (assistant-controller-scope controller) :application)
    (let ((id (getf (assistant-controller-grant controller) :window)))
      (loop for action across actions do
        (when (or (and (getf action :window) (not (eql id (getf action :window))))
                  (and (getf action :mode) (not (equal "window" (getf action :mode))))
                  (member (getf action :op) '("launch" "wait-window") :test #'equal))
          (error "This task is limited to the selected application."))))))
(defun %assistant-run-tool (controller name arguments)
  (unless (hash-table-p arguments) (error "Tool arguments must be an object."))
  (%assistant-owner controller (lambda () (%assistant-require-task controller)))
  (cond
    ((equal name "ataxia_observe")
     (let ((window (gethash "window" arguments)))
       (%assistant-check-action-scope controller (vector (list :op "view" :window window :mode "window")))
       (%assistant-cu-call controller (list :op "view" :mode "window" :window window))
       (let ((result (%assistant-cu-call controller (list :op "observe" :mode "window"))))
         (unless (eq :false (gethash "capture" arguments t))
           (when (getf (getf result :session) :window)
             (setf (getf result :image) (getf (%assistant-cu-call controller (list :op "capture")) :image))))
         result)))
    ((equal name "ataxia_act")
     (let ((request (cu:decode-request arguments)))
       (%assistant-check-action-scope controller (getf request :actions))
       (setf (getf request :op) "batch")
       (%assistant-cu-call controller request)))
    ((equal name "ataxia_desktop_snapshot")
     (%assistant-owner controller (lambda () (%assistant-layout-snapshot controller))))
    ((equal name "ataxia_window")
     (%assistant-owner controller (lambda () (%assistant-control-window controller arguments))))
    ((equal name "ataxia_layout_preview")
     (%assistant-owner controller (lambda () (%assistant-layout-preview controller arguments))))
    ((equal name "ataxia_layout_apply")
     (%assistant-owner controller (lambda () (%assistant-layout-apply controller arguments))))
    ((equal name "ataxia_layout_undo")
     (%assistant-owner controller (lambda () (%assistant-layout-undo controller (gethash "undo" arguments)))))
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
      (or (cdr (assoc name '(("ataxia_observe" . "Looking at the application") ("ataxia_act" . "Using the application")
                            ("ataxia_desktop_snapshot" . "Checking the desktop") ("ataxia_window" . "Updating the application window")
                            ("ataxia_layout_preview" . "Planning the arrangement")
                            ("ataxia_layout_apply" . "Arranging the desktop") ("ataxia_layout_undo" . "Restoring the arrangement")
                            ("ataxia_ui_preview" . "Opening the app preview") ("ataxia_ui_update" . "Updating the app preview")) :test #'equal)) name))
    (let ((epoch (assistant-controller-epoch controller)))
      (setf (assistant-controller-tool-worker controller)
        (sb-thread:make-thread
         (lambda ()
           (let* ((*assistant-operation-epoch* epoch)
                  (result (handler-case
                           (%assistant-tool-result (%assistant-run-tool controller name (gethash "arguments" params)))
                           (error (cause) (%assistant-tool-failure cause)))))
             ;; The worker alone owns the response cache; the tool thread posts completion.
             (when (= epoch (assistant-controller-epoch controller))
               (ignore-errors (%assistant-queue controller :tool-result (list key id result))))))
         :name "Ataxia assistant tool")))))
