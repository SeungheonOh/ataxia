;;;; Slint application launcher overlay.
;;;;
;;;; The launcher is one ordinary CANVAS-OVERLAY. Slint owns its visual and
;;;; widget state; the World supplies searchable open-window and desktop-entry
;;;; results, then performs focus or process-launch actions synchronously.

(in-package #:ataxia.infinite-world)

(defconstant +launcher-result-limit+ 6)

(defparameter +launcher-source+
  "component LauncherRow inherits Rectangle {
    in property <string> title;
    in property <int> index;
    in property <bool> enabled;
    in property <bool> selected;
    callback activate(int);

    height: 44px;
    visible: root.enabled;
    background: touch.pressed ? #a9a9a5 : root.selected ? #171717 : touch.has-hover ? #d4d4d0 : #f4f4f1;
    Text {
        x: 14px;
        y: 0px;
        width: parent.width - 28px;
        height: parent.height;
        text: root.title;
        color: root.selected ? #f4f4f1 : #171717;
        font-size: 14px;
        font-weight: 700;
        vertical-alignment: center;
        overflow: elide;
    }
    touch := TouchArea { clicked => { root.activate(root.index); } }
}

export component AtaxiaLauncher inherits Window {
    background: transparent;
    in-out property <bool> shown: false;
    in-out property <string> query: \"\";
    in-out property <int> selected-index: 0;
    in property <int> result-count: 0;
    in property <string> result-title-0: \"\";
    in property <string> result-title-1: \"\";
    in property <string> result-title-2: \"\";
    in property <string> result-title-3: \"\";
    in property <string> result-title-4: \"\";
    in property <string> result-title-5: \"\";
    in property <string> result-detail-0: \"\";
    in property <string> result-detail-1: \"\";
    in property <string> result-detail-2: \"\";
    in property <string> result-detail-3: \"\";
    in property <string> result-detail-4: \"\";
    in property <string> result-detail-5: \"\";
    in property <string> result-kind-0: \"\";
    in property <string> result-kind-1: \"\";
    in property <string> result-kind-2: \"\";
    in property <string> result-kind-3: \"\";
    in property <string> result-kind-4: \"\";
    in property <string> result-kind-5: \"\";
    callback search(string);
    callback activate(int);
    callback dismiss();

    changed shown => { if root.shown { editor.focus(); } }

    panel := Rectangle {
        x: 0px;
        y: 0px;
        width: parent.width;
        height: parent.height;
        border-width: 1px;
        border-color: #171717;
        background: #e4e4e0;

        search-box := Rectangle {
            x: 12px;
            y: 12px;
            width: parent.width - 24px;
            height: 48px;
            border-width: 1px;
            border-color: #171717;
            background: #f4f4f1;
            editor := TextInput {
                x: 14px;
                y: 7px;
                width: parent.width - 28px;
                height: parent.height - 14px;
                text <=> root.query;
                color: #171717;
                selection-background-color: #a8a8a3;
                font-size: 18px;
                single-line: true;
                edited => { root.search(self.text); }
                accepted => { if root.result-count > 0 { root.activate(root.selected-index); } }
                key-pressed(event) => {
                    if event.text == Key.Escape {
                        root.dismiss();
                        return accept;
                    }
                    if event.text == Key.DownArrow {
                        root.selected-index = Math.min(root.selected-index + 1, root.result-count - 1);
                        return accept;
                    }
                    if event.text == Key.UpArrow {
                        root.selected-index = Math.max(root.selected-index - 1, 0);
                        return accept;
                    }
                    return reject;
                }
            }
        }

        VerticalLayout {
            x: 12px;
            y: 72px;
            width: parent.width - 24px;
            height: 269px;
            spacing: 1px;
            LauncherRow { title: root.result-title-0; index: 0; enabled: root.result-count > 0; selected: root.selected-index == 0; activate(index) => { root.activate(index); } }
            LauncherRow { title: root.result-title-1; index: 1; enabled: root.result-count > 1; selected: root.selected-index == 1; activate(index) => { root.activate(index); } }
            LauncherRow { title: root.result-title-2; index: 2; enabled: root.result-count > 2; selected: root.selected-index == 2; activate(index) => { root.activate(index); } }
            LauncherRow { title: root.result-title-3; index: 3; enabled: root.result-count > 3; selected: root.selected-index == 3; activate(index) => { root.activate(index); } }
            LauncherRow { title: root.result-title-4; index: 4; enabled: root.result-count > 4; selected: root.selected-index == 4; activate(index) => { root.activate(index); } }
            LauncherRow { title: root.result-title-5; index: 5; enabled: root.result-count > 5; selected: root.selected-index == 5; activate(index) => { root.activate(index); } }
        }

        Text {
            x: 12px;
            y: 72px;
            width: parent.width - 24px;
            height: 269px;
            visible: root.result-count == 0;
            text: \"No matches\";
            color: #666662;
            font-size: 13px;
            horizontal-alignment: center;
            vertical-alignment: center;
        }
    }
}")

(defstruct (%desktop-entry
             (:constructor %make-desktop-entry (name detail path id)))
  name detail path id)

(defstruct (%launcher-entry
             (:constructor %make-launcher-entry (kind title detail subject score)))
  kind title detail subject score)

(defclass launcher-overlay (canvas-overlay)
  ((results :initform #() :accessor %launcher-results)
   (desktop-entries :initform nil :accessor %launcher-desktop-entries)))

(defmethod %overlay-visibility-changed
    ((overlay launcher-overlay) visible-p)
  (ataxia.world.slint:set-slint-property
   (canvas-overlay-component overlay) "shown" visible-p)
  overlay)

(defmethod %overlay-output-changed
    ((overlay launcher-overlay) output-state)
  (%position-launcher overlay output-state))

(defmethod %destroy-overlay ((overlay launcher-overlay))
  (let ((component (canvas-overlay-component overlay)))
    (ataxia.world.slint:set-slint-component-invalidator component nil)
    (when (ataxia.world.slint:slint-component-graphics-attached-p component)
      (ataxia.kernel:drawable-detach-graphics component))
    (ataxia.world.slint:destroy-slint-component component))
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

(defun %desktop-files ()
  (remove-duplicates
   (append
    (directory #P"/usr/share/applications/*.desktop")
    (directory (merge-pathnames #P".local/share/applications/*.desktop"
                                (user-homedir-pathname))))
   :test #'equal :key #'namestring))

(defun %load-desktop-entries ()
  (sort (remove nil (mapcar #'%read-desktop-entry (%desktop-files)))
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
  (ataxia.world.slint:set-slint-property
   component (format nil "~A-~D" prefix index) value))

(defun %refresh-launcher (world overlay query)
  (let* ((component (canvas-overlay-component overlay))
         (results (coerce (%launcher-candidates world overlay query) 'vector)))
    (setf (%launcher-results overlay) results)
    (ataxia.world.slint:set-slint-property component "result-count" (length results))
    (ataxia.world.slint:set-slint-property component "selected-index" 0)
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
        (uiop:launch-program
         (list "env" (format nil "WAYLAND_DISPLAY=~A" display)
               "gio" "launch" (%desktop-entry-path entry))
         :input #P"/dev/null" :output #P"/dev/null"
         :error-output #P"/dev/null" :wait nil)
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
               (when (%canvas-window-hidden-p window)
                 (setf (%canvas-window-hidden-p window) nil)
                 (%damage-window world window)
                 (%update-window-membership world window))
               (dolist (seat-state (%seat-states world))
                 (when (and (%canvas-seat-output seat-state)
                            (eq (canvas-overlay-output overlay)
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
    (values (max 380d0 (min 620d0 (- width 48d0)))
            (max 360d0 (min 380d0 (- height 48d0))))))

(defun %position-launcher (overlay state)
  (multiple-value-bind (output-width output-height) (%output-logical-size state)
    (multiple-value-bind (width height) (%launcher-size state)
      (setf (canvas-overlay-x overlay) (/ (- output-width width) 2d0)
            (canvas-overlay-y overlay) (/ (- output-height height) 2d0)
            (canvas-overlay-width overlay) width
            (canvas-overlay-height overlay) height)
      (ataxia.world.slint:resize-slint-component
       (canvas-overlay-component overlay) width height
       :scale (ataxia.kernel:output-scale (%canvas-output-output state)))))
  overlay)

(defun %make-launcher-overlay (world state)
  (multiple-value-bind (width height) (%launcher-size state)
    (let* ((output (%canvas-output-output state))
           (component
             (ataxia.world.slint:make-slint-component
              :source +launcher-source+
              :source-path "ataxia-launcher.slint"
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
      (ataxia.world.slint:set-slint-component-invalidator
       component
       (lambda (ignored)
         (declare (ignore ignored))
         (unless (%world-quiescing-p world)
           (when (canvas-overlay-visible-p overlay)
             (%request-output-state-frame world state))
           (%schedule-component-timer world))))
      (ataxia.world.slint:set-slint-callback
       component "search"
       (lambda (ignored query)
         (declare (ignore ignored))
         (%refresh-launcher world overlay query)))
      (ataxia.world.slint:set-slint-callback
       component "activate"
       (lambda (ignored index)
         (declare (ignore ignored))
         (let ((value (ignore-errors
                        (parse-integer index :junk-allowed t))))
           (when value (%activate-launcher-result world overlay value)))))
      (ataxia.world.slint:set-slint-callback
       component "dismiss"
       (lambda (ignored value)
         (declare (ignore ignored value))
         (hide-overlay world overlay)))
      (%refresh-launcher world overlay "")
      overlay)))

(defun %launcher-for-output (world output)
  (find-if (lambda (overlay)
             (and (typep overlay 'launcher-overlay)
                  (eq output (canvas-overlay-output overlay))))
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
      (if (canvas-overlay-visible-p overlay)
          (hide-overlay world overlay)
          (progn
            (setf (%canvas-seat-previous-focus seat-state)
                  (%canvas-seat-focused seat-state))
            (%refresh-launcher world overlay "")
            (ataxia.world.slint:set-slint-property
             (canvas-overlay-component overlay) "query" "")
            (show-overlay world overlay)
            (%focus-target world seat-state overlay)))))
  world)
