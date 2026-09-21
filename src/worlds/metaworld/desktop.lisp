;;;; Metaworld's interpretation of portable desktop and shell operations.
(in-package #:ataxia.infinite-world)

(defmethod ataxia.world:world-supports-p ((world metaworld) capability)
  (or (member capability '(:shell-navigation :layout)) (call-next-method)))
(defmethod ataxia.world:world-output-work-area-changed :after ((world metaworld) output)
  (%meta-refit-work-area world output))
(defmethod ataxia.world:world-shell-state ((world metaworld) output)
  (let* ((state (gethash output (%world-outputs world)))
         (group (and state (%meta-view-active (%meta-view-for-state world state)))))
    (list :name (if group (subworld-name group) "Overview")
          :active (not (null group)) :selected (if group (subworld-workspace group) 0)
          :group (and group (subworld-id group))
          :count (if group (%meta-workspace-count group) 0)
          :groups
          (loop for entry in (metaworld-subworlds world) collect
            (list :id (subworld-id entry) :name (subworld-name entry)
                  :selected (eq entry group) :workspace (subworld-workspace entry)
                  :removable (not (%meta-standalone world))
                  :workspaces
                  (loop for number from 1 to (%meta-workspace-count entry) collect
                    (let ((members (%meta-workspace-members entry number)))
                      (list :number number :count (length members)
                            :removable (> (%meta-workspace-count entry) 1)
                            :titles (loop for member in members
                                          for object = (subworld-member-object member)
                                          for app = (ataxia.world:window-application object)
                                          when app collect (or (ataxia.kernel:application-title app) "Untitled"))))))))))
(defmethod ataxia.world:world-shell-action ((world metaworld) output seat action &optional number)
  (let* ((state (gethash output (%world-outputs world)))
         (group (%meta-view-active (%meta-view-for-state world state)))
         (groups (metaworld-subworlds world)))
    (case action
      (:overview (%meta-overview world seat state))
      (:select-workspace
       (destructuring-bind (id workspace) number
         (let ((destination (find id groups :key #'subworld-id :test #'eql)))
           (when (and destination (typep workspace '(integer 1 9)))
             (unless (eq group destination) (enter-subworld world destination seat))
             (%meta-switch-workspace world destination workspace seat)))))
      (:remove-workspace
       (destructuring-bind (id workspace) number
         (let ((destination (find id groups :key #'subworld-id :test #'eql)))
           (when destination (%meta-remove-workspace world destination workspace seat)))))
      (:remove-subworld
       (let ((destination (find number groups :key #'subworld-id :test #'eql)))
         (when (and destination (not (%meta-standalone world)))
           (remove-subworld world destination))))
      (:workspace
       (if group (%meta-switch-workspace world group number seat)
           (when (nth (1- number) groups) (enter-subworld world (nth (1- number) groups) seat))))
      ((:previous :next)
       (when groups
         (enter-subworld world
                         (nth (mod (+ (or (position group groups) (if (eq action :next) -1 0))
                                      (if (eq action :next) 1 -1)) (length groups)) groups) seat))))
    (%request-output-state-frame world state)))

(defmethod ataxia.world:world-active-operation-p ((world metaworld))
  (or (%meta-group-drag world) (call-next-method)))

(defmethod %desktop-viewport-camera ((world metaworld) state)
  (%desktop-camera world state))
(defmethod %desktop-viewport-geometry ((world metaworld) window)
  (%desktop-object-geometry world window))
(defmethod %apply-desktop-viewport ((world metaworld) state camera)
  ;; Free camera navigation exits this output's fitted group view. It never
  ;; changes group membership, the selected group workspace, or human focus.
  (%meta-cancel-motion world state :metaworld-camera)
  (let ((view (%meta-view-for-state world state)))
    (setf (%meta-view-active view) nil (%meta-view-parent-camera view) nil))
  (setf (%meta-save-needed-p world) t)
  (call-next-method))

(defun %desktop-restore-window (world window)
  (let ((group (object-subworld world window)))
    (when (and group (eq window (subworld-fullscreen group)))
      (%meta-toggle-fullscreen world window nil nil))
    (when (or (%canvas-window-expanded-state window) (%canvas-window-restore-geometry window))
      (%set-window-expanded world window (or (%canvas-window-expanded-state window) :fullscreen) nil nil)
      ;; Also clear flags from expansions made before state tracking was loaded.
      (ataxia.kernel:request-object-state (canvas-window-application window) world :fullscreen nil)
      (ataxia.kernel:request-object-state (canvas-window-application window) world :maximized nil))
    (%set-window-minimized world window nil)
    (when group (%meta-layout world group))))


(defmethod ataxia.world:control-world-window ((world metaworld) window action output)
  (let ((group (object-subworld world window)))
    (cond
      ((eq action :restore) (%desktop-restore-window world window))
      ((and group (member action '(:maximize :fullscreen)))
       (%set-window-minimized world window nil)
       (%meta-toggle-fullscreen world window t nil))
      (t (call-next-method)))))
