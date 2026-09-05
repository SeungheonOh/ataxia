(in-package #:ataxia.infinite-world)

(defvar *meta-action-seat* nil)
(defvar *meta-property-cache* (make-hash-table :test #'eq :weakness :key))

(defun %meta-ui-path (name)
  (asdf:system-relative-pathname "ataxia-metaworld"
                                 (format nil "src/worlds/metaworld/~A.slint" name)))

(defparameter *meta-ui-sources*
  (loop for name in '("header" "toolbar" "group-controls" "canvas-menu" "window-controls" "note")
        collect (cons name (uiop:read-file-string (%meta-ui-path name)))))

(defun %meta-ui-widget (world name component state width height &key (layer 1200))
  (make-agent-widget
   world (cdr (assoc name *meta-ui-sources* :test #'equal))
   :source-path (namestring (%meta-ui-path name)) :component-name component
   :output (%canvas-output-output state) :width width :height height :layer layer))

(defun %meta-property (widget name value)
  (let* ((component (canvas-overlay-component widget))
         (cache (or (gethash component *meta-property-cache*)
                    (setf (gethash component *meta-property-cache*)
                          (make-hash-table :test #'equal)))))
    (unless (equal (gethash name cache :absent) value)
      (setf (gethash name cache) value)
      (set-agent-widget-property widget name value))))

(defun %meta-reposition-ui (world widget x y width height)
  (unless (and (= x (canvas-overlay-x widget)) (= y (canvas-overlay-y widget))
               (= width (canvas-overlay-width widget)) (= height (canvas-overlay-height widget)))
    (let ((resize (or (/= width (canvas-overlay-width widget))
                      (/= height (canvas-overlay-height widget)))))
      (if resize
          (configure-agent-widget world widget :x x :y y :width width :height height)
          (configure-agent-widget world widget :x x :y y)))))

(defun %meta-focused-object (world &optional seat)
  (let* ((state (%meta-seat world seat))
         (focused (and state (%canvas-seat-focused state)))
         (previous (and state (%canvas-seat-previous-focus state))))
    (flet ((object-p (object)
             (or (typep object 'canvas-window)
                 (and (typep object 'agent-widget)
                      (gethash object (%meta-spatial-widgets world))))))
      (cond ((object-p focused) focused)
            ((object-p previous) previous)
            (t nil)))))

(defun %meta-header (world state group)
  (let* ((view (%meta-view-for-state world state))
         (headers (%meta-view-headers view)))
    (or (gethash group headers)
        (let ((widget (%meta-ui-widget world "header" "SubworldHeader" state 330d0 30d0 :layer 100)))
          (bind-agent-widget-event
           widget "enter"
           (lambda (source event)
             (declare (ignore source event))
             (enter-subworld world group *meta-action-seat*)))
          (setf (gethash group headers) widget)))))

(defun %meta-toolbar (world state)
  (let ((view (%meta-view-for-state world state)))
    (or (%meta-view-panel view)
        (let ((widget (%meta-ui-widget world "toolbar" "MetaworldToolbar" state 760d0 48d0)))
          (bind-agent-widget-event
           widget "action"
           (lambda (source event)
             (declare (ignore source))
             (%meta-command world *meta-action-seat* (agent-widget-event-value event))))
          (setf (%meta-view-panel view) widget)))))

(defun %meta-sync-ui (world state)
  (let* ((view (%meta-view-for-state world state))
         (active (%meta-view-active view))
         (panel (%meta-toolbar world state)))
    (multiple-value-bind (width height) (%output-logical-size state)
      (declare (ignore height))
      (let ((panel-width (min (if active 600d0 340d0) (- width 24d0))))
        (%meta-reposition-ui world panel (/ (- width panel-width) 2d0) 8d0 panel-width 48d0)))
    (%meta-property panel "caption"
                    (if active (subworld-name active) "Canvas"))
    (%meta-property panel "active" (not (null active)))
    (%meta-property panel "standalone" (not (null (%meta-standalone world))))
    (%meta-property panel "workspace" (if active (subworld-workspace active) 1))
    (if (> (%meta-view-panel-until view) (%now))
        (show-overlay world panel)
        (hide-overlay world panel))
    (dolist (group (metaworld-subworlds world))
      (let ((header (%meta-header world state group)))
        (multiple-value-bind (canvas-x canvas-y)
            (%world-to-canvas state (subworld-x group) (subworld-y group))
          (multiple-value-bind (x y) (%canvas-to-screen state canvas-x canvas-y)
            (%meta-reposition-ui world header x (- y 32d0)
                                 (min 440d0 (max 210d0 (* (%canvas-output-zoom state)
                                                         (%meta-footprint-width group))))
                                 30d0)))
        (%meta-property header "caption"
                        (subworld-name group))
        (%meta-property header "active" (eq group active))
        (if (%meta-standalone world) (hide-overlay world header) (show-overlay world header))))
    (dolist (group (loop for group being the hash-keys of (%meta-view-headers view)
                        unless (member group (metaworld-subworlds world)) collect group))
      (remove-agent-widget world (gethash group (%meta-view-headers view)))
      (remhash group (%meta-view-headers view)))
    (maphash
     (lambda (widget geometry)
       (when (eq (canvas-overlay-output widget) (%canvas-output-output state))
         (destructuring-bind (x y width height) geometry
           (multiple-value-bind (canvas-x canvas-y) (%world-to-canvas state x y)
             (multiple-value-bind (screen-x screen-y) (%canvas-to-screen state canvas-x canvas-y)
               (let ((zoom (%canvas-output-zoom state)))
                 (unless (and (= screen-x (canvas-overlay-x widget))
                              (= screen-y (canvas-overlay-y widget))
                              (= (* zoom width) (canvas-overlay-width widget))
                              (= (* zoom height) (canvas-overlay-height widget)))
                   (%damage-overlay world widget)
                   (setf (canvas-overlay-x widget) screen-x
                         (canvas-overlay-y widget) screen-y
                         (canvas-overlay-width widget) (* zoom width)
                         (canvas-overlay-height widget) (* zoom height))
                   (%damage-overlay world widget))))))))
     (%meta-spatial-widgets world))
    (%meta-sync-object-controls world state)
    (%meta-position-context world state))
  world)

(defun %meta-refresh-menu (world)
  (let ((widget (%meta-menu world))
        (group (%meta-menu-group world)))
    (when (and widget group (eq :group (%meta-menu-kind world)))
      (%meta-property widget "world-name" (subworld-name group))
      (%meta-property widget "policy"
                      (string-downcase (symbol-name (if (eq :niri (subworld-kind group))
                                                       :niri (subworld-layout group)))))
      (%meta-property widget "standalone" (not (null (%meta-standalone world)))))))

(defun %meta-dismiss-menu (world)
  (when (%meta-menu world)
    (hide-overlay world (%meta-menu world))
    (dolist (seat-state (%seat-states world))
      (when (eq (%canvas-seat-focused seat-state) (%meta-menu world))
        (%focus-target world seat-state
                       (when (%target-visible-p (%meta-menu-target world))
                         (%meta-menu-target world))))))
  world)

(defun %meta-open-menu (world &optional seat (group (%meta-current world seat)))
  (let* ((seat-state (%meta-seat world seat))
         (state (if seat-state (%canvas-seat-output seat-state) (%first-output-state world)))
         (reuse-p (and state (%meta-menu world)
                       (eq (%meta-menu-kind world) (if group :group :canvas))
                       (eq (canvas-overlay-output (%meta-menu world)) (%canvas-output-output state)))))
    (when state
      (setf (%meta-menu-target world) (%meta-focused-object world seat)
            (%meta-menu-group world) group)
      (when (%meta-menu world)
        (%meta-dismiss-menu world)
        (unless reuse-p (remove-agent-widget world (%meta-menu world))))
      (unless reuse-p
       (let ((widget (%meta-ui-widget world (if group "group-controls" "canvas-menu")
                                     (if group "SubworldControls" "CanvasCreation")
                                     state (if group 330d0 220d0) (if group 164d0 120d0) :layer 2000)))
        (setf (%meta-menu world) widget
              (%meta-menu-kind world) (if group :group :canvas))
        (when group
          (bind-agent-widget-event
           widget "rename"
           (lambda (source event)
             (declare (ignore source))
             (let ((name (agent-widget-event-value event)) (group (%meta-menu-group world)))
               (when (and group (<= 1 (length name) 200))
                 (setf (subworld-name group) name)
                 (%meta-changed world))))))
        (bind-agent-widget-event
         widget "action"
         (lambda (source event)
           (declare (ignore source))
           (%meta-menu-action world (agent-widget-event-value event) *meta-action-seat*)))))
      (multiple-value-bind (x y)
          (%screen-to-world state (if seat-state (%canvas-seat-x seat-state) 40d0)
                            (if seat-state (%canvas-seat-y seat-state) 40d0))
        (setf (%meta-menu-anchor world) (list x y)))
      (when group (%meta-property (%meta-menu world) "confirming" nil))
      (%meta-refresh-menu world)
      (%meta-position-context world state)
      (show-overlay world (%meta-menu world))
      (when seat-state
        (setf (%canvas-seat-previous-focus seat-state) (%meta-menu-target world))
        (%focus-target world seat-state (%meta-menu world)))))
  world)

(defun %meta-position-context (world state)
  (let ((widget (%meta-menu world))
        (group (%meta-menu-group world)))
    (when (and widget (canvas-overlay-visible-p widget)
               (eq (canvas-overlay-output widget) (%canvas-output-output state)))
      (multiple-value-bind (canvas-x canvas-y)
          (%world-to-canvas state
                            (if group (subworld-x group) (first (%meta-menu-anchor world)))
                            (if group (subworld-y group) (second (%meta-menu-anchor world))))
        (multiple-value-bind (x y) (%canvas-to-screen state canvas-x canvas-y)
          (multiple-value-bind (width height) (%output-logical-size state)
            (%meta-reposition-ui
             world widget
             (max 8d0 (min (- width (canvas-overlay-width widget) 8d0) x))
             (max 8d0 (min (- height (canvas-overlay-height widget) 8d0) y))
             (canvas-overlay-width widget) (canvas-overlay-height widget))))))))

(defun %meta-sync-object-controls (world state)
  (let* ((view (%meta-view-for-state world state))
         (seat-state (find state (%seat-states world) :key #'%canvas-seat-output))
         (pointer-x (and seat-state (%canvas-seat-x seat-state)))
         (pointer-y (and seat-state (%canvas-seat-y seat-state)))
         (object (and seat-state
                      (first (%windows-at-screen-point world state pointer-x pointer-y))))
         (panel (%meta-view-window-controls view)))
    (when (and object (not (%canvas-seat-operation seat-state)) (not (%meta-group-drag world)))
      (multiple-value-bind (x y width height) (%window-canvas-geometry state object)
        (declare (ignore height))
        (multiple-value-bind (canvas-x canvas-y) (%screen-to-canvas state pointer-x pointer-y)
          (when (and (<= x canvas-x (+ x width)) (<= y canvas-y (+ y 24d0)))
            (setf (%meta-view-window-target view) object
                  (%meta-view-window-controls-until view) (+ (%now) 1.1d0))))))
    (when (and panel seat-state (canvas-overlay-visible-p panel)
               (<= (canvas-overlay-x panel) pointer-x (+ (canvas-overlay-x panel) (canvas-overlay-width panel)))
               (<= (canvas-overlay-y panel) pointer-y (+ (canvas-overlay-y panel) (canvas-overlay-height panel))))
      (setf (%meta-view-window-controls-until view) (+ (%now) 1.1d0)))
    (let ((target (%meta-view-window-target view)))
      (when (and target (eq target (find-canvas-window world (canvas-window-application target))))
        (unless panel
          (setf panel (%meta-ui-widget world "window-controls" "ObjectControls" state 400d0 36d0 :layer 1150)
                (%meta-view-window-controls view) panel)
          (bind-agent-widget-event
           panel "action"
           (lambda (widget event)
             (declare (ignore widget))
             (let ((object (%meta-view-window-target view)))
               (when object
                 (%meta-focus world object *meta-action-seat*)
                 (%meta-command world *meta-action-seat* (agent-widget-event-value event)))))))
        (let* ((group (object-subworld world target))
               (member (and group (%meta-member group target))))
          (%meta-property panel "owned" (not (null group)))
          (%meta-property panel "detachable" (and (not (%meta-standalone world)) (not (null group))))
          (%meta-property panel "niri" (and group (eq :niri (subworld-kind group))))
          (%meta-property panel "floating" (and member (subworld-member-floating-p member))))
        (multiple-value-bind (x y width height) (%window-canvas-geometry state target)
          (declare (ignore height))
          (multiple-value-bind (screen-x screen-y) (%canvas-to-screen state x y)
            (%meta-reposition-ui world panel screen-x (max 8d0 (- screen-y 37d0))
                                 (min 400d0 (max 200d0 width)) 36d0)))))
    (when panel
      (if (and (> (%meta-view-window-controls-until view) (%now))
               (%target-visible-p (%meta-view-window-target view))
               (not (%meta-group-drag world)))
          (show-overlay world panel) (hide-overlay world panel)))))

(defun %meta-new-note (world &optional group content geometry)
  (let* ((seat-state (%meta-seat world *meta-action-seat*))
         (state (or (and seat-state (%canvas-seat-output seat-state)) (%first-output-state world)))
         (widget (%create-agent-widget
                  'meta-note world (cdr (assoc "note" *meta-ui-sources* :test #'equal))
                  :source-path (namestring (%meta-ui-path "note"))
                  :component-name "MetaworldNote" :output (%canvas-output-output state)
                  :width 430d0 :height 320d0 :layer 20)))
    (setf (%meta-note-content widget)
          (or content ""))
    (%meta-property widget "content" (%meta-note-content widget))
    (bind-agent-widget-event
     widget "edited"
     (lambda (source event)
       (setf (%meta-note-content source) (agent-widget-event-value event))
       (%meta-changed world)))
    (bind-agent-widget-event
     widget "close"
     (lambda (source event)
       (declare (ignore event))
       (%meta-focus world source *meta-action-seat*)
       (%meta-command world *meta-action-seat* "close")))
    (setf (gethash widget (%meta-spatial-widgets world))
          (or geometry (list (+ (%canvas-output-camera-x state) 120d0)
                             (+ (%canvas-output-camera-y state) 150d0) 430d0 320d0)))
    (when group (move-object-to-subworld world widget group))
    (%meta-changed world)
    widget))
