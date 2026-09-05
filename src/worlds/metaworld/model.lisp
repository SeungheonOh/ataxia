(in-package #:ataxia.infinite-world)

(defvar *meta-layout-motion* nil)

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
  (last-camera nil) (last-focus nil))

(defclass metaworld (infinite-world)
  ((subworlds :initform nil :accessor metaworld-subworlds)
   (next-subworld-id :initform 0 :accessor %meta-next-id)
   (owners :initform (make-hash-table :test #'eq) :reader %meta-owners)
   (group-focus :initform (make-hash-table :test #'eq) :reader %meta-group-focus)
   (views :initform (make-hash-table :test #'eq) :reader %meta-views)
   (modifiers :initform (make-hash-table :test #'eq) :reader %meta-modifiers)
   (standalone :initarg :standalone :initform nil :accessor %meta-standalone)
   (state-file :initarg :state-file :initform nil :reader %meta-state-file)
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
  (or (and seat (gethash seat (%world-seats world)))
      (first (%seat-states world))))

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

(defun %meta-visible-members (group &key include-floating)
  (remove-if-not
   (lambda (member)
     (and (= (subworld-workspace group) (subworld-member-workspace member))
          (%meta-mapped-p (subworld-member-object member))
          (or include-floating (not (subworld-member-floating-p member)))))
   (subworld-members group)))

(defun %meta-columns (group)
  (remove-duplicates
   (mapcar #'subworld-member-column (%meta-visible-members group))
   :from-end t))

(defun %meta-footprint-width (group)
  (if (eq (subworld-kind group) :niri)
      (max (subworld-width group)
           (+ 32d0
              (loop for column in (%meta-columns group)
                    for member = (find column (%meta-visible-members group)
                                       :key #'subworld-member-column)
                    sum (+ 14d0 (subworld-member-width member)))))
      (subworld-width group)))

(defun %meta-group-at (world x y)
  (find-if
   (lambda (group)
     (and (<= (subworld-x group) x
              (+ (subworld-x group) (%meta-footprint-width group)))
          (<= (subworld-y group) y
              (+ (subworld-y group) (subworld-height group)))))
   (reverse (metaworld-subworlds world))))

(defun %meta-camera (state)
  (list (%canvas-output-camera-x state) (%canvas-output-camera-y state)
        (%canvas-output-zoom state) (%canvas-output-rotation state)))

(defun %meta-set-camera (world state camera)
  (destructuring-bind (x y zoom &optional (rotation 0d0)) camera
    (setf (%canvas-output-rotation state) (coerce rotation 'double-float)
          (%canvas-output-target-rotation state) (coerce rotation 'double-float))
    (set-output-camera world (%canvas-output-output state) x y zoom)))

(defun %meta-transition-camera (world state origin)
  (let ((destination (%meta-camera state)))
    (unless (equal origin destination)
      (%meta-set-camera world state origin)
      (ataxia.world:start-animation
       (%world-animator world) state :metaworld-camera (%now) 0.24d0
       (lambda (subject progress)
         (%meta-set-camera
          world subject
          (mapcar (lambda (start end) (+ start (* progress (- end start))))
                  origin destination))
         (%meta-sync-ui world subject))
       :easing #'ataxia.world:ease-out-cubic)
      (%request-output-state-frame world state))))

(defun %meta-changed (world)
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
                                                    (subworld-height entry)))))
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
                              (< y (+ (subworld-y group) (subworld-height group) 96d0))
                              (> (+ y 896d0) (subworld-y group))))
                       (metaworld-subworlds world))
        while overlap do (setf x (+ (subworld-x overlap) (%meta-footprint-width overlap) 96d0))
        finally (return (list x y))))
