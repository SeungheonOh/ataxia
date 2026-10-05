;;;; Seat input routing.
;;;;
;;;; Input is resolved synchronously against the last presented hit list, so
;;;; clients never wait for the director. Windows receive their input directly.
;;;; Compositor-drawn nodes and bindings turn input into director events; a
;;;; node or binding that receives a press captures the pointer until every
;;;; button is released, as in DOM pointer capture.

(in-package #:ataxia.stage-world)

;;; Layout.

(defun %output-width (stage-output)
  (nth-value 0 (ataxia.world:output-logical-size (stage-output-output stage-output))))

(defun %seat-output (world seat-state)
  (let ((x (stage-seat-x seat-state)))
    (or (find-if (lambda (stage-output)
                   (< x (+ (stage-output-offset stage-output) (%output-width stage-output))))
                 (%outputs world))
        (car (last (%outputs world))))))

(defun %clamp-seat (world seat-state)
  (let ((outputs (%outputs world)))
    (when outputs
      (let* ((last-output (car (last outputs)))
             (right (+ (stage-output-offset last-output) (%output-width last-output))))
        (setf (stage-seat-x seat-state)
              (max 0d0 (min (- right 1d-6) (stage-seat-x seat-state))))
        (multiple-value-bind (width height)
            (ataxia.world:output-logical-size
             (stage-output-output (%seat-output world seat-state)))
          (declare (ignore width))
          (setf (stage-seat-y seat-state)
                (max 0d0 (min (- height 1d-6) (stage-seat-y seat-state)))))))))

(defun %move-seat (world seat-state input)
  (if (ataxia.kernel:cursor-motion-input-absolute-p input)
      (let* ((outputs (%outputs world))
             (last-output (car (last outputs))))
        (when last-output
          (setf (stage-seat-x seat-state)
                (* (ataxia.kernel:cursor-motion-input-x input)
                   (+ (stage-output-offset last-output) (%output-width last-output))))
          (setf (stage-seat-y seat-state)
                (* (ataxia.kernel:cursor-motion-input-y input)
                   (nth-value 1 (ataxia.world:output-logical-size
                                 (stage-output-output (%seat-output world seat-state))))))))
      (setf (stage-seat-x seat-state)
            (+ (stage-seat-x seat-state) (ataxia.kernel:cursor-motion-input-delta-x input))
            (stage-seat-y seat-state)
            (+ (stage-seat-y seat-state) (ataxia.kernel:cursor-motion-input-delta-y input))))
  (%clamp-seat world seat-state))

(defun %seat-screen-point (world seat-state)
  "Output under the pointer and the pointer's output-logical coordinates."
  (let ((stage-output (%seat-output world seat-state)))
    (when stage-output
      (values stage-output
              (- (stage-seat-x seat-state) (stage-output-offset stage-output))
              (stage-seat-y seat-state)))))

;;; Picking.

(defun %hit-local (hit x y)
  (affine-apply (hit-inverse hit) x y))

(defun %hit-content (hit x y)
  (multiple-value-bind (local-x local-y) (%hit-local hit x y)
    (affine-apply (hit-content hit) local-x local-y)))

(defun %hit-accepts-p (world hit x y)
  (let ((clip (hit-clip hit)))
    (when (and clip (not (and (<= (ataxia.world:rectangle-x clip) x (ataxia.world:rectangle-right clip))
                              (<= (ataxia.world:rectangle-y clip) y (ataxia.world:rectangle-bottom clip)))))
      (return-from %hit-accepts-p nil)))
  (multiple-value-bind (local-x local-y) (%hit-local hit x y)
    (if (hit-client hit)
        (multiple-value-bind (content-x content-y) (affine-apply (hit-content hit) local-x local-y)
          (let ((bounds (hit-content-bounds hit)))
            (and bounds
                 (<= (ataxia.world:rectangle-x bounds) content-x (ataxia.world:rectangle-right bounds))
                 (<= (ataxia.world:rectangle-y bounds) content-y (ataxia.world:rectangle-bottom bounds))
                 (%client-live-p (hit-client hit))
                 (ataxia.kernel:interactable-hit-test (hit-client hit) world content-x content-y))))
        ;; A background is an infinite plane; rects accept their own box.
        (or (null (hit-width hit))
            (and (<= 0d0 local-x (hit-width hit)) (<= 0d0 local-y (hit-height hit)))))))

(defun %client-live-p (client)
  (or (not (typep client 'ataxia.kernel:wayland-application))
      (%live-application-p client)))

(defun %pick (world seat-state &optional (wants (constantly t)))
  "Topmost hit under the pointer that is a client or satisfies WANTS."
  (multiple-value-bind (stage-output x y) (%seat-screen-point world seat-state)
    (when stage-output
      (find-if (lambda (hit)
                 (and (or (hit-client hit) (funcall wants (hit-node hit)))
                      (%hit-accepts-p world hit x y)))
               (output-hits world stage-output)))))

;;; Director events.

(defun %modifier-names (seat-state)
  (map 'vector (lambda (modifier) (car (rassoc modifier +modifier-names+)))
       (remove-if-not (lambda (modifier) (rassoc modifier +modifier-names+))
                      (stage-seat-modifiers seat-state))))

(defun %pointer-payload (world seat-state &optional hit)
  "Event fields describing the pointer, in screen, world and HIT's spaces."
  (multiple-value-bind (stage-output x y) (%seat-screen-point world seat-state)
    (when stage-output
      (multiple-value-bind (world-x world-y) (screen-to-world stage-output x y)
        (append
         (list :output (%output-name stage-output) :screen-x x :screen-y y
               :world-x world-x :world-y world-y
               :modifiers (%modifier-names seat-state))
         (when hit
           (multiple-value-bind (local-x local-y) (%hit-local hit x y)
             (multiple-value-bind (parent-x parent-y) (affine-apply (hit-parent-inverse hit) x y)
               (list :x parent-x :y parent-y :local-x local-x :local-y local-y)))))))))

(defun %emit-event (world node name &rest fields)
  (when (node-handles-p node name)
    (%send world (list* :type "event" :node (stage-node-id node)
                        :name (string-downcase (symbol-name name)) fields))))

(defun %capture-hit (world seat-state)
  "Recompute the capturing node's hit, which may have moved since the press."
  (let ((node (stage-seat-capture seat-state)))
    (multiple-value-bind (stage-output) (%seat-screen-point world seat-state)
      (and stage-output (find node (output-hits world stage-output) :key #'hit-node)))))

(defun %send-capture-event (world seat-state name &rest fields)
  (let ((node (stage-seat-capture seat-state)))
    (when node
      (apply #'%emit-event world node name
             (append fields (%pointer-payload world seat-state (%capture-hit world seat-state)))))))

(defun %window-under (world seat-state)
  (let ((hit (%pick world seat-state (constantly nil))))
    (and hit (hit-window hit) (stage-window-id (hit-window hit)))))

;;; Client pointer focus.

(defun %deliver-to-client (world seat-state hit function input &key clamp-p)
  (multiple-value-bind (stage-output x y) (%seat-screen-point world seat-state)
    (declare (ignore stage-output))
    (multiple-value-bind (content-x content-y) (%hit-content hit x y)
      (let ((client (hit-client hit)))
        (when clamp-p
          (multiple-value-bind (left top width height) (ataxia.kernel:drawable-local-bounds client)
            (setf content-x (max left (min (+ left width -1d-6) content-x))
                  content-y (max top (min (+ top height -1d-6) content-y)))))
        (funcall function client world (stage-seat-seat seat-state) content-x content-y input)))))

(defun %set-hovered (world seat-state hit)
  "Move pointer focus to HIT's client, or clear it."
  (let ((old (stage-seat-hovered seat-state)))
    (when (and old (not (and hit (eq (hit-client old) (hit-client hit)))))
      (cond ((%client-live-p (hit-client old))
             (ataxia.kernel:interactable-pointer-leave (hit-client old) world (stage-seat-seat seat-state)))
            ((hit-window old)
             (ataxia.kernel:clear-wayland-focus (stage-seat-seat seat-state) :pointer t))))
    (setf (stage-seat-hovered seat-state) hit)))

(defun %set-entered (world seat-state node)
  "Send pointerleave/pointerenter as the topmost node under the pointer changes."
  (let ((old (stage-seat-entered seat-state)))
    (unless (eq old node)
      (when (and old (eq (stage-node-state old) :live))
        (apply #'%emit-event world old :pointerleave (%pointer-payload world seat-state)))
      (setf (stage-seat-entered seat-state) node)
      (when node
        (apply #'%emit-event world node :pointerenter (%pointer-payload world seat-state))))))

(defun %client-grab (seat-state)
  "Client hit holding an implicit grab because one of its buttons is pressed."
  (loop for target being the hash-values of (stage-seat-buttons seat-state)
        when (hit-p target) return target))

(defun %pointer-moved (world seat-state input)
  (let ((seat (stage-seat-seat seat-state)))
    (cond
      ((stage-seat-manipulation seat-state) (update-manipulation world seat-state))
      ((stage-seat-capture seat-state)
       (%send-capture-event world seat-state
                            (if (member (stage-node-kind (stage-seat-capture seat-state))
                                        '(:pointer-binding))
                                :move :pointermove)))
      ((and (%client-grab seat-state) (not (ataxia.kernel:seat-pointer-drag-active-p seat)))
       (%deliver-to-client world seat-state (%client-grab seat-state)
                           #'ataxia.kernel:interactable-pointer-motion input))
      (t
       (let ((hit (%pick world seat-state #'%input-target-p)))
         (%set-entered world seat-state (and hit (hit-node hit)))
         (cond
           ((and hit (hit-client hit))
            (%set-hovered world seat-state hit)
            (%deliver-to-client world seat-state hit #'ataxia.kernel:interactable-pointer-motion
                                input))
           (t
            (%set-hovered world seat-state nil)
            (when hit
              (apply #'%emit-event world (hit-node hit) :pointermove
                     (%pointer-payload world seat-state hit))))))))))

(defun %revalidate-pointer (world seat-state)
  (unless (or (stage-seat-capture seat-state) (stage-seat-manipulation seat-state)
              (%client-grab seat-state))
    (%pointer-moved world seat-state (ataxia.kernel:make-cursor-motion-input :time-msec 0))))

(defun %forget-pointer-client (world client)
  (dolist (seat-state (%seat-states world))
    (let ((buttons (stage-seat-buttons seat-state)))
      (loop for code in (loop for code being the hash-keys of buttons using (hash-value target)
                              when (and (hit-p target) (eq client (hit-client target)))
                                collect code)
            do (remhash code buttons)))
    (let ((hovered (stage-seat-hovered seat-state)))
      (when (and hovered (eq client (hit-client hovered)))
        (setf (stage-seat-hovered seat-state) nil)))))

(defun %release-director-input (world)
  "Drop captures and gestures owned by a director that went away."
  (dolist (seat-state (%seat-states world))
    (when (stage-seat-capture seat-state)
      (setf (stage-seat-capture seat-state) nil)
      (let ((buttons (stage-seat-buttons seat-state)))
        (loop for code in (loop for code being the hash-keys of buttons using (hash-value target)
                                when (eq target :capture) collect code)
              do (remhash code buttons))))
    (setf (stage-seat-gesture seat-state) nil
          (stage-seat-entered seat-state) nil)))

;;; Bindings.

(defun %modifiers-match-p (node seat-state)
  (let ((held (stage-seat-modifiers seat-state)))
    (and (subsetp (node-prop node :modifiers) held)
         (subsetp (intersection held '(:shift :control :alt :logo)) (node-prop node :modifiers)))))

(defun %find-binding (world kind seat-state predicate)
  (and (stage-director-connected-p world)
       (find-if (lambda (node)
                  (and (eq kind (stage-node-kind node))
                       (%modifiers-match-p node seat-state)
                       (funcall predicate node)))
                (%bindings world))))

(defun %install-shortcuts (world nodes)
  "Replace the shortcut table when the declared shortcuts changed."
  (let ((declared (mapcar (lambda (node)
                            (list node (node-prop node :key) (node-prop node :modifiers)
                                  (node-prop node :repeat)))
                          nodes)))
    (unless (equal declared (%shortcuts-declared world))
      (setf (%shortcuts-declared world) declared)
      (%replace-shortcuts world nodes))))

(defun %replace-shortcuts (world nodes)
  (ataxia.world:replace-shortcuts
   (ataxia.world:world-shortcut-controller world)
   (loop for node in nodes
         for priority from 0
         when (node-prop node :key)
           collect (let ((node node))
                     (ataxia.world:make-shortcut-binding
                      :id (stage-node-id node)
                      :key (list :keysym (node-prop node :key))
                      :modifiers (node-prop node :modifiers)
                      ;; Later declarations win, so duplicates never tie.
                      :priority priority
                      :repeat-p (node-prop node :repeat)
                      :predicate (lambda (world seat input)
                                   (declare (ignore seat input))
                                   (stage-director-connected-p world))
                      :press-handler (lambda (world seat input)
                                       (declare (ignore seat input))
                                       (%emit-event world node :press))
                      :release-handler (lambda (world seat input)
                                         (declare (ignore seat input))
                                         (%emit-event world node :release)))))))

;;; Kernel input methods.

(defmethod ataxia.kernel:world-cursor-motion ((world stage-world) seat input)
  (let ((seat-state (gethash seat (%seats world))))
    (when seat-state
      (%move-seat world seat-state input)
      (%pointer-moved world seat-state input)
      (%damage-cursor world seat-state)))
  input)

(defun %begin-action (world seat-state action hit)
  "Start ACTION natively for HIT under the pointer; return the manipulation or NIL."
  (case action
    (:pan (begin-pan world seat-state))
    (:move (let ((target (and hit (move-target (hit-node hit)))))
             (and target (begin-move world seat-state target))))
    (:resize
     (let ((node (and hit (hit-window hit) (hit-node hit))))
       (when (and node (node-prop node :resizable))
         (multiple-value-bind (stage-output x y) (%seat-screen-point world seat-state)
           (declare (ignore stage-output))
           (multiple-value-bind (local-x local-y) (%hit-local hit x y)
             (begin-resize world seat-state node (hit-window hit)
                           (resize-edges local-x local-y (hit-width hit) (hit-height hit))))))))))

(defun %start-pointer-target (seat-state code source manipulation)
  "Route button CODE's release to MANIPULATION, or to SOURCE's captured events."
  (let ((buttons (stage-seat-buttons seat-state)))
    (if manipulation
        (setf (manipulation-source manipulation) source
              (gethash code buttons) :manipulation)
        (setf (stage-seat-capture seat-state) source
              (gethash code buttons) :capture))))

(defun %press-binding (world seat-state binding code)
  (let* ((hit (%pick world seat-state #'%input-target-p))
         (window (and hit (hit-window hit))))
    (%set-hovered world seat-state nil)
    (%start-pointer-target seat-state code binding
                           (%begin-action world seat-state (node-prop binding :action) hit))
    (apply #'%emit-event world binding :down :button code
           :window (and window (stage-window-id window))
           (%pointer-payload world seat-state))))

(defun %press-scene (world seat-state code input)
  (let ((hit (%pick world seat-state #'%input-target-p)))
    (cond
      ((null hit))
      ((hit-client hit)
       (cond ((hit-window hit)
              (when (%focusable-p (hit-window hit))
                (%focus-window world seat-state (hit-window hit))))
             ((hit-overlay hit) (focus-panel world seat-state (hit-overlay hit)))
             ((node-prop (hit-node hit) :focusable)
              (focus-panel world seat-state (stage-node-cache (hit-node hit)))))
       (setf (gethash code (stage-seat-buttons seat-state)) hit)
       (%set-hovered world seat-state hit)
       (%deliver-to-client world seat-state hit #'ataxia.kernel:interactable-pointer-button input))
      (t
       (let* ((node (hit-node hit))
              (manipulation (if (eq (stage-node-kind node) :background)
                                (and (node-prop node :pan) (begin-pan world seat-state))
                                (let ((target (move-target node)))
                                  (and target (begin-move world seat-state target))))))
         (%set-hovered world seat-state nil)
         (%start-pointer-target seat-state code node manipulation)
         (apply #'%emit-event world node :pointerdown :button code
                (%pointer-payload world seat-state hit)))))))

(defun %press (world seat-state code input)
  (let ((buttons (stage-seat-buttons seat-state)))
    (cond
      ((stage-seat-manipulation seat-state)
       (setf (gethash code buttons) :manipulation))
      ((stage-seat-capture seat-state)
       (setf (gethash code buttons) :capture)
       (%send-capture-event world seat-state
                            (if (eq (stage-node-kind (stage-seat-capture seat-state)) :pointer-binding)
                                :down :pointerdown)
                            :button code))
      ((plusp (hash-table-count buttons))
       ;; Further buttons follow the window that already holds the grab.
       (let ((grab (%client-grab seat-state)))
         (when grab
           (setf (gethash code buttons) grab)
           (%deliver-to-client world seat-state grab #'ataxia.kernel:interactable-pointer-button
                               input))))
      (t
       (let ((binding (%find-binding world :pointer-binding seat-state
                                     (lambda (node) (eql code (node-prop node :button))))))
         (if binding
             (%press-binding world seat-state binding code)
             (%press-scene world seat-state code input)))))))

(defun %release (world seat-state code input)
  (let* ((buttons (stage-seat-buttons seat-state))
         (target (gethash code buttons)))
    (remhash code buttons)
    (cond
      ((eq target :manipulation)
       (when (and (zerop (hash-table-count buttons)) (stage-seat-manipulation seat-state))
         (let ((source (manipulation-source (stage-seat-manipulation seat-state))))
           (end-manipulation world seat-state)
           (when source
             (apply #'%emit-event world source
                    (if (eq (stage-node-kind source) :pointer-binding) :up :pointerup)
                    :button code (%pointer-payload world seat-state))))))
      ((eq target :capture)
       (let ((node (stage-seat-capture seat-state)))
         (%send-capture-event world seat-state
                              (if (eq (stage-node-kind node) :pointer-binding) :up :pointerup)
                              :button code)
         (when (zerop (hash-table-count buttons))
           (setf (stage-seat-capture seat-state) nil))))
      ((hit-p target)
       (when (%client-live-p (hit-client target))
         (%deliver-to-client world seat-state target #'ataxia.kernel:interactable-pointer-button
                             input :clamp-p t))))
    (when (zerop (hash-table-count buttons))
      (%revalidate-pointer world seat-state))))

(defmethod ataxia.kernel:world-cursor-button ((world stage-world) seat input)
  (let ((seat-state (gethash seat (%seats world)))
        (code (ataxia.kernel:cursor-button-input-code input)))
    (when seat-state
      (cond
        ((ataxia.kernel:seat-pointer-drag-active-p seat)
         (ataxia.kernel:forward-pointer-drag-button seat input)
         (remhash code (stage-seat-buttons seat-state)))
        ((eq (ataxia.kernel:cursor-button-input-state input) :pressed)
         (%press world seat-state code input))
        (t (%release world seat-state code input)))))
  input)

(defun %axis-fields (input)
  (list :orientation (string-downcase (symbol-name (ataxia.kernel:cursor-axis-input-orientation input)))
        :delta (ataxia.kernel:cursor-axis-input-delta input)
        :discrete (ataxia.kernel:cursor-axis-input-discrete-delta input)
        :source (string-downcase (symbol-name (ataxia.kernel:cursor-axis-input-source input)))))

(defun %axis-action (world seat-state action input)
  (let ((orientation (ataxia.kernel:cursor-axis-input-orientation input))
        (delta (ataxia.kernel:cursor-axis-input-delta input)))
    (unless (zerop delta)
      (if (and (eq action :zoom) (eq orientation :vertical))
          (wheel-zoom world seat-state delta (ataxia.kernel:cursor-axis-input-source input))
          (wheel-pan world seat-state orientation delta)))))

(defun %wheel-target-p (node)
  (or (node-handles-p node :wheel)
      (and (eq (stage-node-kind node) :background) (node-prop node :pan))))

(defmethod ataxia.kernel:world-cursor-axis ((world stage-world) seat input)
  (let ((seat-state (gethash seat (%seats world))))
    (when seat-state
      (let ((binding (%find-binding world :wheel-binding seat-state (constantly t))))
        (if binding
            (progn
              (when (member (node-prop binding :action) '(:zoom :pan))
                (%axis-action world seat-state (node-prop binding :action) input))
              (apply #'%emit-event world binding :wheel
                     (append (%axis-fields input)
                             (list :window (%window-under world seat-state))
                             (%pointer-payload world seat-state))))
            (let ((hit (or (%client-grab seat-state) (%pick world seat-state #'%wheel-target-p))))
              (cond
                ((null hit))
                ((hit-client hit)
                 (%deliver-to-client world seat-state hit #'ataxia.kernel:interactable-pointer-axis
                                     input))
                (t
                 (when (and (eq (stage-node-kind (hit-node hit)) :background)
                            (node-prop (hit-node hit) :pan))
                   (%axis-action world seat-state :pan input))
                 (apply #'%emit-event world (hit-node hit) :wheel
                        (append (%axis-fields input)
                                (%pointer-payload world seat-state hit))))))))))
  input)

(defmethod ataxia.kernel:world-cursor-gesture ((world stage-world) seat input)
  (let ((seat-state (gethash seat (%seats world))))
    (when seat-state
      (let* ((dx (ataxia.kernel:cursor-gesture-input-dx input))
             (dy (ataxia.kernel:cursor-gesture-input-dy input))
             (scale (ataxia.kernel:cursor-gesture-input-scale input))
             (cancelled-p (ataxia.kernel:cursor-gesture-input-cancelled-p input))
             (fields (list :fingers (ataxia.kernel:cursor-gesture-input-fingers input)
                           :dx dx :dy dy :scale scale
                           :rotation (ataxia.kernel:cursor-gesture-input-rotation input)
                           :cancelled (if cancelled-p t :false))))
        (case (ataxia.kernel:cursor-gesture-input-phase input)
          (:begin
           (let ((binding (%find-binding
                           world :gesture-binding seat-state
                           (lambda (node)
                             (and (eq (node-prop node :gesture)
                                      (ataxia.kernel:cursor-gesture-input-kind input))
                                  (eql (node-prop node :fingers)
                                       (ataxia.kernel:cursor-gesture-input-fingers input)))))))
             (setf (stage-seat-gesture seat-state) binding)
             (when binding
               (when (member (node-prop binding :action) '(:pan :zoom))
                 (begin-gesture-manipulation world seat-state (node-prop binding :action)))
               (apply #'%emit-event world binding :begin
                      (append fields (%pointer-payload world seat-state))))))
          (:update
           (when (stage-seat-gesture-manipulation seat-state)
             (update-gesture-manipulation world seat-state dx dy scale))
           (when (stage-seat-gesture seat-state)
             (apply #'%emit-event world (stage-seat-gesture seat-state) :update fields)))
          (:end
           (when (stage-seat-gesture-manipulation seat-state)
             (end-gesture-manipulation world seat-state cancelled-p))
           (when (stage-seat-gesture seat-state)
             (apply #'%emit-event world (shiftf (stage-seat-gesture seat-state) nil) :end
                    fields)))))))
  input)

(defmethod ataxia.kernel:world-key-event ((world stage-world) seat input)
  (let ((seat-state (gethash seat (%seats world))))
    (when seat-state
      (setf (stage-seat-modifiers seat-state)
            (etypecase input
              (ataxia.kernel:key-input (ataxia.kernel:key-input-modifiers input))
              (ataxia.kernel:modifiers-input (ataxia.kernel:modifiers-input-names input))))
      (let* ((panel (stage-seat-focused-panel seat-state))
             (focused (stage-seat-focused seat-state))
             (client (cond (panel (%panel-client panel))
                           (focused (stage-window-application focused)))))
        (when (and (eq :forward (ataxia.world:handle-shortcut-input
                                 (ataxia.world:world-shortcut-controller world) world seat input))
                   client
                   (%client-live-p client))
          (ataxia.kernel:interactable-key-event client world seat input)))))
  input)

;;; Client requests.

(defun %primary-node (window)
  (first (stage-window-nodes window)))

(defmethod ataxia.kernel:world-client-request
    ((world stage-world) (application ataxia.kernel:wayland-application) request)
  (let* ((window (gethash application (%windows world)))
         (node (and window (%primary-node window))))
    (when window
      (typecase request
        ((or ataxia.kernel:move-client-request ataxia.kernel:resize-client-request)
         (let* ((seat-state (gethash (ataxia.kernel:client-request-seat request) (%seats world)))
                (moving-p (typep request 'ataxia.kernel:move-client-request))
                (event (if moving-p :moverequest :resizerequest))
                (buttons (and seat-state (stage-seat-buttons seat-state))))
           (when (and node seat-state (not (stage-seat-manipulation seat-state)))
             (flet ((take-buttons (kind)
                      (loop for code being the hash-keys of buttons
                            do (setf (gethash code buttons) kind))
                      (%set-hovered world seat-state nil)))
               (cond
                 ;; Client-side title bars and edges move and resize natively.
                 ((and moving-p (node-prop node :movable))
                  (take-buttons :manipulation)
                  (begin-move world seat-state node))
                 ((and (not moving-p) (node-prop node :resizable))
                  (take-buttons :manipulation)
                  (begin-resize world seat-state node window
                                (ataxia.kernel:resize-client-request-edges request)))
                 ;; Otherwise the request continues as a pointer capture on the
                 ;; window node, so the director reuses its ordinary drag handling.
                 ((and (node-handles-p node event) (stage-director-connected-p world))
                  (take-buttons :capture)
                  (setf (stage-seat-capture seat-state) node)
                  (apply #'%emit-event world node event
                         (append (unless moving-p
                                   (list :edges (ataxia.kernel:resize-client-request-edges request)))
                                 (%pointer-payload world seat-state
                                                   (%capture-hit world seat-state))))))))))
        (ataxia.kernel:state-client-request
         (let ((name (ataxia.kernel:state-client-request-name request))
               (value (if (ataxia.kernel:state-client-request-value request) t :false)))
           (case name
             (:activation
              (let ((seat-state (or (gethash (ataxia.kernel:client-request-seat request) (%seats world))
                                    (%default-seat-state world))))
                (when (and seat-state (%focusable-p window))
                  (%focus-window world seat-state window))))
             ((:fullscreen :maximized :minimized)
              (let ((event (ecase name
                             (:fullscreen :fullscreenrequest)
                             (:maximized :maximizerequest)
                             (:minimized :minimizerequest))))
                (if (and node (node-handles-p node event) (stage-director-connected-p world))
                    (%emit-event world node event :value value)
                    ;; Unhandled requests are answered with the current state,
                    ;; so clients waiting for a configure are not left hanging.
                    (unless (eq name :minimized)
                      (setf (getf (stage-window-states window) name) :unset)
                      (%request-window-state world window name
                                             (and node (node-prop node name)))))))))))))
  request)
