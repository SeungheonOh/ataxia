(in-package #:ataxia.infinite-world)

(defun %meta-object-geometry (object)
  (etypecase object
    (canvas-window
     (list (canvas-window-x object) (canvas-window-y object)
           (canvas-window-width object) (canvas-window-height object)))
    (agent-widget
     (or (gethash object (%meta-spatial-widgets (agent-widget-world object)))
         (list (overlay-x object) (overlay-y object)
               (overlay-width object) (overlay-height object))))))

(defun %meta-place (world object x y width height)
  ;; Layout may retarget neighbors during a grab, but must never move the grab.
  (when (and *meta-layout-motion* (%meta-dragged-p world object))
    (return-from %meta-place object))
  (let* ((destination (list (coerce x 'double-float) (coerce y 'double-float)
                            (max 96d0 (coerce width 'double-float))
                            (max 64d0 (coerce height 'double-float))))
         (origin (%meta-object-geometry object))
         (target (%meta-target-geometry world object))
         (animate-p (and *meta-layout-motion* (not (%meta-restoring-p world))
                         (%target-visible-p object))))
    (when (and animate-p (equalp target destination))
      (return-from %meta-place object))
    (when (typep object 'canvas-window) (%damage-window world object))
    ;; Request the final client size once. Presentation scales the latest buffer
    ;; while the displayed rectangle interpolates, without configure storms.
    (unless (and (= (round (third target)) (round (third destination)))
                 (= (round (fourth target)) (round (fourth destination))))
      (etypecase object
        (canvas-window
         (ataxia.kernel:request-object-configuration
          (canvas-window-application object) world
          (make-instance 'ataxia.kernel:toplevel-configuration
                         :width (round (third destination)) :height (round (fourth destination)))))
        (agent-widget
         (ataxia.world:ui-resize
          (overlay-component object) (third destination) (fourth destination)))))
    (flet ((place (subject geometry)
             (etypecase subject
               (canvas-window
                (setf (canvas-window-x subject) (first geometry)
                      (canvas-window-y subject) (second geometry)
                      (canvas-window-width subject) (third geometry)
                      (canvas-window-height subject) (fourth geometry)))
               (agent-widget
                (setf (gethash subject (%meta-spatial-widgets world)) geometry)))))
      (if (and animate-p (or (not (equalp origin destination))
                             (%meta-motion world object :metaworld-layout)))
          (%meta-animate-to world object :metaworld-layout origin destination 0.22d0 #'place
                            :bounds (list nil nil (list 96d0 most-positive-double-float)
                                          (list 64d0 most-positive-double-float)))
          (progn
            (%meta-cancel-motion world object :metaworld-layout)
            (place object destination))))
    (when (typep object 'canvas-window)
      (%damage-window world object)
      (%update-window-membership world object)))
  object)

(defun %meta-translate-object (world object dx dy)
  ;; Translate both the displayed sample and the path. A moving group must not
  ;; freeze a child's in-flight layout or leave its destination behind.
  (let ((motion (%meta-motion world object :metaworld-layout)))
    (when motion
      (dolist (geometry (list (%meta-trajectory-origin motion) (%meta-trajectory-destination motion)))
        (incf (first geometry) dx)
        (incf (second geometry) dy))))
  (etypecase object
    (canvas-window
     (%damage-window world object)
     (incf (canvas-window-x object) dx)
     (incf (canvas-window-y object) dy)
     (%damage-window world object)
     (%update-window-membership world object))
    (agent-widget
     (let ((geometry (copy-list (%meta-object-geometry object))))
       (incf (first geometry) dx)
       (incf (second geometry) dy)
       (setf (gethash object (%meta-spatial-widgets world)) geometry))))
  object)

(defun %meta-set-visible (world object visible-p)
  (when (and (typep object 'canvas-window) (%canvas-window-minimized-p object))
    (setf visible-p nil))
  (let ((group (object-subworld world object)))
    (when (and (typep object 'canvas-window) group (eq :hyprland (subworld-kind group)))
      (return-from %meta-set-visible (%meta-hypr-set-visible world object visible-p))))
  (when (typep object 'canvas-window)
    (%meta-cancel-motion world object :visibility)
    (setf (%canvas-window-input-enabled-p object) (not (null visible-p))
          (%canvas-window-visibility-opacity object) 1d0))
  (etypecase object
    (canvas-window
     (unless (eq (not visible-p) (%canvas-window-hidden-p object))
       (%damage-window world object)
       (setf (%canvas-window-hidden-p object) (not visible-p))
       (%damage-window world object)
       (%update-window-membership world object)))
    (agent-widget
     (when (member object (world-overlays world))
       (if visible-p (show-overlay world object) (hide-overlay world object))))))

(defun %meta-grid-rectangles (world members x y width height &optional (gap 14d0))
  ;; When a narrow remainder cannot hold a first-leaf split, use a compact
  ;; grid rather than letting minimum window sizes overlap neighboring tiles.
  (let* ((count (length members))
         (columns (or (loop for cols from 1 to count
                            for rows = (ceiling count cols)
                            when (and (>= (/ (- width (* gap (1- cols))) cols) 96d0)
                                      (>= (/ (- height (* gap (1- rows))) rows) 64d0))
                              return cols)
                      count))
         (rows (ceiling count columns))
         (tile-width (/ (- width (* gap (1- columns))) columns))
         (tile-height (/ (- height (* gap (1- rows))) rows)))
    (loop for member in members for index from 0
          do (%meta-place world (subworld-member-object member)
                          (+ x (* (mod index columns) (+ tile-width gap)))
                          (+ y (* (floor index columns) (+ tile-height gap)))
                          tile-width tile-height))))

(defun %meta-stack-rectangles (world members x y width height &optional (gap 14d0))
  (when members
    (let* ((count (length members))
           (usable (- height (* gap (1- count)))))
      (when (< usable (* 64d0 count))
        (return-from %meta-stack-rectangles (%meta-grid-rectangles world members x y width height gap)))
      (let ((remaining (copy-list members)) (available usable)
            (sizes (make-hash-table :test #'eq)) (top y))
        ;; Reserve the real minimum size before distributing weighted space.
        ;; Advancing by an unclamped share used to overlap skew-weight stacks.
        (loop while remaining do
          (let* ((total (reduce #'+ remaining :key #'subworld-member-weight))
                 (small (remove-if-not
                         (lambda (m) (< (* available (/ (subworld-member-weight m) total)) 64d0)) remaining)))
            (if small
                (dolist (m small)
                  (setf (gethash m sizes) 64d0)
                  (decf available 64d0)
                  (setf remaining (remove m remaining :test #'eq)))
                (progn
                  (dolist (m remaining)
                    (setf (gethash m sizes) (* available (/ (subworld-member-weight m) total))))
                  (setf remaining nil)))))
        (dolist (member members)
          (let ((tile-height (gethash member sizes)))
            (%meta-place world (subworld-member-object member) x top width tile-height)
            (incf top (+ tile-height gap))))))))

(defun %meta-layout-niri (world group members &optional (workspace (subworld-workspace group)))
  (let ((left (subworld-x group))
        (top (%meta-workspace-y group workspace))
        (height (subworld-height group)))
    (dolist (column (%meta-columns group workspace))
      (let* ((rows (remove-if-not
                    (lambda (member) (= column (subworld-member-column member)))
                    members))
             (width (subworld-member-width (first rows))))
        (dolist (member rows) (setf (subworld-member-width member) width))
        (%meta-stack-rectangles world rows left top width height 0d0)
        (incf left width)))))

(defun %meta-layout-dwindle (world group members)
  (%meta-hypr-layout world group members))

(defun %meta-layout-master (world group members)
  (when members
    (let* ((left (+ (subworld-x group) 16d0))
           (top (+ (subworld-y group) 16d0))
           (width (- (subworld-width group) 32d0))
           (height (- (subworld-height group) 32d0))
           (rows (max 1 (floor (/ (+ height 14d0) 78d0))))
           (side-minimum (- (* (ceiling (length (rest members)) rows) 110d0) 14d0))
           (master-width (if (rest members)
                             (max 96d0 (min (- width 14d0 side-minimum)
                                           (* (- width 14d0) (subworld-ratio group))))
                             width)))
      (when (and (rest members) (< width (+ 110d0 side-minimum)))
        (return-from %meta-layout-master (%meta-grid-rectangles world members left top width height)))
      (%meta-place world (subworld-member-object (first members))
                   left top master-width height)
      (when (rest members)
        (%meta-stack-rectangles world (rest members)
                                (+ left master-width 14d0) top
                                (- width master-width 14d0) height)))))

(defun %meta-raise-floating (world group)
  (when group
    (dolist (window (copy-list (%world-stacking world)))
      (let ((member (%meta-member group window)))
        (when (and member (subworld-member-floating-p member) (%window-visible-p window))
          (%raise-window world window))))))

(defun %meta-layout (world group)
  (when *meta-layout-deferred-p*
    (when group (pushnew group *meta-layout-pending* :test #'eq))
    (return-from %meta-layout group))
  (let ((*meta-layout-motion* t))
   (when group
    (dolist (member (copy-list (subworld-members group)))
      (let ((object (subworld-member-object member)))
        (when (and (typep object 'agent-widget) (not (member object (world-overlays world))))
          (setf (subworld-members group) (remove member (subworld-members group)))
          (remhash object (%meta-owners world))
          (remhash object (%meta-spatial-widgets world)))))
    (let ((fullscreen (subworld-fullscreen group))
          (niri-p (eq :niri (subworld-kind group))))
      (dolist (member (subworld-members group))
        (%meta-set-visible
         world (subworld-member-object member)
         (and (or niri-p (= (subworld-workspace group) (subworld-member-workspace member)))
              (or (null fullscreen)
                  (and niri-p (/= (subworld-workspace group) (subworld-member-workspace member)))
                  (eq fullscreen (subworld-member-object member))))))
      (if niri-p
          (loop for workspace from 1 to (%meta-workspace-count group)
                unless (and fullscreen (= workspace (subworld-workspace group)))
                  do (%meta-layout-niri world group (%meta-visible-members group :workspace workspace)
                                        workspace))
          (unless fullscreen
            (let ((members (%meta-visible-members group)))
              (if (eq (subworld-layout group) :master)
                  (%meta-layout-master world group members)
                  (%meta-layout-dwindle world group members)))))
      (when fullscreen
        (if niri-p
            (%meta-place world fullscreen (subworld-x group) (%meta-workspace-y group)
                         (subworld-width group) (subworld-height group))
            (%meta-place world fullscreen
                         (subworld-x group) (subworld-y group)
                         (subworld-width group) (subworld-height group)))))
    (%meta-raise-floating world group)
    (%meta-changed world))))

(defun move-object-to-subworld (world object group &key workspace)
  (check-type world metaworld)
  (check-type object (or canvas-window agent-widget))
  (when (and (typep object 'agent-widget)
             (or (eq object (%meta-menu world))
                 (loop for view being the hash-values of (%meta-views world)
                       thereis (or (eq object (%meta-view-panel view))
                                   (loop for header being the hash-values of (%meta-view-headers view)
                                         thereis (eq object header))))))
    (error "World controls cannot become subworld members."))
  (when (and workspace (not (typep workspace '(integer 1 9))))
    (error "Workspace must be between 1 and 9."))
  (unless (or (null group) (member group (metaworld-subworlds world) :test #'eq))
    (error "Destination does not belong to this metaworld."))
  (unless (etypecase object
            (canvas-window (eq object (find-canvas-window
                                      world (canvas-window-application object))))
            (agent-widget (member object (world-overlays world))))
    (error "Object does not belong to this metaworld."))
  (let* ((previous (object-subworld world object))
         (member (and previous (%meta-member previous object))))
    (when (and (typep object 'agent-widget)
               (not (gethash object (%meta-spatial-widgets world))))
      (let ((state (gethash (overlay-output object) (%world-outputs world))))
        (multiple-value-bind (x y)
            (%screen-to-world state (overlay-x object) (overlay-y object))
          (setf (gethash object (%meta-spatial-widgets world))
                (list x y (/ (overlay-width object) (%canvas-output-zoom state))
                      (/ (overlay-height object) (%canvas-output-zoom state)))))))
    (when (eq previous group)
      (when (and member workspace)
        (setf (subworld-member-workspace member) workspace)
        (%meta-layout world group))
      (return-from move-object-to-subworld object))
    (when previous
      (when (eq object (gethash previous (%meta-group-focus world)))
        (remhash previous (%meta-group-focus world)))
      (setf (subworld-members previous)
            (remove member (subworld-members previous)))
      (when (eq (subworld-fullscreen previous) object)
        (setf (subworld-fullscreen previous) nil)
        (when (typep object 'canvas-window)
          (ataxia.kernel:request-object-state (canvas-window-application object) world :fullscreen nil)))
      (remhash object (%meta-owners world)))
    (%meta-set-visible world object t)
    (when group
        (let ((entry (%make-subworld-member
                      :object object :workspace (or workspace (subworld-workspace group))
                      :column (incf (subworld-next-column group))
                      :width (* 0.48d0 (- (subworld-width group) 32d0))
                      :restore-geometry (if member (subworld-member-restore-geometry member)
                                            (%meta-object-geometry object)))))
          (setf (gethash object (%meta-owners world)) group
                (subworld-members group) (append (subworld-members group) (list entry)))))
    (%meta-layout world previous)
    (%meta-layout world group)
    (%meta-changed world)
    object))

(defun %meta-clamp-scroll (group scroll viewport-width)
  (max 0d0 (min scroll (max 0d0 (- (%meta-workspace-width group (subworld-workspace group))
                                   viewport-width)))))

(defun %meta-fit-group (world state group &key overview-p)
  (multiple-value-bind (work-x work-y width height) (%canvas-work-area world state)
    (let* ((group-width (if overview-p (%meta-footprint-width group) (subworld-width group)))
           (group-height (if overview-p (%meta-footprint-height group) (subworld-height group)))
           (group-y (if overview-p (subworld-y group) (%meta-workspace-y group)))
           ;; Entered Niri fills the work area. Its horizontal strip
           ;; may overflow; fitting both dimensions would letterbox wide groups.
           (niri-p (and (not overview-p) (eq :niri (subworld-kind group))))
           (zoom (if niri-p (/ height group-height)
                     (max 0.08d0 (min 8d0 (/ width group-width) (/ height group-height)))))
           (viewport-width (if niri-p (/ width zoom) (subworld-width group)))
           (scroll (if niri-p
                       (%meta-clamp-scroll group
                                           (gethash (subworld-workspace group) (subworld-scrolls group) 0d0)
                                           viewport-width)
                       0d0)))
      (unless overview-p
        (setf (gethash (subworld-workspace group) (subworld-scrolls group)) scroll))
      (%meta-set-camera
       world state
       (list (- (+ (subworld-x group) scroll) (if niri-p 0d0 (/ (- width (* group-width zoom)) (* 2d0 zoom)))
                (/ work-x zoom))
             (- group-y (/ (- height (* group-height zoom)) (* 2d0 zoom)) (/ work-y zoom))
             zoom 0d0)))))

(defun %meta-refit-work-area (world output)
  (let* ((state (gethash output (%world-outputs world)))
         (group (and state (%meta-view-active (%meta-view-for-state world state)))))
    (when group
      (%meta-cancel-motion world state :metaworld-camera)
      (when (%meta-standalone world)
        (multiple-value-bind (x y width height) (%canvas-work-area world state)
          (declare (ignore x y))
          (setf (subworld-width group) width (subworld-height group) height))
        (%meta-layout world group))
      (%meta-fit-group world state group))))

(defun %meta-focus (world object &optional seat (animate-p t))
  (let ((seat-state (%meta-seat world seat)))
    (when seat-state
      (%focus-target world seat-state object)
      (let ((group (and object (object-subworld world object)))
            (state (%canvas-seat-output seat-state)))
        (when group
          (setf (gethash group (%meta-group-focus world)) object)
          (let ((member (%meta-member group object)))
            (when member
              (setf (gethash (subworld-member-workspace member)
                             (or (gethash group *meta-workspace-focus*)
                                 (setf (gethash group *meta-workspace-focus*) (make-hash-table)))) object))))
        (%meta-raise-floating world group)
        (when (and group state (not (%meta-dragged-p world object)) (eq group (%meta-current world seat))
                   (eq :niri (subworld-kind group)))
          (multiple-value-bind (work-x work-y width height) (%canvas-work-area world state)
            (declare (ignore work-y height))
            (let* ((object-x (first (%meta-target-geometry world object)))
                   (object-width (third (%meta-target-geometry world object)))
                   (camera-x (+ (%canvas-output-camera-x state) (/ work-x (%canvas-output-zoom state))))
                   (visible-width (/ width (%canvas-output-zoom state)))
                   (left-limit (subworld-x group))
                   (origin (%meta-camera state))
                   (desired (cond
                              ((> object-width visible-width)
                               (- (+ object-x (/ object-width 2d0)) (/ visible-width 2d0)))
                              ((< object-x camera-x) object-x)
                              ((> (+ object-x object-width) (+ camera-x visible-width))
                               (- (+ object-x object-width) visible-width))
                              (t camera-x)))
                   (destination (+ left-limit (%meta-clamp-scroll group (- desired left-limit) visible-width))))
              (unless (= destination camera-x)
                (set-output-camera world (%canvas-output-output state) (- destination (/ work-x (%canvas-output-zoom state)))
                                   (%canvas-output-camera-y state) (%canvas-output-zoom state)))
              (setf (gethash (subworld-workspace group) (subworld-scrolls group))
                    (- destination left-limit))
              (when animate-p (%meta-transition-camera world state origin))))))))
  (%meta-changed world)
  object)

(defun enter-subworld (world group &optional seat)
  (unless (member group (metaworld-subworlds world) :test #'eq)
    (error "Subworld does not belong to this world."))
  (let* ((seat-state (%meta-seat world seat))
         (state (if seat-state (%canvas-seat-output seat-state) (%first-output-state world)))
         (view (%meta-view-for-state world state))
         (origin (and state (%meta-camera state))))
    (when view
      (unless (%meta-view-active view)
        (setf (%meta-view-parent-camera view) (%meta-camera state)))
      (setf (%meta-view-active view) group
            (%meta-view-panel-until view) 0d0)
      (%meta-fit-group world state group)
      (%meta-focus world
                   (or (let* ((table (gethash group *meta-workspace-focus*))
                              (previous (and table (gethash (subworld-workspace group) table))))
                         (when (and (eq group (object-subworld world previous))
                                    (%target-visible-p previous)) previous))
                       (some (lambda (member)
                           (let ((object (subworld-member-object member)))
                             (when (%target-visible-p object) object)))
                         (%meta-visible-members group :include-floating t))) seat nil)
      (%meta-transition-camera world state origin)))
  (%meta-changed world)
  group)

(defun leave-subworld (world &optional seat)
  (let* ((seat-state (%meta-seat world seat))
         (state (if seat-state (%canvas-seat-output seat-state) (%first-output-state world)))
         (view (%meta-view-for-state world state))
         (origin (and state (%meta-camera state))))
    (when (and view (%meta-view-active view))
      (if (%meta-standalone world)
          (%meta-fit-group world state (%meta-view-active view) :overview-p t)
          (progn
            (setf (%meta-view-active view) nil)
            (when (%meta-view-parent-camera view)
              (%meta-set-camera world state (%meta-view-parent-camera view)))))
      (%meta-transition-camera world state origin)
      (setf (%meta-view-panel-until view) 0d0)))
  (%meta-changed world))

(defun %meta-translate-subworld (world group x y)
  (let ((shift-x (- x (subworld-x group)))
        (shift-y (- y (subworld-y group)))
        (*meta-layout-motion* nil))
    (setf (subworld-x group) (coerce x 'double-float)
          (subworld-y group) (coerce y 'double-float))
    (dolist (member (subworld-members group))
      (let ((object (subworld-member-object member)))
        (let ((saved (subworld-member-restore-geometry member)))
          (when saved
            (setf (subworld-member-restore-geometry member)
                  (list (+ (first saved) shift-x) (+ (second saved) shift-y)
                        (third saved) (fourth saved)))))
        (%meta-translate-object world object shift-x shift-y))))
  group)

(defun move-subworld (world group x y)
  (unless (member group (metaworld-subworlds world) :test #'eq)
    (error "Subworld does not belong to this world."))
  (check-type x real)
  (check-type y real)
  (let ((direction (list (- x (subworld-x group)) (- y (subworld-y group)))))
    (%meta-cancel-motion world group :subworld-push)
    (%meta-translate-subworld world group x y)
    (%meta-push-subworlds world group direction))
  (%meta-changed world)
  group)

(defun remove-subworld (world group)
  (when (%meta-standalone world)
    (error "A standalone world's only layout cannot be removed."))
  (%meta-cancel-motion world group :subworld-push)
  (dolist (state (%output-states world))
    (let ((view (%meta-view-for-state world state)))
      (when (eq group (%meta-view-active view))
        (setf (%meta-view-active view) nil)
        (when (%meta-view-parent-camera view)
          (%meta-set-camera world state (%meta-view-parent-camera view))))))
  (dolist (member (copy-list (subworld-members group)))
    (move-object-to-subworld world (subworld-member-object member) nil))
  (setf (metaworld-subworlds world) (remove group (metaworld-subworlds world)))
  (remhash group (%meta-group-focus world))
  (%meta-changed world))

(defun %meta-niri-drop-side (geometry x y control-p)
  "Top/bottom quarter in the center of a tile stacks; side drops make columns."
  (destructuring-bind (left top width height) geometry
    (cond (control-p (if (< y (+ top (/ height 2d0))) :above :below))
          ((<= (+ left (* width 0.25d0)) x (+ left (* width 0.75d0)))
           (cond ((< y (+ top (* height 0.25d0))) :above)
                 ((>= y (+ top (* height 0.75d0))) :below))))))

(defun %meta-insert-member (group member target after-p stack-p)
  (let ((members (remove member (subworld-members group))))
    (setf (subworld-members group)
          (loop for entry in members
                when (and (eq entry target) (not after-p)) collect member
                collect entry
                when (and (eq entry target) after-p) collect member)))
  (when (eq :niri (subworld-kind group))
    (setf (subworld-member-column member)
          (if stack-p (subworld-member-column target) (incf (subworld-next-column group))))
    (when stack-p
      (setf (subworld-member-width member) (subworld-member-width target)
            (subworld-member-workspace member) (subworld-member-workspace target))))
  member)
