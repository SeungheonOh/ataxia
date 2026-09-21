;;;; Output-local shell presentation; the host owns desktop navigation policy.
(in-package #:ataxia.world.shell)

(defclass rmlui-status-bar (rmlui-widget)
  ((popup :initform nil :accessor %bar-popup)))
(defstruct shell-service timer power brightness-target audio media clipboard
  osd-timer (osds (make-hash-table :test #'eq)) feedback-output
  (sleep-keys (make-hash-table :test #'equal)))
(defgeneric initialize-status-bar-controls (world bar)
  (:documentation "Optional services can bind their controls when a bar is created.")
  (:method (world bar) (declare (ignore world bar)) nil))
(defun status-bars (world)
  (remove-if-not (lambda (widget) (typep widget 'rmlui-status-bar)) (world-overlays world)))
(defmethod service-output-insets ((service shell-service) world output)
  (declare (ignore service))
  (values 0d0 0d0 0d0
          (if (find output (status-bars world) :key #'overlay-output) 44d0 0d0)))
(defun set-bar-class (bar name value)
  (cache-widget-value bar (list :class name) value
    (lambda (component) (ataxia.world.rmlui:set-rmlui-class component "bar" name value))))

(defun %bar-sync (world bar output)
  (multiple-value-bind (width height) (output-logical-size output)
    (let* ((bar-width (max 1d0 width))
           (tiny (< bar-width 380d0))
           (navigation (world-shell-state world output))
           (active (getf navigation :active))
           (selected (getf navigation :selected 0))
           (count (min 9 (getf navigation :count 0)))
           (slots (if (< bar-width 680d0) 3 9))
           (first-slot (max 1 (min (- count slots -1) (- selected (floor slots 2)))))
           (seat (world-seat-on-output world output))
           (focused (and seat (world-seat-focus world seat))))
      (position-widget world bar 0d0 (max 0d0 (- height 44d0)) bar-width 44d0)
      (set-bar-class bar "compact" (< bar-width 1050d0))
      (set-bar-class bar "narrow" (< bar-width 680d0))
      (set-bar-class bar "tiny" tiny)
      (set-widget-text bar "group"
                       (if active
                           (format nil "~A / Workspace ~D ▾" (short-ui-text (getf navigation :name) 18) selected)
                           (if (world-supports-p world :shell-navigation) "Overview / Workspaces ▾" "Desktop")))
      (set-widget-text bar "title"
                 (short-ui-text
                  (if (window-application focused)
                      (or (ataxia.kernel:application-title (window-application focused)) "Untitled")
                      (if active (format nil "~A · workspace ~D" (getf navigation :name) selected)
                          "Desktop")) 90))
      (set-widget-text bar "apps" (format nil "~D apps" (length (world-windows world))))
      (set-widget-style bar "selection" "opacity" (if active "1" "0"))
      (loop for position from 0 below 9 do
        (set-bar-class bar (format nil "position-~D" position) (= position (max 0 (- selected first-slot)))))
      (loop for index from 1 to 9 for id = (format nil "ws~D" index) do
        (set-widget-style bar id "display" (if (<= first-slot index (min count (+ first-slot slots -1))) "block" "none"))
        (cache-widget-value bar (list :selected index) (= index selected)
                     (lambda (component) (ataxia.world.rmlui:set-rmlui-class component id "selected" (= index selected))))))))


(defun %bar-maintenance-delay (now power-popup-p)
  ;; The closed bar displays whole minutes and battery percentage. Share its
  ;; single minute deadline; only the visible detail panel needs faster refresh.
  (* 1000 (min (if power-popup-p 30 60) (- 60 (mod now 60)))))

(defun %bar-schedule-maintenance (world &optional source (now (get-universal-time)))
  (let* ((service (world-service world :shell))
         (timer (or source (and service (shell-service-timer service)))))
    (when timer
      (ataxia.runtime:update-event-loop-timer
       timer (%bar-maintenance-delay
              now (some (lambda (bar)
                          (let ((popup (%bar-popup bar)))
                            (and popup (eq :power (%shell-popup-kind popup)))))
                        (status-bars world)))))))

(defun %bar-maintain (world source)
  (when (world-service world :shell)
    (let ((now (get-universal-time)) (power (%bar-power)))
      (dolist (bar (status-bars world)) (%bar-clock bar now power))
      (when source (%bar-schedule-maintenance world source now)))))
(defun %bar-action (world bar action &optional number)
  (let* ((output (overlay-output bar)) (seat (world-seat-on-output world output)))
    ;; Commands require a seat on this output; never steer another output by fallback.
    (when seat
      (unless (member action '(:menu :power :spaces :media :clipboard)) (%bar-close-popup world bar))
      (case action
        (:menu (%bar-toggle-popup world bar :apps))
        (:power (%bar-toggle-popup world bar :power))
        ((:spaces :media :clipboard) (%bar-toggle-popup world bar action))
        (otherwise
         (when (world-supports-p world :shell-navigation)
           (world-shell-action world output seat action number)))))))
(defun %bar-create (world output)
  (let* ((path (asdf:system-relative-pathname "ataxia-rmlui" "src/world/rmlui/status-bar/bar.rml"))
         (bar (create-agent-widget 'rmlui-status-bar world (uiop:read-file-string path)
                                   :component-factory #'ataxia.world.rmlui:make-shell-rmlui-component
                                   :source-path (namestring path) :output output
                                   :width 1000d0 :height 44d0 :layer 1150)))
    (dolist (entry '(("home" . :menu) ("power" . :power) ("group" . :spaces)
                     ("audio" . :media) ("media" . :media) ("clipboard" . :clipboard)
                     ("previous" . :previous) ("next" . :next)))
      (let ((action (cdr entry)))
        (bind-agent-widget-event bar (car entry)
          (lambda (widget event) (declare (ignore event)) (%bar-action world widget action)))))
    (loop for index from 1 to 9 do
      (let ((number index))
        (bind-agent-widget-event bar (format nil "ws~D" index)
          (lambda (widget event) (declare (ignore event)) (%bar-action world widget :workspace number)))))
    (%bar-sync world bar output)
    (initialize-status-bar-controls world bar)
    (world-output-work-area-changed world output)
    bar))

(defun disable-rmlui-status-bar (world &key (reflow-p t))
  "Remove the bars and their maintenance timer. Call on the World owner thread."
  (let ((service (world-service world :shell)))
    (when service (%stop-shell-controls world service))
    (when service (%stop-power-controller (shell-service-power service)))
    (when (and service (shell-service-timer service))
      (ataxia.runtime:remove-event-loop-source (shell-service-timer service))))
  (detach-world-service world :shell)
  (dolist (bar (status-bars world))
    (%bar-close-popup world bar)
    (remove-agent-widget world bar)
    (when reflow-p (world-output-work-area-changed world (overlay-output bar))))
  world)
(defun enable-rmlui-status-bar (world &key (power-backend #'%system-power-action) (system-controls-p t))
  "Install one responsive RmlUi bar per output. Repeated calls are safe."
  (require-world-capabilities world :ui :desktop)
  (disable-rmlui-status-bar world)
  (let ((service (make-shell-service)))
    (attach-world-service world :shell service)
    (handler-case
        (progn
          (setf (shell-service-power service) (%start-power-controller world service power-backend))
          (%power-queue (shell-service-power service) :refresh)
          (dolist (output (world-outputs world)) (%bar-create world output))
          (when system-controls-p (%start-shell-controls world service))
          (setf (shell-service-timer service)
                (ataxia.runtime:add-event-loop-timer
                 (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))
                 (lambda (source) (%bar-maintain world source) 0)))
          (%bar-maintain world (shell-service-timer service))
          world)
      (error (cause) (disable-rmlui-status-bar world) (error cause)))))

(defmethod service-before-render ((service shell-service) world lease)
  (dolist (bar (status-bars world))
    (when (eq (overlay-output bar) (ataxia.kernel:frame-output lease))
      (%bar-sync world bar (overlay-output bar))
      (when (%bar-popup bar)
        (%bar-position-popup world bar (overlay-output bar))
        (when (eq :spaces (%shell-popup-kind (%bar-popup bar)))
          (%sync-workspace-popup world (%bar-popup bar)))))))
(defmethod service-output-added ((service shell-service) world output)
  (%bar-create world output)
  (%bar-maintain world nil)
  (%sync-system-controls world service))
(defmethod service-quiescing ((service shell-service) world reason)
  (declare (ignore reason))
  (disable-rmlui-status-bar world :reflow-p nil))
