;;;; Per-output display lists, damage and frame production.
;;;;
;;;; Each frame flattens the scene into immutable draw items in buffer space.
;;;; Comparing their signatures with the previous frame yields exactly the
;;;; damage caused by scene edits, animation and cursor motion; client content
;;;; damage is projected through the same transforms. The walk also records
;;;; pick targets, so input resolves against what was last presented.

(in-package #:ataxia.stage-world)

(defstruct (item (:constructor %make-item (key bounds signature draw)))
  (key nil :read-only t)
  ;; Conservative buffer-space rectangle covering every pixel the item touches.
  (bounds nil :read-only t)
  ;; EQUALP-comparable description of everything affecting those pixels,
  ;; except client buffer content, which arrives as explicit damage.
  (signature nil :read-only t)
  ;; (LAMBDA (RENDERER)) drawing the item; tokens are collected separately.
  (draw nil :read-only t)
  (token nil)
  (callback-p nil)
  ;; Buffer rectangle drawing is limited to, from clipping ancestors.
  (clip nil)
  ;; For backdrop blur: the buffer area whose pixels the blur reads.
  (blur-area nil)
  ;; Buffer rectangles a change damages when tighter than BOUNDS, e.g. a border's ring.
  (damage nil)
  ;; The effect item that draws this one into its content, or NIL for the frame itself.
  (owner nil)
  ;; For an effect: what it runs, and the items it owns in paint order.
  (effect nil)
  (children nil))

(defstruct (hit (:constructor %make-hit))
  node window
  ;; Interactable receiving pointer input: a window's application, a web page's
  ;; component or a shell overlay's component; OVERLAY is set for the last.
  (client nil)
  (overlay nil)
  ;; Output-logical point -> node-local point, and parent space for events.
  (inverse nil :read-only t)
  (parent-inverse nil :read-only t)
  (width 0d0) (height 0d0)
  ;; For clients: node-local -> client content coordinates, and content bounds.
  (content nil)
  (content-bounds nil)
  ;; Output-logical rectangle outside which clipping ancestors hide the node.
  (clip nil))

(defstruct (display-context (:constructor %make-display-context))
  world stage-output output-name
  ;; Output-logical -> buffer transform, and the buffer's own rectangle.
  screen bounds
  (items nil) (hits nil)
  ;; Windows and pages shown, while building the scene's display.
  (presented nil)
  (tag nil)
  ;; Clip rectangles of the node being emitted, in buffer and logical space.
  (clip nil) (logical-clip nil)
  ;; True while emitting a moving node or a descendant of one.
  (moving-p nil)
  ;; True once anything moving was emitted: this output must keep animating.
  (animating-p nil)
  ;; The effect item whose subtree is being emitted.
  (owner nil)
  ;; True while emitting descendants of a node with pointer handlers, which
  ;; take the pointer for it as children of a DOM element do.
  (pointer-parent-p nil)
  ;; While building the scene's display: text raster scales seen, and whether
  ;; any text used an approximate scale that a following frame must refine.
  (raster-scales nil)
  (refine-p nil))

(defun %premultiplied (red green blue alpha opacity)
  "A premultiplied COLOR, unboxed: items compare and upload it without allocating more."
  (let ((alpha (* (float alpha 1d0) (float opacity 1d0)))
        (color (make-array 4 :element-type 'double-float)))
    (setf (aref color 0) (* (float red 1d0) alpha)
          (aref color 1) (* (float green 1d0) alpha)
          (aref color 2) (* (float blue 1d0) alpha)
          (aref color 3) alpha)
    color))

(defun %node-color (node key opacity)
  (multiple-value-call #'%premultiplied (node-color node key) opacity))

(defun %node-paint (node key end-key angle-key opacity)
  (make-paint (%node-color node key opacity) (%node-color node end-key opacity)
              (node-number node angle-key 0d0)))

(defparameter +clear-paint+
  (make-paint (make-array 4 :element-type 'double-float :initial-element 0d0)
              (make-array 4 :element-type 'double-float :initial-element 0d0) 0d0))

(defun %paint-visible-p (paint)
  (or (plusp (aref (paint-start paint) 3)) (plusp (aref (paint-end paint) 3))))

(defun %emit (context key bounds signature draw &key token callback-p)
  (let* ((clip (display-context-clip context))
         (visible (ataxia.world:rectangle-intersection
                   bounds (if clip
                              (or (ataxia.world:rectangle-intersection clip (display-context-bounds context))
                                  (return-from %emit nil))
                              (display-context-bounds context)))))
    ;; Offscreen or clipped-away items cost nothing: no drawing, damage or callbacks.
    (when visible
      (let ((item (%make-item (list* (display-context-tag context) key) visible
                              (if clip (list* clip signature) signature) draw)))
        (setf (item-token item) token
              (item-callback-p item) callback-p
              (item-clip item) clip
              (item-owner item) (display-context-owner context))
        (when (display-context-moving-p context)
          (setf (display-context-animating-p context) t))
        (push item (display-context-items context))
        item))))

(defun %node-local-affine (world node)
  (multiple-value-bind (width height) (%node-size world node)
    (node-affine (node-number node :x 0d0) (node-number node :y 0d0)
                 (node-number node :scale 1d0) (node-number node :rotation 0d0)
                 (* width (node-prop node :origin-x)) (* height (node-prop node :origin-y)))))

(defun %inflate (rectangle amount)
  (ataxia.world:make-rectangle (- (ataxia.world:rectangle-x rectangle) amount)
                               (- (ataxia.world:rectangle-y rectangle) amount)
                               (+ (ataxia.world:rectangle-width rectangle) (* 2 amount))
                               (+ (ataxia.world:rectangle-height rectangle) (* 2 amount))))

(defun %emit-shadow (context node transform width height radius opacity)
  (multiple-value-bind (red green blue alpha) (node-color node :shadow-color)
    (when (plusp (* alpha opacity))
      (let* ((spread (node-number node :shadow-spread 0d0))
             (blur (max 0d0 (node-number node :shadow-blur 0d0)))
             (x (- (node-number node :shadow-x 0d0) spread))
             (y (- (node-number node :shadow-y 0d0) spread))
             (box-width (+ width (* 2 spread)))
             (box-height (+ height (* 2 spread)))
             (corner (max 0d0 (+ radius spread)))
             (color (%premultiplied red green blue alpha opacity))
             (extent (shadow-extent blur)))
        (when (and (plusp box-width) (plusp box-height))
          (%emit context (list (stage-node-id node) :shadow)
                 (affine-rectangle-bounds transform (- x extent) (- y extent)
                                                    (+ box-width (* 2 extent))
                                                    (+ box-height (* 2 extent)) 1)
                 (list transform x y box-width box-height corner blur color)
                 (lambda (renderer)
                   (draw-stage-shadow renderer transform x y box-width box-height
                                      corner blur color))))))))

(defun %emit-backdrop-blur (context node transform width height radius opacity)
  "Blur what is already drawn behind NODE's rounded box."
  (let ((blur (* (max 0d0 (node-number node :blur 0d0)) (affine-scale-factor transform))))
    (when (and (>= blur 1d0) (plusp width) (plusp height))
      (let* ((bounds (affine-rectangle-bounds transform 0 0 width height 1))
             (margin (nth-value 2 (blur-parameters blur)))
             (screen (display-context-bounds context))
             (sampled (ataxia.world:rectangle-intersection (%inflate bounds margin) screen)))
        (when sampled
          (multiple-value-bind (x y area-width area-height)
              (ataxia.world:rectangle-pixel-bounds sampled (ataxia.world:rectangle-width screen)
                                                   (ataxia.world:rectangle-height screen))
            (let* ((area (list x y area-width area-height))
                   (item (%emit context (list (stage-node-id node) :blur) bounds
                                (list transform width height radius blur opacity area)
                                (lambda (renderer)
                                  (draw-stage-blur renderer transform width height radius blur
                                                   opacity area)))))
              (when item
                (setf (item-blur-area item) (ataxia.world:make-rectangle x y area-width area-height))))))))))

(defun %ring-damage (transform width height thickness)
  "Buffer strips covering a THICKNESS-wide ring inside an axis-aligned box, or NIL."
  (when (and (zerop (affine-b transform)) (zerop (affine-c transform))
             (< (* 4 thickness) (min width height)))
    (mapcar (lambda (strip)
              (destructuring-bind (x y width height) strip
                (affine-rectangle-bounds transform x y width height 2)))
            (list (list 0 0 width thickness)
                  (list 0 (- height thickness) width thickness)
                  (list 0 thickness thickness (- height (* 2 thickness)))
                  (list (- width thickness) thickness thickness (- height (* 2 thickness)))))))

(defun %emit-box (context node part transform x y width height radius border fill stroke)
  (when (and (plusp width) (plusp height)
             (or (%paint-visible-p fill) (and (plusp border) (%paint-visible-p stroke))))
    (let* ((local (affine-multiply transform (affine-translation x y)))
           (item (%emit context (list (stage-node-id node) part)
                        (affine-rectangle-bounds local 0 0 width height 2)
                        (list local width height radius border fill stroke)
                        (lambda (renderer)
                          (draw-stage-rect renderer local width height radius border fill stroke)))))
      ;; A border alone repaints only its ring, so an animated border leaves
      ;; the window inside it untouched.
      (when (and item (not (%paint-visible-p fill)))
        (setf (item-damage item) (%ring-damage local width height (max border radius)))))))

(defgeneric emit-content (kind context node transform opacity screen-inverse parent-inverse)
  (:documentation "Emit the draw items and pick targets of one node of KIND. TRANSFORM maps
node-local space to buffer pixels; SCREEN-INVERSE maps output-logical points to node-local
space and PARENT-INVERSE to its parent's space.")
  (:method (kind context node transform opacity screen-inverse parent-inverse)
    (declare (ignore kind context node transform opacity screen-inverse parent-inverse))
    nil))

(defmethod emit-content ((kind (eql :rect)) context node transform opacity screen-inverse parent-inverse)
  (multiple-value-bind (width height) (%node-size (display-context-world context) node)
    (let ((radius (max 0d0 (node-number node :radius 0d0)))
          (border (max 0d0 (node-number node :border-width 0d0))))
      (%emit-shadow context node transform width height radius opacity)
      (%emit-backdrop-blur context node transform width height radius opacity)
      (%emit-box context node :fill transform 0 0 width height radius border
                 (%node-paint node :color :color-end :fill-angle opacity)
                 (%node-paint node :border-color :border-color-end :border-angle opacity))
      (when (%hit-target-p context node)
        (%add-hit context node screen-inverse parent-inverse width height)))))

(defmethod emit-content ((kind (eql :group)) context node transform opacity screen-inverse
                         parent-inverse)
  (declare (ignore transform opacity))
  ;; A sized group taking the pointer catches it over its whole box, as a div does.
  (when (and (node-declared-p node :width) (node-declared-p node :height) (%hit-target-p context node))
    (multiple-value-bind (width height) (%node-size (display-context-world context) node)
      (%add-hit context node screen-inverse parent-inverse width height))))

(defmethod emit-content ((kind (eql :background)) context node transform opacity screen-inverse
                         parent-inverse)
  (let ((color (%node-color node :color opacity))
        (grid (node-prop node :grid))
        (grid-color (%node-color node :grid-color opacity))
        (spacing (node-number node :grid-spacing 32d0))
        (size (node-number node :grid-size 1d0)))
    (when (or (plusp (aref color 3)) (and (not (eq grid :none)) (plusp (aref grid-color 3))))
      ;; An infinite plane covers the whole output.
      (%emit context (list (stage-node-id node) :background) (display-context-bounds context)
             (list transform color grid grid-color spacing size)
             (lambda (renderer)
               (draw-stage-background renderer transform color grid grid-color spacing size))))
    (when (%hit-target-p context node)
      (%add-hit context node screen-inverse parent-inverse nil nil))))

(defun %add-hit (context node screen-inverse parent-inverse width height &rest options)
  "Record NODE as a pick target; a NIL WIDTH accepts the whole plane."
  (when (and screen-inverse (eq (stage-node-state node) :live))
    (push (apply #'%make-hit :node node :inverse screen-inverse :parent-inverse parent-inverse
                 :width width :height height :clip (display-context-logical-clip context) options)
          (display-context-hits context))))

(defun %window-content-affine (window width height)
  "Map client content coordinates to the node's local WIDTH x HEIGHT box."
  (multiple-value-bind (x y natural-width natural-height)
      (%window-bounds window)
    (let ((scale-x (/ width (max 1d0 natural-width)))
          (scale-y (/ height (max 1d0 natural-height))))
      (make-affine scale-x 0 0 scale-y (- (* scale-x x)) (- (* scale-y y))))))

(defun %surface-bounds (surfaces)
  (let ((bounds nil))
    (loop for surface across surfaces
          for rectangle = (ataxia.world:make-rectangle
                           (ataxia.kernel:drawable-surface-local-x surface)
                           (ataxia.kernel:drawable-surface-local-y surface)
                           (ataxia.kernel:drawable-surface-width surface)
                           (ataxia.kernel:drawable-surface-height surface))
          do (setf bounds (if bounds (ataxia.world:rectangle-union bounds rectangle) rectangle)))
    bounds))

(defun %emit-window-surface (context node transform content surface index
                             width height radius opacity dim &key (feedback-p t))
  "Emit one client surface; CONTENT maps client coordinates to the node's local box.
FEEDBACK-P sends the client presentation feedback and frame callbacks."
  (let ((x (ataxia.kernel:drawable-surface-local-x surface))
        (y (ataxia.kernel:drawable-surface-local-y surface))
        (surface-width (ataxia.kernel:drawable-surface-width surface))
        (surface-height (ataxia.kernel:drawable-surface-height surface)))
    (multiple-value-bind (local-x local-y) (affine-apply content x y)
      (let ((local-width (* surface-width (affine-a content)))
            (local-height (* surface-height (affine-d content))))
        (%emit context (list (stage-node-id node) :surface index)
               (affine-rectangle-bounds transform local-x local-y local-width local-height 1)
               (list transform local-x local-y local-width local-height width height radius opacity
                     dim (ataxia.kernel:drawable-surface-texture-coordinates surface))
               (lambda (renderer)
                 (draw-stage-surface renderer transform surface local-x local-y local-width
                                     local-height width height radius opacity dim))
               :token (and feedback-p (ataxia.kernel:drawable-surface-presentation-token surface))
               :callback-p (and feedback-p
                                (ataxia.kernel:drawable-surface-frame-callback-p surface)))))))

(defun %emit-decorations (context node transform width height opacity)
  "Emit the shadow, outset border and backdrop blur of a box holding client
content; return its corner radius."
  (let ((radius (max 0d0 (node-number node :radius 0d0)))
        (border (max 0d0 (node-number node :border-width 0d0))))
    (%emit-shadow context node transform width height radius opacity)
    (%emit-box context node :border transform (- border) (- border)
               (+ width (* 2 border)) (+ height (* 2 border)) (+ radius border) border
               +clear-paint+ (%node-paint node :border-color :border-color-end :border-angle opacity))
    (%emit-backdrop-blur context node transform width height radius opacity)
    radius))

(defmethod emit-content ((kind (eql :window)) context node transform opacity screen-inverse
                         parent-inverse)
  (let* ((world (display-context-world context))
         (window (%node-window world node))
         (application (and window (stage-window-application window)))
         (live-p (and window (%window-presentable-p window)))
         ;; An exiting node shows the last frame of a window its client closed.
         (surfaces (cond (live-p (ataxia.kernel:drawable-surfaces application))
                         ((and window (not (eq (stage-node-state node) :live)))
                          (stage-window-snapshot window)))))
    (when (plusp (length surfaces))
      (multiple-value-bind (width height) (%node-size world node)
        (when (and (plusp width) (plusp height))
          (let* ((radius (%emit-decorations context node transform width height opacity))
                 (dim (max 0d0 (min 1d0 (node-number node :dim 0d0))))
                 (content (%window-content-affine window width height))
                 (content-transform (affine-multiply transform content))
                 (stage-output (display-context-stage-output context)))
            ;; Offscreen windows neither enter the output nor wake it.
            (when (and (plusp (loop for surface across surfaces
                                    for index from 0
                                    count (%emit-window-surface context node transform content surface
                                                                index width height radius opacity dim
                                                                :feedback-p live-p)))
                       live-p)
              (push content-transform (gethash window (stage-output-window-transforms stage-output)))
              (setf (gethash window (display-context-presented context)) t))
            (when (and live-p (node-prop node :interactive))
              (%add-hit context node screen-inverse parent-inverse width height
                        :window window :client application :content (affine-invert content)
                        :content-bounds (%surface-bounds surfaces)))))))))

(defun %pointer-handlers-p (node)
  (intersection (stage-node-handlers node) +bubbling-events+))

(defun %claims-pointer-p (node)
  "Whether NODE's pointer handlers or cursor apply over it and its descendants."
  (or (%pointer-handlers-p node) (node-prop node :cursor)))

(defun %takes-pointer-p (node)
  (or (%claims-pointer-p node)
      (case (stage-node-kind node)
        (:background (node-prop node :pan))
        ((:rect :text :image) (move-target node)))))

(defun %input-target-p (node)
  "True for compositor-drawn nodes that take pointer input instead of passing it
through: nodes with pointer handlers or a cursor, their descendants, and nodes
that drag or pan natively."
  (or (%takes-pointer-p node)
      (loop for current = (stage-node-parent node) then (stage-node-parent current)
            while current thereis (%claims-pointer-p current))))

(defun %hit-target-p (context node)
  "%INPUT-TARGET-P while CONTEXT builds the display, which knows about the ancestors."
  (or (display-context-pointer-parent-p context) (%takes-pointer-p node)))

(defun %child-clip (context node transform)
  "Buffer and logical clip rectangles for NODE's children, when NODE clips them."
  (if (node-prop node :clip)
      (multiple-value-bind (width height) (%node-size (display-context-world context) node)
        (let* ((box (affine-rectangle-bounds transform 0 0 width height))
               (clip (if (display-context-clip context)
                         (or (ataxia.world:rectangle-intersection box (display-context-clip context))
                             (ataxia.world:make-rectangle 0 0 0 0))
                         box))
               (to-logical (affine-invert (display-context-screen context))))
          (values clip
                  (if to-logical
                      (affine-rectangle-bounds to-logical (ataxia.world:rectangle-x clip)
                                               (ataxia.world:rectangle-y clip)
                                               (ataxia.world:rectangle-width clip)
                                               (ataxia.world:rectangle-height clip))
                      (display-context-logical-clip context)))))
      (values (display-context-clip context) (display-context-logical-clip context))))

(defun %emit-node (context node buffer-base screen-base opacity)
  "Emit NODE and its subtree. BUFFER-BASE maps NODE's parent space to buffer
pixels; SCREEN-BASE maps output-logical points into that parent space."
  (unless (or (eq (stage-node-state node) :dead) (not (node-prop node :visible)))
    (let ((kind (stage-node-kind node))
          (world (display-context-world context)))
      (unless (or (member kind '(:camera :reserve :shortcut :pointer-binding
                                 :wheel-binding :gesture-binding))
                  (and (eq kind :screen)
                       (node-prop node :output)
                       (not (equal (node-prop node :output) (display-context-output-name context)))))
        (let* ((local (%node-local-affine world node))
               ;; A screen node restarts from output pixels, ignoring the camera.
               (transform (affine-multiply (if (eq kind :screen) (display-context-screen context) buffer-base)
                                           local))
               (opacity (* opacity (max 0d0 (min 1d0 (node-number node :opacity 1d0)))))
               (local-inverse (affine-invert local))
               (screen-inverse (and local-inverse
                                    (if (eq kind :screen)
                                        local-inverse
                                        (and screen-base (affine-multiply local-inverse screen-base)))))
               (moving-p (display-context-moving-p context)))
          (when (plusp opacity)
            (setf (display-context-moving-p context) (or moving-p (node-moving-p node)))
            (if (effect-shown-p node)
                (emit-effect context kind node transform opacity screen-inverse screen-base)
                (progn (emit-content kind context node transform opacity screen-inverse screen-base)
                       (%emit-subtree context node transform screen-inverse opacity)))
            (setf (display-context-moving-p context) moving-p)))))))

(defun %emit-subtree (context node transform screen-inverse opacity)
  "Emit NODE's children within the clip NODE gives them."
  (let ((clip (display-context-clip context))
        (logical-clip (display-context-logical-clip context))
        (pointer-parent-p (display-context-pointer-parent-p context)))
    (multiple-value-bind (child-clip child-logical-clip) (%child-clip context node transform)
      (setf (display-context-clip context) child-clip
            (display-context-logical-clip context) child-logical-clip
            (display-context-pointer-parent-p context)
            (or pointer-parent-p (%claims-pointer-p node)))
      (%emit-children context node transform screen-inverse opacity)
      (setf (display-context-clip context) clip
            (display-context-logical-clip context) logical-clip
            (display-context-pointer-parent-p context) pointer-parent-p))))

(defun %emit-children (context node buffer-base screen-base opacity)
  (dolist (child (stage-node-children node))
    (%emit-node context child buffer-base screen-base opacity)))

(defun %buffer-transform (stage-output)
  (multiple-value-bind (width height)
      (ataxia.world:output-logical-size (stage-output-output stage-output))
    (output-buffer-affine width height (stage-output-buffer-width stage-output)
                          (stage-output-buffer-height stage-output)
                          (stage-output-transform stage-output))))

(defun %emit-surfaces-at (context key drawable x y transform)
  "Emit DRAWABLE's surfaces with their origin at logical point (X, Y)."
  (loop for surface across (ataxia.kernel:drawable-surfaces drawable)
        for index from 0
        for local = (affine-multiply
                     transform
                     (affine-translation (+ x (ataxia.kernel:drawable-surface-local-x surface))
                                         (+ y (ataxia.kernel:drawable-surface-local-y surface))))
        for width = (ataxia.kernel:drawable-surface-width surface)
        for height = (ataxia.kernel:drawable-surface-height surface)
        do (let ((local local) (surface surface))
             (%emit context (list key index)
                    (affine-rectangle-bounds local 0 0 width height 1)
                    (list local width height)
                    (lambda (renderer)
                      (draw-stage-surface renderer local surface 0 0 width height 0 0 0d0 1d0))
                    :token (ataxia.kernel:drawable-surface-presentation-token surface)
                    :callback-p (ataxia.kernel:drawable-surface-frame-callback-p surface)))))

(defun %display-context (world stage-output &rest options)
  (apply #'%make-display-context
         :world world :stage-output stage-output :output-name (%output-name stage-output)
         :screen (%buffer-transform stage-output)
         :bounds (ataxia.world:make-rectangle 0 0 (stage-output-buffer-width stage-output)
                                              (stage-output-buffer-height stage-output))
         options))

(defun build-seat-items (world stage-output)
  "Cursor and drag icon items for STAGE-OUTPUT, painted above everything else."
  (let ((context (%display-context world stage-output :tag :seat)))
    (dolist (seat-state (%seat-states world))
      (when (eq stage-output (%seat-output world seat-state))
        (%emit-cursor context seat-state)))
    (nreverse (display-context-items context))))

(defun build-display (world stage-output)
  "Flatten the scene and overlays for STAGE-OUTPUT. Return items in paint order, hits
topmost first, the windows and pages presented, whether anything animates, whether
text needs a refining frame, and the text raster scales used."
  (let* ((context (%display-context world stage-output
                                    :presented (make-hash-table :test #'eq)
                                    :raster-scales (make-hash-table :test #'eql)))
         (buffer (display-context-screen context)))
    (clrhash (stage-output-window-transforms stage-output))
    (setf (stage-output-pointer-effects-p stage-output) nil)
    (let ((camera (camera-transform stage-output)))
      (setf (display-context-tag context) :scene)
      (%emit-children context (scene-root (%scene world)) (affine-multiply buffer camera)
                      (affine-invert camera) 1d0)
      (when (eq stage-output (first (%outputs world)))
        (setf (display-context-tag context) :fallback)
        (%emit-children context (scene-root (%fallback world)) buffer +identity-affine+ 1d0)))
    (setf (display-context-tag context) :overlay)
    (emit-overlays context)
    (values (nreverse (display-context-items context))
            (display-context-hits context)
            (display-context-presented context)
            (display-context-animating-p context)
            (display-context-refine-p context)
            (display-context-raster-scales context))))

(defun %apply-presence (world stage-output presented)
  "Track which outputs show each window; Kernel derives wl_surface.enter from it."
  (let ((output (stage-output-output stage-output)))
    (loop for window being the hash-values of (%windows world)
          for shown-p = (gethash window presented)
          for member-p = (member output (stage-window-outputs window))
          unless (eq (not shown-p) (not member-p))
            do (%set-window-membership window (if shown-p
                                                  (cons output (stage-window-outputs window))
                                                  (remove output (stage-window-outputs window)))))))

(defun %reordered (kept)
  "KEPT holds (OLD-INDEX . DAMAGE) of unchanged items in their new paint order. Return
the damage of the fewest whose moves explain that order: all but a longest run still
in old order, found by patience sorting."
  (let* ((count (length kept))
         (kept (coerce kept 'simple-vector))
         ;; TAILS holds, for each run length, the position ending the lowest such run.
         (tails (make-array count :fill-pointer 0))
         (links (make-array count :initial-element nil))
         (in-order (make-array count :element-type 'bit :initial-element 0)))
    (dotimes (position count)
      (let* ((index (car (svref kept position)))
             (length (let ((low 0) (high (fill-pointer tails)))
                       (loop while (< low high)
                             do (let ((middle (floor (+ low high) 2)))
                                  (if (< (car (svref kept (aref tails middle))) index)
                                      (setf low (1+ middle))
                                      (setf high middle))))
                       low)))
        (when (plusp length) (setf (svref links position) (aref tails (1- length))))
        (if (= length (fill-pointer tails))
            (vector-push position tails)
            (setf (aref tails length) position))))
    (loop for position = (aref tails (1- (fill-pointer tails))) then (svref links position)
          while position do (setf (sbit in-order position) 1))
    (loop for position below count
          when (zerop (sbit in-order position)) append (cdr (svref kept position)))))

(defun %diff-items (world stage-output items previous current)
  "Damage every item whose pixels may have changed since PREVIOUS, the table of the
last diffed items; fill the emptied table CURRENT for ITEMS and return it. Items
appearing or leaving change no others; items changing places damage only the fewest
that moved."
  (let ((region nil)
        (kept nil)
        (in-order-p t))
    (clrhash current)
    (loop for item in items
          for index from 0
          for old = (gethash (item-key item) previous)
          for damage = (or (item-damage item) (list (item-bounds item)))
          do (setf (gethash (item-key item) current) (list* damage index (item-signature item)))
             (cond ((not (and old (equalp (cddr old) (item-signature item))))
                    (setf region (append damage (when old (car old)) region)))
                   (t
                    (when (and kept (< (cadr old) (caar kept))) (setf in-order-p nil))
                    (push (cons (cadr old) damage) kept))))
    (maphash (lambda (key old)
               (unless (gethash key current) (setf region (append (car old) region))))
             previous)
    (unless in-order-p
      (setf region (append (%reordered (nreverse kept)) region)))
    (when region
      (ataxia.world:damage-add-region (%damage world) (stage-output-output stage-output) region))
    current))

(defun %damage-content (world client rectangles)
  "Project content damage through every transform presenting CLIENT, a window or a page."
  (dolist (stage-output (%outputs world))
    (let ((transforms (gethash client (stage-output-window-transforms stage-output))))
      (when transforms
        (ataxia.world:damage-add-region
         (%damage world) (stage-output-output stage-output)
         (loop for transform in transforms
               nconc (loop for rectangle in rectangles
                           collect (%inflate
                                    (affine-rectangle-bounds
                                     transform
                                     (ataxia.kernel:frame-damage-rectangle-x rectangle)
                                     (ataxia.kernel:frame-damage-rectangle-y rectangle)
                                     (ataxia.kernel:frame-damage-rectangle-width rectangle)
                                     (ataxia.kernel:frame-damage-rectangle-height rectangle))
                                    1))))
        (%request-frames world (list stage-output))))))

(defun %damage-cursor (world seat-state)
  "Repaint the output under the cursor and any output still showing a cursor; the
next frame's diff of the cursor items finds the pixels. Effects reading the pointer
there are rebuilt too. Other outputs stay asleep."
  (let* ((current (%seat-output world seat-state))
         (outputs (remove-if-not (lambda (stage-output)
                                   (or (eq stage-output current)
                                       (plusp (hash-table-count (stage-output-seat-items stage-output)))))
                                 (%outputs world))))
    (dolist (stage-output outputs)
      (when (stage-output-pointer-effects-p stage-output)
        (setf (stage-output-display-valid-p stage-output) nil)))
    (%request-frames world outputs)))

(defun %refresh-display (world stage-output)
  "Rebuild STAGE-OUTPUT's cached display and hit lists unless they match the scene."
  (unless (stage-output-display-valid-p stage-output)
    (multiple-value-bind (items hits presented animating-p refine-p raster-scales)
        (build-display world stage-output)
      (setf (stage-output-display stage-output) (list items presented animating-p raster-scales)
            (stage-output-hits stage-output) hits
            (stage-output-built-at stage-output) (%now)
            (stage-output-diffed-p stage-output) nil
            ;; Text drawn at an approximate scale is redrawn by the next frame.
            (stage-output-display-valid-p stage-output) (not refine-p))
      (when refine-p (%request-frames world (list stage-output))))))

(defun output-hits (world stage-output)
  "Pick targets for STAGE-OUTPUT, topmost first, as the scene presents now."
  (%refresh-display world stage-output)
  (stage-output-hits stage-output))

;;; Frames.

(defun %settling-p (world)
  (or (scene-settling-p (%scene world)) (scene-settling-p (%fallback world))))

(defun %moving-outputs (world)
  "Outputs whose camera moves, or that showed endless loops on their last frame."
  (let ((loops-p (or (scene-moving-p (%scene world)) (scene-moving-p (%fallback world)))))
    (remove-if-not (lambda (stage-output)
                     (or (camera-moving-p stage-output)
                         (and loops-p (stage-output-animating-p stage-output))))
                   (%outputs world))))

(defun %advance (world timestamp)
  "Sample motion at TIMESTAMP and keep frames coming while anything moves. Finite
motion may bring anything into view, so it keeps every output up; a moving camera
wakes only its output, and endless loops only the outputs showing them."
  (when (> timestamp (%advanced-at world))
    ;; Whatever moved until now has new values, including the step that ends a motion.
    (when (or (%settling-p world) (%moving-outputs world))
      (%invalidate-display world))
    (setf (%advanced-at world) timestamp)
    (scene-advance (%scene world) timestamp)
    (scene-advance (%fallback world) timestamp)
    (dolist (stage-output (%outputs world))
      (camera-sample stage-output timestamp)))
  (if (%settling-p world)
      (%request-frames world)
      (let ((awake (%moving-outputs world)))
        (when awake (%request-frames world awake)))))

(defmethod ataxia.kernel:world-graphics-attached ((world stage-world) graphics-context)
  (declare (ignore graphics-context))
  (setf (%renderer world) (create-stage-renderer))
  (%full-damage world)
  world)

(defmethod ataxia.kernel:world-graphics-detaching ((world stage-world) graphics-context reason)
  (declare (ignore graphics-context reason))
  (detach-web-graphics world)
  (detach-overlay-graphics world)
  (destroy-stage-renderer (%renderer world))
  (setf (%renderer world) nil)
  world)

(defun %sync-buffer-geometry (stage-output lease)
  (let ((width (ataxia.kernel:frame-width lease))
        (height (ataxia.kernel:frame-height lease))
        (transform (ataxia.kernel:frame-transform lease)))
    (unless (and (= width (stage-output-buffer-width stage-output))
                 (= height (stage-output-buffer-height stage-output))
                 (= transform (stage-output-transform stage-output)))
      (setf (stage-output-buffer-width stage-output) width
            (stage-output-buffer-height stage-output) height
            (stage-output-transform stage-output) transform)
      (clrhash (stage-output-items stage-output))
      (clrhash (stage-output-seat-items stage-output))
      (setf (stage-output-display-valid-p stage-output) nil))))

(defparameter +pass-cost+ 12000
  "What one more paint pass costs, in pixels painted. A pass walks the items and
issues the draws it touches again: about 18 us here, against 1.5 ns a pixel.")

(defun %pixel-rectangle (rectangle width height)
  (multiple-value-bind (x y pixel-width pixel-height)
      (ataxia.world:rectangle-pixel-bounds rectangle width height)
    (when (and (plusp pixel-width) (plusp pixel-height))
      (ataxia.world:make-rectangle x y pixel-width pixel-height))))

(defun %contains-p (outer inner)
  (equalp (ataxia.world:rectangle-intersection outer inner) inner))

(defun %blur-passes (region items width height)
  "Paint passes repairing REGION, a pass per rectangle. A blur reads every pixel of
its area, so an area REGION reaches is painted whole by a single pass, merged with
any area it overlaps, and no other pass touches it."
  (let ((areas (loop for item in items
                     for area = (and (item-blur-area item)
                                     (%pixel-rectangle (item-blur-area item) width height))
                     when area collect area))
        (reached nil)
        (changed t))
    (loop while changed
          do (setf changed nil)
             (dolist (area areas)
               (when (or (ataxia.world:region-intersects-p area region)
                         (ataxia.world:region-intersects-p area reached))
                 (setf areas (remove area areas :test #'eq)
                       changed t)
                 (loop for overlapping = (find-if (lambda (other)
                                                    (ataxia.world:rectangle-intersection other area))
                                                  reached)
                       while overlapping
                       do (setf reached (remove overlapping reached :test #'eq)
                                area (ataxia.world:rectangle-union area overlapping)))
                 (push area reached))))
    (if (null reached)
        region
        ;; A rectangle holding an area whole paints it; otherwise the area is a pass of its own.
        (let ((holders (mapcar (lambda (area)
                                 (find-if (lambda (rectangle) (%contains-p rectangle area)) region))
                               reached)))
          (nconc (loop for rectangle in region
                       nconc (ataxia.world:subtract-region
                              (list rectangle)
                              (loop for area in reached
                                    for holder in holders
                                    unless (eq holder rectangle) collect area)
                              :rectangle-limit nil))
                 (loop for area in reached
                       for holder in holders
                       unless holder collect area))))))

(defun %frame-passes (region items width height)
  "Paint passes repairing REGION: rectangles near enough to share a pass merged,
whole blur areas, or the whole buffer once that is cheaper."
  (let ((passes (%blur-passes (ataxia.world:coalesce-damage-region
                               region :width width :height height :merge-cost +pass-cost+)
                              items width height)))
    (if (<= (+ (* width height) +pass-cost+)
            (+ (reduce #'+ passes :key #'ataxia.world:rectangle-area)
               (* +pass-cost+ (length passes))))
        (list (ataxia.world:make-rectangle 0 0 width height))
        passes)))

(defun %rectangles-overlap-p (left right)
  (and (< (max (ataxia.world:rectangle-x left) (ataxia.world:rectangle-x right))
          (min (ataxia.world:rectangle-right left) (ataxia.world:rectangle-right right)))
       (< (max (ataxia.world:rectangle-y left) (ataxia.world:rectangle-y right))
          (min (ataxia.world:rectangle-bottom left) (ataxia.world:rectangle-bottom right)))))

(defun draw-layer (renderer items rectangle width height &optional owner)
  "Paint the ITEMS OWNER draws (NIL: the frame) that overlap buffer RECTANGLE, whose
scissor is set, bottom first; return the presentation tokens of surfaces drawn."
  (let ((tokens nil))
    (multiple-value-bind (x y pixel-width pixel-height)
        (ataxia.world:rectangle-pixel-bounds rectangle width height)
      (dolist (item items tokens)
        (when (and (eq (item-owner item) owner) (%rectangles-overlap-p rectangle (item-bounds item)))
          (when (item-clip item)
            (let ((visible (ataxia.world:rectangle-intersection rectangle (item-bounds item))))
              (multiple-value-call #'set-stage-scissor renderer
                (ataxia.world:rectangle-pixel-bounds
                 (or (ataxia.world:rectangle-intersection visible (item-clip item)) visible)
                 width height))))
          (if (item-effect item)
              (setf tokens (union (draw-effect renderer item rectangle width height) tokens))
              (when (and (funcall (item-draw item) renderer) (item-token item))
                (pushnew (item-token item) tokens :test #'eq)))
          (when (item-clip item)
            (set-stage-scissor renderer x y pixel-width pixel-height)))))))

(defun %draw-items (renderer layers region width height debug-p)
  "Paint the item lists in LAYERS, bottom first, within REGION; return presentation
tokens of surfaces drawn."
  (let ((tokens nil))
    (when debug-p
      (set-stage-scissor renderer 0 0 width height)
      (ataxia.world.gles:gles-clear 0.55d0 0.015d0 0.08d0 1d0))
    ;; Each damaged rectangle is repainted from the bottom, so overlapping
    ;; rectangles never accumulate translucent layers twice.
    (dolist (rectangle region)
      (multiple-value-bind (x y pixel-width pixel-height)
          (ataxia.world:rectangle-pixel-bounds rectangle width height)
        (when (and (plusp pixel-width) (plusp pixel-height))
          (set-stage-scissor renderer x y pixel-width pixel-height)
          (ataxia.world.gles:gles-clear 0.055d0 0.055d0 0.065d0 1d0)
          (dolist (items layers)
            (setf tokens (union (draw-layer renderer items rectangle width height) tokens))))))
    tokens))

(defmethod ataxia.kernel:world-render ((world stage-world) lease)
  (let* ((output (ataxia.kernel:frame-output lease))
         (stage-output (%find-stage-output world output))
         (renderer (%renderer world))
         (width (ataxia.kernel:frame-width lease))
         (height (ataxia.kernel:frame-height lease)))
    (unless (and stage-output renderer)
      (error "Stage World cannot render an unattached output."))
    (%sync-buffer-geometry stage-output lease)
    (%advance world (ataxia.kernel:frame-timestamp lease))
    (sweep-webs world)
    (sweep-departed world)
    (prepare-webs world stage-output)
    (prepare-overlays world stage-output)
    (%refresh-display world stage-output)
    (destructuring-bind (items presented animating-p raster-scales) (stage-output-display stage-output)
      (setf (stage-output-animating-p stage-output) animating-p)
      ;; A display reused from the previous frame has nothing new to diff.
      (unless (stage-output-diffed-p stage-output)
        (%apply-presence world stage-output presented)
        (sync-web-presence world stage-output presented)
        (setf (stage-output-raster-scales stage-output) raster-scales)
        (rotatef (stage-output-items stage-output) (stage-output-spare-items stage-output))
        (%diff-items world stage-output items (stage-output-spare-items stage-output)
                     (stage-output-items stage-output))
        (setf (stage-output-diffed-p stage-output) t))
      (let ((seat-items (build-seat-items world stage-output)))
        (rotatef (stage-output-seat-items stage-output) (stage-output-spare-seat-items stage-output))
        (%diff-items world stage-output seat-items (stage-output-spare-seat-items stage-output)
                     (stage-output-seat-items stage-output))
      (multiple-value-bind (region damage-frame)
          (ataxia.world:damage-begin-frame (%damage world) output
                                           (ataxia.kernel:frame-target-token lease)
                                           (ataxia.kernel:frame-generation lease)
                                           width height)
        (let ((tokens nil)
              (region (%frame-passes region items width height)))
          (when region
            (begin-stage-frame renderer width height)
            (setf tokens (%draw-items renderer (list items seat-items) region width height
                                      (%damage-debug-p world)))
            (finish-stage-frame)
            (note-output-presented world stage-output region))
          ;; A raster any output's cached display uses was touched when that display was built.
          (sweep-rasters renderer (reduce #'min (%outputs world) :key #'stage-output-built-at
                                                                 :initial-value (%now)))
          (release-stale-pixels world)
          (make-instance
           'ataxia.kernel:world-frame-result
           :target-token (ataxia.kernel:frame-target-token lease)
           :damage (ataxia.world:region-to-frame-damage
                    (if (%damage-debug-p world)
                        (list (ataxia.world:make-rectangle 0 0 width height))
                        region)
                    width height)
           :presentation-tokens (coerce tokens 'vector)
           ;; Visible clients waiting for a frame progress even when their
           ;; pixels were not repainted this frame.
           :callback-tokens (coerce (loop for layer in (list items seat-items)
                                          nconc (loop for item in layer
                                                      when (and (item-callback-p item) (item-token item)
                                                                (not (member (item-token item) tokens)))
                                                        collect (item-token item)))
                                    'vector)
           :complete-p t
           :world-cookie damage-frame)))))))

(defmethod ataxia.kernel:world-frame-committed ((world stage-world) output frame-result commit-info)
  (declare (ignore output commit-info))
  (let ((damage-frame (ataxia.kernel:frame-result-world-cookie frame-result)))
    (when damage-frame (ataxia.world:damage-commit-frame (%damage world) damage-frame)))
  frame-result)

(defmethod ataxia.kernel:world-frame-failed ((world stage-world) output frame-result reason)
  (declare (ignore reason))
  (when frame-result
    (let ((damage-frame (ataxia.kernel:frame-result-world-cookie frame-result)))
      (when damage-frame (ataxia.world:damage-fail-frame (%damage world) damage-frame))))
  (let ((stage-output (%find-stage-output world output)))
    (when stage-output (%request-frames world (list stage-output))))
  frame-result)
