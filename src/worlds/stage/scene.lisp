;;;; Retained scene graph and director commits.
;;;;
;;;; A commit is applied in order and finished as one unit. Nodes removed in a
;;;; commit hand their displayed motion state to new nodes with the same
;;;; identity, so remounts, re-parenting and hot reloads animate instead of
;;;; jumping. A removed node with exit values stays visible until they settle.

(in-package #:ataxia.stage-world)

(defstruct (scene (:constructor make-scene (&key natural-value)))
  (nodes (make-hash-table :test #'eql) :read-only t)
  (root (%make-stage-node 0 :root) :read-only t)
  ;; Nodes with at least one moving channel, including exiting ones.
  (active (make-hash-table :test #'eq) :read-only t)
  (exiting nil :type list)
  ;; (NODE KEY) -> displayed value used when a property first gains a channel
  ;; after creation, e.g. a window's natural width before it is constrained.
  (natural-value (lambda (node key) (declare (ignore node key)) nil) :type function)
  (created nil :type list)
  (removed nil :type list))

(defun scene-node (scene id)
  (if (eql id 0)
      (scene-root scene)
      (or (gethash id (scene-nodes scene))
          (protocol-error "Unknown node ~S." id))))

(defun node-identity (node)
  "Layout identity shared by nodes that represent the same thing across remounts."
  (or (stage-node-layout-id node)
      (when (eq (stage-node-kind node) :window)
        (let ((window (node-prop node :window)))
          (and window (format nil "window:~D" window))))))

(defun %track-activity (scene node)
  (if (node-moving-p node)
      (setf (gethash node (scene-active scene)) t)
      (remhash node (scene-active scene)))
  node)

(defun %set-animated (scene node spec value time from)
  "Retarget SPEC's channels to VALUE; FROM is the starting value for a new channel."
  (let* ((key (prop-spec-key spec))
         (motion (node-motion node key))
         (existing (gethash key (stage-node-channels node))))
    (if (eq (prop-spec-type spec) :color)
        (let ((channels (or existing
                            (let ((start (or from value)))
                              (map 'vector (lambda (component) (make-channel component))
                                   start)))))
          (setf (gethash key (stage-node-channels node)) channels)
          (loop for channel across channels
                for component across value
                do (channel-retarget channel component motion time)))
        (let ((channel (or existing
                           (make-channel (to-channel spec (or from value)) (prop-spec-tolerance spec)))))
          (setf (gethash key (stage-node-channels node)) channel)
          (channel-retarget channel (to-channel spec value) motion time))))
  (%track-activity scene node))

(defun %set-prop (scene node spec raw value time creating-p)
  "Declare SPEC's VALUE, decoded from RAW (NIL resets it), animating it when it animates."
  (let* ((key (prop-spec-key spec))
         (animated-p (and (prop-spec-animated-p spec)
                          (node-kind-animates-p (stage-node-kind node))
                          ;; A held key keeps its manipulated value; the declaration
                          ;; applies when the director changes it after release.
                          (not (member key (stage-node-held node))))))
    (cond
      ((null raw)
       (remhash key (stage-node-props node))
       (when animated-p
         (if value
             (%set-animated scene node spec value time nil)
             (remhash key (stage-node-channels node)))))
      (t
       (setf (gethash key (stage-node-props node)) value)
       (when animated-p
         (%set-animated
          scene node spec value time
          (cond
            (creating-p (getf (stage-node-initial node) key))
            ((gethash key (stage-node-channels node)) nil)
            ;; A gradient appearing on a solid paint starts from that paint.
            ((assoc key +gradient-ends+)
             (multiple-value-call #'vector (node-color node (cdr (assoc key +gradient-ends+)))))
            (t (funcall (scene-natural-value scene) node key)))))))))

(defun %decode-targets (node object)
  "Decode an initial/exit object into a plist of animated property values."
  (unless (hash-table-p object)
    (protocol-error "Expected an object of property values."))
  (let ((targets nil))
    (maphash (lambda (name raw)
               (if (equal name "uniforms")
                   (setf (getf targets :uniforms) (%effect-uniforms node raw))
                   (let ((spec (%prop-spec-for node name)))
                     (unless (prop-spec-animated-p spec)
                       (protocol-error "Property ~A cannot animate." name))
                     (when (null raw)
                       (protocol-error "Animation target ~A needs a value." name))
                     (setf (getf targets (prop-spec-key spec)) (decode-prop-value spec raw)))))
             object)
    targets))

(defun %effect-uniforms (node raw)
  (unless (kind-effects-p (stage-node-kind node))
    (protocol-error "A ~(~A~) node has no effect uniforms." (stage-node-kind node)))
  (and raw (decode-uniforms raw)))

(defun %set-uniforms (scene node uniforms time creating-p)
  "Declare NODE's UNIFORMS; changed values animate with the `uniforms` transition and
new ones start from `initial` when the node is created."
  (let ((motion (node-motion node :uniforms))
        (initial (and creating-p (getf (stage-node-initial node) :uniforms))))
    (setf (stage-node-uniforms node)
          (loop for (name . value) in uniforms
                for previous = (cdr (assoc name (stage-node-uniforms node) :test #'equal))
                for start = (or (and previous (= (length previous) (length value)) previous)
                                (let ((from (cdr (assoc name initial :test #'equal))))
                                  (map 'vector #'make-channel
                                       (if (and from (= (length from) (length value))) from value))))
                do (map nil (lambda (channel component) (channel-retarget channel component motion time))
                        start value)
                collect (cons name start))))
  (%track-activity scene node))

(defun %decode-motions (node object)
  "Alist of property key (or :DEFAULT) to motion from a transition OBJECT."
  (unless (or (null object) (hash-table-p object))
    (protocol-error "transition must be an object."))
  (let ((motions nil))
    (when object
      (maphash (lambda (name spec)
                 (let ((key (cond ((equal name "default") :default)
                                  ((equal name "uniforms") :uniforms)
                                  (t (prop-spec-key (or (gethash name +prop-specs+)
                                                        (protocol-error "Unknown property ~S." name)))))))
                   ;; A motion for a property this kind lacks is moot, not an error:
                   ;; a shared transition object may name more than one kind uses.
                   (when (or (eq key :default)
                             (and (eq key :uniforms) (kind-effects-p (stage-node-kind node)))
                             (member key (kind-props (stage-node-kind node))))
                     (push (cons key (decode-motion spec)) motions))))
               object))
    motions))

(defun %apply-props (scene node props time &optional creating-p)
  "Apply PROPS to NODE. Everything is decoded first, so a rejected op changes nothing."
  (unless (hash-table-p props)
    (protocol-error "Node properties must be an object."))
  (let ((values nil) (metadata nil) (uniforms :absent))
    (maphash (lambda (name raw)
               (cond
                 ((equal name "uniforms") (setf uniforms (%effect-uniforms node raw)))
                 ((equal name "transition") (push (cons :motions (%decode-motions node raw)) metadata))
                 ((equal name "initial")
                  (when (and creating-p raw) (push (cons :initial (%decode-targets node raw)) metadata)))
                 ((equal name "exit") (push (cons :exit (and raw (%decode-targets node raw))) metadata))
                 ((equal name "layoutId")
                  (unless (or (null raw) (stringp raw)) (protocol-error "layoutId must be a string."))
                  (push (cons :layout-id raw) metadata))
                 ((equal name "animate") (push (cons :layers (decode-layers node raw)) metadata))
                 ((equal name "handlers")
                  (push (cons :handlers (loop for name in (and raw (%json-list raw "handlers"))
                                              for event = (cdr (assoc name +event-names+ :test #'equal))
                                              when event collect event))
                        metadata))
                 (t (let ((spec (%prop-spec-for node name)))
                      (push (list spec raw (decode-prop-value spec raw)) values)))))
             props)
    ;; Metadata first: a commit changing both a transition and a value animates
    ;; that value with the new transition.
    (loop for (field . value) in metadata
          do (ecase field
               (:motions (clrhash (stage-node-motions node))
                (loop for (key . motion) in value do (setf (gethash key (stage-node-motions node)) motion)))
               (:initial (setf (stage-node-initial node) value))
               (:exit (setf (stage-node-exit node) value))
               (:layout-id (setf (stage-node-layout-id node) value))
               (:handlers (setf (stage-node-handlers node) value))
               (:layers (%start-layers scene node value time))))
    (loop for (spec raw value) in values do (%set-prop scene node spec raw value time creating-p))
    (unless (eq uniforms :absent) (%set-uniforms scene node uniforms time creating-p)))
  node)

(defun %start-layers (scene node layers time)
  "Make LAYERS NODE's animations. One whose id was declared before keeps its start,
so it runs on (or stays finished); the others start at TIME."
  (dolist (layer layers)
    (let ((previous (find (layer-id layer) (stage-node-layers node) :key #'layer-id :test #'equal)))
      (setf (layer-start layer) (if previous (layer-start previous) time)
            (layer-done-p layer) (and previous (layer-done-p previous)))))
  (setf (stage-node-layers node) layers)
  (sample-layers node time)
  (%track-activity scene node))

(defun scene-create (scene id type props time)
  (unless (and (integerp id) (plusp id))
    (protocol-error "Node ids must be positive integers."))
  (when (gethash id (scene-nodes scene))
    (protocol-error "Node ~D already exists." id))
  (let ((node (%make-stage-node id (second (find-node-kind type)))))
    (%apply-props scene node props time t)
    (setf (gethash id (scene-nodes scene)) node)
    (push node (scene-created scene))
    node))

(defun scene-update (scene id props time)
  (%apply-props scene (scene-node scene id) props time))

(defun %detach-child (node)
  (let ((parent (stage-node-parent node)))
    (when parent
      (setf (stage-node-children parent) (delete node (stage-node-children parent) :test #'eq)
            (stage-node-parent node) nil))))

(defun scene-insert (scene parent-id id before-id)
  "Insert node ID into PARENT-ID before BEFORE-ID, or last when BEFORE-ID is NIL."
  (let ((parent (scene-node scene parent-id))
        (node (scene-node scene id))
        (before (and before-id (scene-node scene before-id))))
    (when (or (eq node parent)
              (loop for ancestor = parent then (stage-node-parent ancestor)
                    while ancestor thereis (eq ancestor node)))
      (protocol-error "Node ~D cannot contain itself." id))
    (when (and before (not (eq parent (stage-node-parent before))))
      (protocol-error "Node ~D is not a child of ~D." before-id parent-id))
    (%detach-child node)
    (setf (stage-node-parent node) parent
          (stage-node-children parent)
          (let ((position (and before (position before (stage-node-children parent)))))
            (if position
                (append (subseq (stage-node-children parent) 0 position)
                        (list node)
                        (nthcdr position (stage-node-children parent)))
                (append (stage-node-children parent) (list node)))))
    node))

(defun %walk-subtree (node function)
  (funcall function node)
  (dolist (child (stage-node-children node))
    (%walk-subtree child function)))

(defun scene-remove (scene parent-id id)
  (let ((node (scene-node scene id)))
    (unless (eq (scene-node scene parent-id) (stage-node-parent node))
      (protocol-error "Node ~D is not a child of ~D." id parent-id))
    (%walk-subtree node (lambda (child)
                          (when (eq (stage-node-state child) :live)
                            (setf (stage-node-state child) :removed))
                          (remhash (stage-node-id child) (scene-nodes scene))))
    (push node (scene-removed scene))
    node))

(defun %destroy-node (scene node)
  (%detach-child node)
  ;; Descendants may be exiting on their own; none of them may linger.
  (%walk-subtree node (lambda (child)
                        (setf (stage-node-state child) :dead)
                        (remhash child (scene-active scene))
                        (setf (scene-exiting scene) (delete child (scene-exiting scene) :test #'eq)))))

(defun scene-clear (scene)
  "Remove every top-level node within the current commit. Replacements created in
the same commit inherit their motion; nothing else plays an exit, because a new
director may reuse the old node ids."
  (dolist (child (copy-list (stage-node-children (scene-root scene))))
    (if (eq (stage-node-state child) :live)
        (progn (setf (stage-node-exit child) nil)
               (scene-remove scene 0 (stage-node-id child)))
        (%destroy-node scene child))))

(defun %channel-snapshot (node)
  (let ((snapshot nil))
    (maphash (lambda (key value)
               (push (cons key (if (vectorp value)
                                   (map 'vector (lambda (channel)
                                                  (cons (channel-value channel)
                                                        (channel-velocity channel)))
                                        value)
                                   (cons (channel-value value) (channel-velocity value))))
                     snapshot))
             (stage-node-channels node))
    snapshot))

(defun %inherit-motion (scene node snapshot time)
  (loop for (key . state) in snapshot
        for channels = (gethash key (stage-node-channels node))
        for motion = (node-motion node key)
        when channels
          do (if (vectorp channels)
                 (loop for channel across channels
                       for (value . velocity) across state
                       do (channel-inherit channel value velocity motion time))
                 (channel-inherit channels (car state) (cdr state) motion time)))
  (%track-activity scene node))

(defun node-target (node key)
  "Destination of KEY: its channel target while one exists, else the declared value."
  (let ((channel (gethash key (stage-node-channels node))))
    (if (and channel (not (vectorp channel)))
        (from-channel (find-prop-spec key) (channel-target channel))
        (node-prop node key))))

(defun node-jump (scene node key value)
  "Show VALUE for numeric KEY at once, creating its channel when needed."
  (let ((spec (find-prop-spec key)))
    (channel-jump (or (gethash key (stage-node-channels node))
                      (setf (gethash key (stage-node-channels node))
                            (make-channel 0d0 (prop-spec-tolerance spec))))
                  (to-channel spec value))
    (%track-activity scene node)))

(defun %displayed-value (scene node spec)
  (let ((key (prop-spec-key spec)))
    (if (eq (prop-spec-type spec) :color)
        (multiple-value-call #'vector (node-color node key))
        (or (node-number node key) (funcall (scene-natural-value scene) node key) 0d0))))

(defun %begin-exit (scene node time)
  (setf (stage-node-state node) :exiting
        ;; An endless animation would keep the node from ever leaving.
        (stage-node-layers node) (remove-if (lambda (layer) (track-endless-p (layer-track layer)))
                                            (stage-node-layers node)))
  (loop for (key value) on (stage-node-exit node) by #'cddr
        do (if (eq key :uniforms)
               (loop with motion = (node-motion node :uniforms)
                     for (name . components) in value
                     for channels = (cdr (assoc name (stage-node-uniforms node) :test #'equal))
                     when (and channels (= (length channels) (length components)))
                       do (map nil (lambda (channel component)
                                     (channel-retarget channel component motion time))
                               channels components))
               (let ((spec (find-prop-spec key)))
                 (%set-animated scene node spec value time (%displayed-value scene node spec)))))
  (%track-activity scene node)
  (if (node-moving-p node)
      (push node (scene-exiting scene))
      (%destroy-node scene node)))

(defun scene-finish-commit (scene time)
  "Transfer motion between same-identity nodes, then retire removed nodes."
  (let ((stash (make-hash-table :test #'equal))
        (claimed (make-hash-table :test #'eq)))
    (dolist (removed (scene-removed scene))
      (%walk-subtree removed
                     (lambda (node)
                       (let ((identity (node-identity node)))
                         (when (and identity (not (gethash identity stash)))
                           (setf (gethash identity stash) node))))))
    (dolist (node (reverse (scene-created scene)))
      (let* ((identity (node-identity node))
             (previous (and identity (gethash identity stash))))
        (when previous
          (remhash identity stash)
          (setf (gethash previous claimed) t)
          (%inherit-motion scene node (%channel-snapshot previous) time))))
    (dolist (removed (scene-removed scene))
      ;; A claimed node now lives on elsewhere; never draw it twice.
      (%walk-subtree removed (lambda (node)
                               (when (gethash node claimed)
                                 (setf (stage-node-state node) :dead))))
      (if (and (stage-node-exit removed)
               (eq (stage-node-state removed) :removed)
               (stage-node-parent removed)
               (not (eq (stage-node-state (stage-node-parent removed)) :dead)))
          (%begin-exit scene removed time)
          (%destroy-node scene removed)))
    (setf (scene-created scene) nil
          (scene-removed scene) nil)))

(defun scene-advance (scene time)
  "Sample every moving channel at TIME. Return true while motion remains."
  (loop for node being the hash-keys of (scene-active scene)
        do (loop for value being the hash-values of (stage-node-channels node)
                 do (if (vectorp value)
                        (map nil (lambda (channel) (channel-sample channel time)) value)
                        (channel-sample value time)))
           (loop for (nil . channels) in (stage-node-uniforms node)
                 do (map nil (lambda (channel) (channel-sample channel time)) channels))
           (sample-layers node time)
           (%track-activity scene node))
  (dolist (node (copy-list (scene-exiting scene)))
    (unless (node-moving-p node)
      (%destroy-node scene node)))
  (scene-moving-p scene))

(defun scene-moving-p (scene)
  (plusp (hash-table-count (scene-active scene))))

(defun scene-settling-p (scene)
  "True while any channel or layer runs a motion that will finish, as opposed to an endless loop."
  (loop for node being the hash-keys of (scene-active scene)
          thereis (or (layers-running-p node t)
                      (loop for (nil . channels) in (stage-node-uniforms node)
                              thereis (some (lambda (channel)
                                              (and (channel-active-p channel)
                                                   (not (motion-loops-p (channel-motion channel)))))
                                            channels))
                      (loop for value being the hash-values of (stage-node-channels node)
                              thereis (some (lambda (channel)
                                              (and (channel-active-p channel)
                                                   (not (motion-loops-p (channel-motion channel)))))
                                            (if (vectorp value) value (list value)))))))

(defun map-scene-nodes (function scene)
  "Call FUNCTION on every live node in paint order."
  (labels ((visit (node)
             (dolist (child (stage-node-children node))
               (when (eq (stage-node-state child) :live)
                 (funcall function child)
                 (visit child)))))
    (visit (scene-root scene))))

(defun scene-description (scene)
  "Live nodes with their declared properties, as nested plists."
  (labels ((describe-node (node)
             (append (list :id (stage-node-id node) :kind (stage-node-kind node))
                     (loop for key being the hash-keys of (stage-node-props node)
                             using (hash-value value)
                           append (list key value))
                     (let ((children (remove :live (stage-node-children node)
                                             :key #'stage-node-state :test-not #'eq)))
                       (when children
                         (list :children (mapcar #'describe-node children)))))))
    (mapcar #'describe-node (remove :live (stage-node-children (scene-root scene))
                                   :key #'stage-node-state :test-not #'eq))))
