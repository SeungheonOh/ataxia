(in-package #:ataxia.infinite-world)

(defvar *meta-layout-motion* nil)
(defvar *meta-action-seat* nil)
(defvar *meta-launch-sequence* 0)

(defstruct (%meta-launch (:constructor %make-meta-launch))
  expires app-id group-id below-id workspace)
(defvar *meta-layout-deferred-p* nil)
(defvar *meta-layout-pending* nil)

(defmacro %with-meta-layout-batch ((world) &body body)
  `(if *meta-layout-deferred-p*
       (progn ,@body)
       (let ((*meta-layout-deferred-p* t) (*meta-layout-pending* nil))
         (multiple-value-prog1 (progn ,@body)
           (let ((*meta-layout-deferred-p* nil))
             (dolist (group (nreverse *meta-layout-pending*))
               (%meta-layout ,world group)))))))

(defstruct (subworld (:constructor %make-subworld))
  id name (kind :niri) (layout :dwindle)
  (x 0d0) (y 0d0) (width 1400d0) (height 800d0)
  (workspace 1) (ratio 0.55d0) (next-column 0)
  (members nil) (scrolls (make-hash-table))
  (fullscreen nil))

(defstruct (subworld-member (:constructor %make-subworld-member))
  object (workspace 1) (column 0) (width 660d0) (weight 1d0)
  (floating-p nil) (order most-positive-fixnum) restore-geometry)

(defclass meta-note (agent-widget)
  ((content :initform "" :accessor %meta-note-content)))

(defstruct (%meta-view (:constructor %make-meta-view))
  active parent-camera (panel-until 0d0) panel
  (headers (make-hash-table :test #'eq))
  window-controls window-target (window-controls-until 0d0)
  (last-camera nil) (last-focus nil) (hover-after 0d0))

(defclass metaworld (infinite-world)
  ((chrome-states :initform (make-hash-table :test #'eq) :reader %meta-chrome-states)
   (packing-signature :initform nil :accessor %meta-packing-signature)
   (packing-anchor :initform nil :accessor %meta-packing-anchor)
   (packing-direction :initform '(1d0 0d0) :accessor %meta-packing-direction)
   (motions :initform (make-hash-table :test #'eq) :reader %meta-motions)
   (drop-previews :initform (make-hash-table :test #'eq) :reader %meta-drop-previews)
   (preview-positions :initform (make-hash-table :test #'eq) :reader %meta-preview-positions)
   (subworlds :initform nil :accessor metaworld-subworlds)
   (next-subworld-id :initform 0 :accessor %meta-next-id)
   (owners :initform (make-hash-table :test #'eq) :reader %meta-owners)
   (group-focus :initform (make-hash-table :test #'eq) :reader %meta-group-focus)
   (views :initform (make-hash-table :test #'eq) :reader %meta-views)
   (modifiers :initform (make-hash-table :test #'eq) :reader %meta-modifiers)
   (standalone :initarg :standalone :initform nil :accessor %meta-standalone)
   (state-file :initarg :state-file :initform nil :reader %meta-state-file)
   (state-paths :initform (make-hash-table) :accessor %meta-state-paths)
   (saved-windows :initform nil :accessor %meta-saved-windows)
   (saved-cameras :initform nil :accessor %meta-saved-cameras)
   (saved-notes :initform nil :accessor %meta-saved-notes)
   (pending-launches :initform nil :accessor %meta-pending-launches)
   (state-loaded-p :initform nil :accessor %meta-state-loaded-p)
   (initialized-windows :initform (make-hash-table :test #'eq) :reader %meta-initialized-windows)
   (save-needed-p :initform nil :accessor %meta-save-needed-p)
   (last-save :initform 0d0 :accessor %meta-last-save)
   (menu :initform nil :accessor %meta-menu)
   (menu-group :initform nil :accessor %meta-menu-group)
   (menu-kind :initform nil :accessor %meta-menu-kind)
   (menu-anchor :initform nil :accessor %meta-menu-anchor)
   (menu-target :initform nil :accessor %meta-menu-target)
   (timer :initform nil :accessor %meta-timer)
   (state-error :initform nil :accessor %meta-state-error)
   (spatial-widgets :initform (make-hash-table :test #'eq) :reader %meta-spatial-widgets)
   (group-drag :initform nil :accessor %meta-group-drag)
   (restoring-p :initform nil :accessor %meta-restoring-p)))

(defclass niri-world (metaworld) ())
(defclass hyprland-world (metaworld) ())

(defun %meta-state-path (mode)
  (merge-pathnames
   (format nil "ataxia/~(~A~).sexp" (or mode :metaworld))
   (uiop:ensure-directory-pathname
    (or (uiop:getenv "XDG_STATE_HOME")
        (merge-pathnames ".local/state/" (user-homedir-pathname))))))

(defun make-metaworld (&key damage-debug-p standalone
                           (state-file (%meta-state-path standalone)))
  (unless (member standalone '(nil :niri :hyprland))
    (error "Unknown standalone policy: ~S" standalone))
  (make-instance (case standalone (:niri 'niri-world)
                       (:hyprland 'hyprland-world) (t 'metaworld))
                 :damage-debug-p damage-debug-p
                 :standalone standalone :state-file state-file))

(defun make-niri-world (&rest options)
  (apply #'make-metaworld :standalone :niri options))

(defun make-hyprland-world (&rest options)
  (apply #'make-metaworld :standalone :hyprland options))

(defun %meta-view-for-state (world state)
  (when state
    (or (gethash state (%meta-views world))
        (setf (gethash state (%meta-views world)) (%make-meta-view)))))

(defun %meta-seat (world &optional seat)
  (let ((seat (or seat *meta-action-seat*)))
    (if seat (gethash seat (%world-seats world))
        (first (%seat-states world)))))

(defun %meta-current (world &optional seat)
  (let* ((seat-state (%meta-seat world seat))
         (state (if seat-state (%canvas-seat-output seat-state)
                    (%first-output-state world)))
         (view (%meta-view-for-state world state)))
    (and view (%meta-view-active view))))

(defun object-subworld (world object)
  (gethash object (%meta-owners world)))

(defun %meta-member (group object)
  (find object (subworld-members group) :key #'subworld-member-object :test #'eq))

(defun %meta-mapped-p (object)
  (etypecase object
    (canvas-window (%canvas-window-mapped-p object))
    (agent-widget (member object (world-overlays (%agent-widget-world object))))))

(defvar *meta-workspace-counts* (make-hash-table :test #'eq :weakness :key))
(defvar *meta-workspace-focus* (make-hash-table :test #'eq :weakness :key))

(defun %meta-workspace-count (group)
  (let ((count (max (gethash group *meta-workspace-counts* 1)
                    (subworld-workspace group)
                    (reduce #'max (subworld-members group) :key #'subworld-member-workspace
                            :initial-value 1))))
    (setf (gethash group *meta-workspace-counts*) count)))

(defun %meta-workspace-y (group &optional (workspace (subworld-workspace group)))
  (+ (subworld-y group)
     (if (eq :niri (subworld-kind group))
         (* (1- workspace) (subworld-height group)) 0d0)))

(defun %meta-footprint-height (group)
  (if (eq :niri (subworld-kind group))
      (* (%meta-workspace-count group) (subworld-height group))
      (subworld-height group)))

(defun %meta-workspace-at (group y)
  (if (eq :niri (subworld-kind group))
      (max 1 (min (%meta-workspace-count group)
                  (1+ (floor (- y (subworld-y group)) (subworld-height group)))))
      (subworld-workspace group)))

(defun %meta-visible-members (group &key include-floating (workspace (subworld-workspace group)))
  (remove-if-not
   (lambda (member)
     (and (or (null workspace) (= workspace (subworld-member-workspace member)))
          (%meta-mapped-p (subworld-member-object member))
          (or include-floating (not (subworld-member-floating-p member)))))
   (subworld-members group)))

(defun %meta-workspace-members (group workspace)
  (remove-if-not (lambda (entry) (= workspace (subworld-member-workspace entry)))
                 (subworld-members group)))

(defun %meta-same-column-p (a b)
  (and (= (subworld-member-workspace a) (subworld-member-workspace b))
       (= (subworld-member-column a) (subworld-member-column b))))

(defun %meta-set-column-width (group member width)
  (dolist (entry (subworld-members group))
    (when (%meta-same-column-p entry member)
      (setf (subworld-member-width entry) width))))

(defun %meta-replace-workspace-members (group workspace members)
  ;; Retain every other workspace's ordering and slots in the group list.
  (setf (subworld-members group)
        (loop for entry in (subworld-members group)
              collect (if (= workspace (subworld-member-workspace entry))
                          (pop members) entry))))

(defun %meta-columns (group &optional (workspace (subworld-workspace group)))
  (remove-duplicates
   (mapcar #'subworld-member-column (%meta-visible-members group :workspace workspace))
   :from-end t))

(defun %meta-workspace-width (group workspace)
  (let ((members (%meta-visible-members group :workspace workspace)))
    (max (subworld-width group)
         (loop for column in (remove-duplicates (mapcar #'subworld-member-column members))
               for member = (find column members :key #'subworld-member-column)
               sum (subworld-member-width member)))))

(defun %meta-footprint-width (group)
  (if (eq (subworld-kind group) :niri)
      (loop for workspace from 1 to (%meta-workspace-count group)
            maximize (%meta-workspace-width group workspace))
      (subworld-width group)))

(defun %meta-group-at (world x y)
  (find-if
   (lambda (group)
     (and (<= (subworld-x group) x
              (+ (subworld-x group) (%meta-footprint-width group)))
          (<= (subworld-y group) y
              (+ (subworld-y group) (%meta-footprint-height group)))))
   (reverse (metaworld-subworlds world))))

(defun %meta-camera (state)
  (list (%canvas-output-camera-x state) (%canvas-output-camera-y state)
        (%canvas-output-zoom state) (%canvas-output-rotation state)))

(defun %meta-set-camera (world state camera)
  (destructuring-bind (x y zoom &optional (rotation 0d0)) camera
    (setf (%canvas-output-rotation state) (coerce rotation 'double-float)
          (%canvas-output-target-rotation state) (coerce rotation 'double-float))
    (set-output-camera world (%canvas-output-output state) x y zoom)))

(defun %meta-camera-sample (origin destination progress)
  "Interpolate the screen transform so pan and zoom follow the same path."
  (if (>= progress 1d0) (copy-list destination)
      (if (<= progress 0d0) (copy-list origin)
          (destructuring-bind (ax ay az &optional (ar 0d0)) origin
            (destructuring-bind (bx by bz &optional (br 0d0)) destination
              (let* ((p (coerce progress 'double-float))
                     (zoom (+ az (* p (- bz az))))
                     (angle (- (mod (+ (- br ar) pi) (* 2d0 pi)) pi)))
                (list (/ (+ (* ax az) (* p (- (* bx bz) (* ax az)))) zoom)
                      (/ (+ (* ay az) (* p (- (* by bz) (* ay az)))) zoom)
                      zoom (+ ar (* p angle)))))))))

(defun %meta-transition-camera (world state origin)
  (let ((destination (%meta-camera state)))
    (when (equalp origin destination)
      (%meta-cancel-motion world state :metaworld-camera)
      (return-from %meta-transition-camera state))
    (let ((view (%meta-view-for-state world state)))
      (setf (%meta-view-hover-after view) (+ (%now) 0.36d0)
            (%meta-view-window-controls-until view) 0d0))
    (%meta-set-camera world state origin)
    ;; One easing parameter keeps translation and scale in lockstep. Old
    ;; per-axis velocities otherwise bend a retargeted camera's path.
    (%meta-cancel-motion world state :metaworld-camera)
    (%meta-animate-to world state :metaworld-camera '(0d0) '(1d0) 0.28d0
                      (lambda (subject progress)
                        (%meta-set-camera world subject
                                          (%meta-camera-sample origin destination (first progress)))))
    (%request-output-state-frame world state)))

(defun %meta-changed (world)
  (when (and (fboundp '%meta-maintain-subworld-spacing)
             (%output-states world) (not (%meta-restoring-p world))
             (not (%world-quiescing-p world)))
    (%meta-maintain-subworld-spacing world))
  (setf (%meta-save-needed-p world) t)
  (ataxia.world:refresh-world world)
  world)

(defun create-subworld (world kind &key name x y)
  (check-type world metaworld)
  (unless (member kind '(:niri :hyprland))
    (error "Subworld policy must be :NIRI or :HYPRLAND."))
  (when (and (%meta-standalone world) (metaworld-subworlds world))
    (error "Standalone worlds cannot contain another subworld."))
  (let* ((id (incf (%meta-next-id world)))
         (group
           (%make-subworld
            :id id :kind kind
            :name (or name (format nil "~A ~D" (if (eq kind :niri)
                                                    "Development" "Workspace") id))
            :x (coerce (or x 0d0) 'double-float)
            :y (coerce (or y
                           (if (metaworld-subworlds world)
                               (+ 200d0
                                  (reduce #'max (metaworld-subworlds world)
                                          :key (lambda (entry)
                                                 (+ (subworld-y entry)
                                                    (%meta-footprint-height entry)))))
                               0d0)) 'double-float))))
    (setf (metaworld-subworlds world)
          (append (metaworld-subworlds world) (list group)))
    (%meta-changed world)
    group))

(defun %meta-vacant-position (world x y)
  (loop for overlap = (find-if
                       (lambda (group)
                         (and (< x (+ (subworld-x group) (%meta-footprint-width group) 96d0))
                              (> (+ x 1496d0) (subworld-x group))
                              (< y (+ (subworld-y group) (%meta-footprint-height group) 96d0))
                              (> (+ y 896d0) (subworld-y group))))
                       (metaworld-subworlds world))
        while overlap do (setf x (+ (subworld-x overlap) (%meta-footprint-width overlap) 96d0))
        finally (return (list x y))))
