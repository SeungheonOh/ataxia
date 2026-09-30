;;;; HTML application launcher overlay.
;;;;
;;;; The launcher is one ordinary CANVAS-OVERLAY. Chromium owns its visual and
;;;; widget state; the World supplies searchable open-window and desktop-entry
;;;; results, then performs focus or process-launch actions on its owner thread.

(in-package #:ataxia.infinite-world)

(defconstant +launcher-result-limit+ 6)

(defstruct (%desktop-entry
             (:constructor %make-desktop-entry (name detail path id)))
  name detail path id)

(defstruct (%launcher-entry
             (:constructor %make-launcher-entry (kind title detail subject score)))
  kind title detail subject score)

(defclass launcher-overlay (ui-overlay)
  ((results :initform #() :accessor %launcher-results)
   (desktop-entries :initform nil :accessor %launcher-desktop-entries)))

(defmethod overlay-visibility-changed
    ((overlay launcher-overlay) visible-p)
  (ataxia.world:ui-set-property
   (overlay-component overlay) "shown" visible-p)
  overlay)

(defmethod overlay-output-changed
    ((overlay launcher-overlay) output)
  (%position-launcher overlay (%make-canvas-output output)))

(defmethod destroy-overlay ((overlay launcher-overlay))
  (let ((component (overlay-component overlay)))
    (ataxia.world:ui-set-invalidator component nil)
    (ataxia.kernel:drawable-detach-graphics component)
    (ataxia.world:ui-destroy component))
  nil)

(defun %desktop-value (lines name)
  (let ((prefix (concatenate 'string name "="))
        (inside nil))
    (dolist (line lines)
      (cond
        ((string= line "[Desktop Entry]") (setf inside t))
        ((and inside (plusp (length line)) (char= (char line 0) #\[))
         (return))
        ((and inside (uiop:string-prefix-p prefix line))
         (return (subseq line (length prefix))))))))

(defun %read-desktop-entry (path)
  (handler-case
      (let ((lines
              (with-open-file (stream path :external-format :utf-8)
                (loop for line = (read-line stream nil nil)
                      while line collect line))))
        (let ((name (%desktop-value lines "Name"))
              (type (%desktop-value lines "Type"))
              (hidden (%desktop-value lines "Hidden"))
              (no-display (%desktop-value lines "NoDisplay"))
              (exec (%desktop-value lines "Exec")))
          (when (and name exec (string-equal type "Application")
                     (not (string-equal hidden "true"))
                     (not (string-equal no-display "true")))
            (%make-desktop-entry
             name
             (or (%desktop-value lines "GenericName")
                 (%desktop-value lines "Comment")
                 exec)
             (namestring path)
             (pathname-name path)))))
    (serious-condition () nil)))

(defun %desktop-data-directories (&optional (data-home (uiop:getenv "XDG_DATA_HOME"))
                                            (data-dirs (uiop:getenv "XDG_DATA_DIRS")))
  ;; Snap/Flatpak and distribution exports are supplied by the session. Do not
  ;; replace that search path with a fixed /usr/share + ~/.local/share pair.
  (labels ((absolute-directory (text)
             (when (and text (plusp (length text)) (char= #\/ (char text 0)))
               (uiop:ensure-directory-pathname text))))
    (remove-duplicates
     (cons (or (absolute-directory data-home)
               (merge-pathnames #P".local/share/" (user-homedir-pathname)))
           (remove nil (mapcar #'absolute-directory
                              (uiop:split-string (if (and data-dirs (plusp (length data-dirs)))
                                                     data-dirs "/usr/local/share:/usr/share")
                                                 :separator ":"))))
     :test #'equal :from-end t)))

(defun %desktop-files (&optional (directories (%desktop-data-directories)))
  ;; Resolve precedence before reading entries: Hidden=true and NoDisplay=true
  ;; in a user entry must also mask an entry of the same ID in a system directory.
  (remove-duplicates
   (loop for directory in directories append
         (ignore-errors (directory (merge-pathnames #P"applications/*.desktop" directory)
                                   :resolve-symlinks nil)))
   :test #'equal :key #'pathname-name :from-end t))

(defun %load-desktop-entries (&optional (directories (%desktop-data-directories)))
  (sort (remove nil (mapcar #'%read-desktop-entry (%desktop-files directories)))
        #'string-lessp :key #'%desktop-entry-name))

(defun %search-score (query text base)
  (let ((position (search query text :test #'char-equal)))
    (when position
      (+ base position (if (zerop position) -20 0)))))

(defun %launcher-candidates (world overlay query)
  (let ((query (string-downcase (string-trim '(#\Space #\Tab) query)))
        (candidates nil))
    (dolist (application (ataxia.kernel:kernel-applications
                          (ataxia.kernel:world-kernel world)))
      (let* ((window (find-canvas-window world application))
             (title (or (ataxia.kernel:application-title application)
                        (ataxia.kernel:application-app-id application)
                        "Untitled application"))
             (app-id (or (ataxia.kernel:application-app-id application) "Wayland"))
             (text (format nil "~A ~A" title app-id))
             (score (if (zerop (length query)) 0
                        (%search-score query text 0))))
        (when (and window (%canvas-window-mapped-p window) score)
          (push (%make-launcher-entry
                 :open title (format nil "Focus open window · ~A" app-id)
                 window score)
                candidates))))
    (dolist (entry (%launcher-desktop-entries overlay))
      (let* ((text (format nil "~A ~A ~A"
                           (%desktop-entry-name entry)
                           (%desktop-entry-detail entry)
                           (%desktop-entry-id entry)))
             (popular
               (cond ((search "foot" (%desktop-entry-id entry) :test #'char-equal) 0)
                     ((search "firefox" (%desktop-entry-id entry) :test #'char-equal) 1)
                     ((search "emacs" (%desktop-entry-id entry) :test #'char-equal) 2)
                     (t 30)))
             (score (if (zerop (length query)) (+ 100 popular)
                        (%search-score query text 50))))
        (when score
          (push (%make-launcher-entry
                 :launch (%desktop-entry-name entry)
                 (format nil "Launch new · ~A" (%desktop-entry-detail entry))
                 entry score)
                candidates))))
    (subseq (stable-sort candidates #'< :key #'%launcher-entry-score)
            0 (min +launcher-result-limit+ (length candidates)))))

(defun %set-launcher-result-property (component prefix index value)
  (ataxia.world:ui-set-property
   component (format nil "~A-~D" prefix index) value))

(defun %refresh-launcher (world overlay query)
  (let* ((component (overlay-component overlay))
         (results (coerce (%launcher-candidates world overlay query) 'vector)))
    (setf (%launcher-results overlay) results)
    (ataxia.world:ui-set-property component "result-count" (length results))
    (ataxia.world:ui-set-property component "selected-index" 0)
    (loop for index below +launcher-result-limit+
          for entry = (and (< index (length results)) (aref results index))
          do (%set-launcher-result-property
              component "result-title" index
              (if entry (%launcher-entry-title entry) ""))
             (%set-launcher-result-property
              component "result-detail" index
              (if entry (%launcher-entry-detail entry) ""))
             (%set-launcher-result-property
              component "result-kind" index
              (if entry
                  (if (eq (%launcher-entry-kind entry) :open) "OPEN" "LAUNCH")
                  ""))))
  overlay)

(defun %launch-desktop-entry (world entry)
  (let ((display
          (ataxia.runtime:runtime-socket-name
           (ataxia.kernel:kernel-runtime
            (ataxia.kernel:world-kernel world)))))
    (handler-case
        (unless (%queue-program-launch
                 (list "env" (format nil "WAYLAND_DISPLAY=~A" display)
                       "gio" "launch" (%desktop-entry-path entry)))
          (show-notification world "Too many pending application launches." :title "Launcher"))
      (serious-condition (cause)
        (format *error-output* "[infinite-world] cannot launch ~A: ~A~%"
                (%desktop-entry-name entry) cause)
        (finish-output *error-output*))))
  entry)

(defun %center-camera-on-window (world seat-state window)
  (let ((state (%canvas-seat-output seat-state)))
    (when state
      (multiple-value-bind (width height) (%output-logical-size state)
        (setf (%canvas-output-camera-x state)
              (- (+ (canvas-window-x window) (/ (canvas-window-width window) 2d0))
                 (/ width (* 2d0 (%canvas-output-zoom state))))
              (%canvas-output-camera-y state)
              (- (+ (canvas-window-y window) (/ (canvas-window-height window) 2d0))
                 (/ height (* 2d0 (%canvas-output-zoom state)))))
        (%full-damage world state)))))

(defun %activate-launcher-result (world overlay index)
  (let ((results (%launcher-results overlay)))
    (when (< -1 index (length results))
      (let ((entry (aref results index)))
        (hide-overlay world overlay)
        (ecase (%launcher-entry-kind entry)
          (:open
           (let ((window (%launcher-entry-subject entry)))
             (when (eq window
                       (find-canvas-window
                        world (canvas-window-application window)))
               (%set-window-minimized world window nil)
               (when (%canvas-window-hidden-p window)
                 (setf (%canvas-window-hidden-p window) nil)
                 (%damage-window world window)
                 (%update-window-membership world window))
               (dolist (seat-state (%seat-states world))
                 (when (and (%canvas-seat-output seat-state)
                            (eq (overlay-output overlay)
                                (%canvas-output-output
                                 (%canvas-seat-output seat-state))))
                   (%center-camera-on-window world seat-state window)
                   (%focus-target world seat-state window)))
               (%raise-window world window))))
          (:launch
           (%launch-desktop-entry world (%launcher-entry-subject entry)))))))
  overlay)

(defun %launcher-size (state)
  (multiple-value-bind (width height) (%output-logical-size state)
    (values (max 1d0 (min 620d0 (- width 24d0)))
            (max 1d0 (min 116d0 (- height 24d0))))))

(defun %position-launcher (overlay state)
  (multiple-value-bind (output-width output-height) (%output-logical-size state)
    (multiple-value-bind (width height) (%launcher-size state)
      (setf (overlay-x overlay) (/ (- output-width width) 2d0)
            (overlay-y overlay) (/ (- output-height height) 2d0)
            (overlay-width overlay) width
            (overlay-height overlay) height)
      (ataxia.world:ui-resize
       (overlay-component overlay) width height
       :scale (ataxia.world:ui-raster-scale (overlay-component overlay)))))
  overlay)

(defun %make-launcher-overlay (world state)
  (multiple-value-bind (width height) (%launcher-size state)
    (let* ((output (%canvas-output-output state))
           (component
             (ataxia.world.web.ui:make-ui-component
              :world world
              :source-path (asdf:system-relative-pathname "ataxia-infinite-world" "src/worlds/infinite/launcher.html")
              :component-name "AtaxiaLauncher"
              :width width :height height
              :scale (ataxia.kernel:output-scale output)))
           (overlay
             (make-instance
              'launcher-overlay :component component :output output
              :x 0d0 :y 0d0 :width width :height height
              :layer 1000 :visible-p nil)))
      (setf (%launcher-desktop-entries overlay) (%load-desktop-entries))
      (%position-launcher overlay state)
      (ataxia.world:ui-set-invalidator
       component
       (lambda (ignored)
         (declare (ignore ignored))
         (unless (%world-quiescing-p world)
           (when (overlay-visible-p overlay)
             (%request-output-state-frame world state))
           (%schedule-component-timer world))))
      (ataxia.world:ui-set-callback
       component "search"
       (lambda (ignored query)
         (declare (ignore ignored))
         (%refresh-launcher world overlay query)))
      (ataxia.world:ui-set-callback
       component "activate"
       (lambda (ignored index)
         (declare (ignore ignored))
         (let ((value (ignore-errors
                        (parse-integer index :junk-allowed t))))
           (when value (%activate-launcher-result world overlay value)))))
      (ataxia.world:ui-set-callback
       component "dismiss"
       (lambda (ignored value)
         (declare (ignore ignored value))
         (hide-overlay world overlay)))
      (%refresh-launcher world overlay "")
      overlay)))

(defun %launcher-for-output (world output)
  (find-if (lambda (overlay)
             (and (typep overlay 'launcher-overlay)
                  (eq output (overlay-output overlay))))
           (world-overlays world)))

(defun %ensure-output-launcher (world state)
  (or (%launcher-for-output world (%canvas-output-output state))
      (add-overlay world (%make-launcher-overlay world state))))

(defun toggle-application-launcher (world seat)
  "Toggle the launcher overlay associated with SEAT's current output."
  (let* ((seat-state (gethash seat (%world-seats world)))
         (state (and seat-state (%canvas-seat-output seat-state)))
         (overlay (and state (%ensure-output-launcher world state))))
    (when overlay
      (if (overlay-visible-p overlay)
          (hide-overlay world overlay)
          (progn
            (setf (%canvas-seat-previous-focus seat-state)
                  (%canvas-seat-focused seat-state))
            (%refresh-launcher world overlay "")
            (ataxia.world:ui-set-property
             (overlay-component overlay) "query" "")
            (show-overlay world overlay)
            (%focus-target world seat-state overlay)))))
  world)
