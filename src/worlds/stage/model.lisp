;;;; Scene node kinds and their property schema.
;;;;
;;;; The director sends canonical JSON values. These tables are the only place
;;;; that maps protocol names to keywords, so remote text is never interned.
;;;; Declared values are kept decoded on the node; animated ones also drive
;;;; channels.

(in-package #:ataxia.stage-world)

(defstruct (prop-spec (:constructor %make-prop-spec))
  (name "" :type string :read-only t)
  (key nil :type keyword :read-only t)
  (type :number :read-only t)
  (default nil :read-only t)
  (animated-p nil :read-only t)
  (tolerance 1d-3 :type double-float :read-only t)
  ;; :LOG animates the logarithm, giving zoom a perceptually uniform pace.
  (space :linear :read-only t)
  (choices nil :read-only t))

(defparameter +prop-specs+
  (let ((table (make-hash-table :test #'equal)))
    (dolist (row
             '(("x" :x :number 0d0 :animated-p t :tolerance 1d-2)
               ("y" :y :number 0d0 :animated-p t :tolerance 1d-2)
               ("width" :width :number nil :animated-p t :tolerance 1d-2)
               ("height" :height :number nil :animated-p t :tolerance 1d-2)
               ("scale" :scale :number 1d0 :animated-p t)
               ("rotation" :rotation :number 0d0 :animated-p t)
               ("opacity" :opacity :number 1d0 :animated-p t)
               ("originX" :origin-x :number 0.5d0)
               ("originY" :origin-y :number 0.5d0)
               ("visible" :visible :boolean t)
               ("color" :color :color #(0d0 0d0 0d0 0d0) :animated-p t)
               ("radius" :radius :number 0d0 :animated-p t :tolerance 1d-2)
               ("borderWidth" :border-width :number 0d0 :animated-p t :tolerance 1d-2)
               ("borderColor" :border-color :color #(0d0 0d0 0d0 0d0) :animated-p t)
               ("shadowColor" :shadow-color :color #(0d0 0d0 0d0 0d0) :animated-p t)
               ("shadowBlur" :shadow-blur :number 0d0 :animated-p t :tolerance 1d-2)
               ("shadowSpread" :shadow-spread :number 0d0 :animated-p t :tolerance 1d-2)
               ("shadowX" :shadow-x :number 0d0 :animated-p t :tolerance 1d-2)
               ("shadowY" :shadow-y :number 0d0 :animated-p t :tolerance 1d-2)
               ("window" :window :id nil)
               ("fullscreen" :fullscreen :boolean nil)
               ("maximized" :maximized :boolean nil)
               ("tiled" :tiled :boolean nil)
               ("focusable" :focusable :boolean t)
               ("interactive" :interactive :boolean t)
               ("grid" :grid :choice :none
                :choices (("none" . :none) ("dots" . :dots) ("lines" . :lines)))
               ("gridColor" :grid-color :color #(0d0 0d0 0d0 0d0) :animated-p t)
               ("gridSpacing" :grid-spacing :number 32d0 :animated-p t :tolerance 1d-2)
               ("gridSize" :grid-size :number 1d0 :animated-p t)
               ("output" :output :string nil)
               ("zoom" :zoom :number 1d0 :animated-p t :space :log :tolerance 1d-4)
               ("key" :key :string nil)
               ("modifiers" :modifiers :modifiers nil)
               ("repeat" :repeat :boolean nil)
               ("button" :button :id 272)
               ("gesture" :gesture :choice :swipe
                :choices (("swipe" . :swipe) ("pinch" . :pinch) ("hold" . :hold)))
               ("fingers" :fingers :id 3)
               ("action" :action :choice :none
                :choices (("none" . :none) ("move" . :move) ("resize" . :resize)
                          ("pan" . :pan) ("zoom" . :zoom)))
               ("pan" :pan :boolean nil)
               ("draggable" :draggable :boolean nil)
               ("movable" :movable :boolean nil)
               ("resizable" :resizable :boolean nil)
               ("minZoom" :min-zoom :number 0.05d0)
               ("maxZoom" :max-zoom :number 8d0)
               ;; Two-stop linear gradients; an absent end color means a solid paint.
               ("colorEnd" :color-end :color nil :animated-p t)
               ("fillAngle" :fill-angle :number 0d0 :animated-p t)
               ("borderColorEnd" :border-color-end :color nil :animated-p t)
               ("borderAngle" :border-angle :number 0d0 :animated-p t)
               ("dim" :dim :number 0d0 :animated-p t)
               ("blur" :blur :number 0d0 :animated-p t :tolerance 1d-2)
               ("clip" :clip :boolean nil)
               ("text" :text :string nil)
               ("markup" :markup :boolean nil)
               ("font" :font :string nil)
               ("fontSize" :font-size :number 14d0)
               ("fontWeight" :font-weight :number 400d0)
               ("italic" :italic :boolean nil)
               ("align" :align :choice :start
                :choices (("start" . :start) ("center" . :center) ("end" . :end)))
               ("lineHeight" :line-height :number nil)
               ("maxLines" :max-lines :id nil)
               ("src" :src :string nil)
               ;; Web pages: JSON text posted as the page's props, and a reload counter.
               ("data" :data :string nil)
               ("autoFocus" :auto-focus :boolean nil)
               ("revision" :revision :number nil)
               ;; Screen space a world keeps for its own UI, in logical pixels.
               ("top" :top :number 0d0)
               ("right" :right :number 0d0)
               ("bottom" :bottom :number 0d0)
               ("left" :left :number 0d0)
               ("fit" :fit :choice :fill
                :choices (("fill" . :fill) ("contain" . :contain) ("cover" . :cover)))
               ;; Effects: the director's GLSL `effect` function and how it is run.
               ("shader" :shader :string nil)
               ("amount" :amount :number 1d0 :animated-p t)
               ("margin" :margin :number 0d0)
               ("local" :local :boolean nil)
               ("time" :time :boolean nil)
               ("backdrop" :backdrop :boolean nil)
               ("pointer" :pointer :boolean nil)
               ("area" :area :choice :box :choices (("box" . :box) ("output" . :output)))
               ;; Pointer shape over the node and its children; NIL inherits.
               ("cursor" :cursor :choice nil
                :choices (("none" . :none) ("default" . :default) ("pointer" . :pointer)
                          ("text" . :text) ("crosshair" . :crosshair) ("move" . :move)
                          ("grab" . :grab) ("grabbing" . :grabbing) ("not-allowed" . :not-allowed)
                          ("help" . :help) ("wait" . :wait) ("progress" . :progress)
                          ("zoom-in" . :zoom-in) ("zoom-out" . :zoom-out)
                          ("ew-resize" . :ew-resize) ("ns-resize" . :ns-resize)
                          ("nwse-resize" . :nwse-resize) ("nesw-resize" . :nesw-resize)))))
      (destructuring-bind (name key type default &rest options) row
        (setf (gethash name table)
              (apply #'%make-prop-spec :name name :key key :type type
                     :default default options))))
    table))

(defparameter +transform-props+
  '(:x :y :scale :rotation :opacity :origin-x :origin-y :visible))

(defparameter +effect-props+ '(:shader :amount :margin :local :time :backdrop :pointer :area)
  "What runs a visual node and its subtree through the director's GLSL.")

(defparameter +box-props+
  '(:width :height :radius :border-width :border-color :border-color-end :border-angle
    :shadow-color :shadow-blur :shadow-spread :shadow-x :shadow-y :blur))

(defparameter +node-kinds+
  `(("group" :group (,@+transform-props+ ,@+effect-props+ :width :height :clip :draggable :cursor))
    ("rect" :rect (,@+transform-props+ ,@+box-props+ ,@+effect-props+ :color :color-end :fill-angle
                   :clip :draggable :cursor))
    ("text" :text (,@+transform-props+ ,@+effect-props+ :width :text :markup :font :font-size
                   :font-weight :italic :color :align :line-height :max-lines :draggable :cursor))
    ("image" :image (,@+transform-props+ ,@+box-props+ ,@+effect-props+ :src :fit :draggable :cursor))
    ("web" :web (,@+transform-props+ ,@+box-props+ ,@+effect-props+ :src :data :revision :focusable
                 :interactive :auto-focus :cursor))
    ("window" :window (,@+transform-props+ ,@+box-props+ ,@+effect-props+ :window :fullscreen
                       :maximized :tiled :focusable :interactive :movable :resizable :dim))
    ("background" :background
     (:x :y :scale :rotation :opacity :visible :color :grid :grid-color :grid-spacing :grid-size
      :pan :cursor))
    ("camera" :camera (:output :x :y :zoom :rotation :min-zoom :max-zoom))
    ("screen" :screen (:output :x :y :scale :rotation :opacity :visible))
    ("reserve" :reserve (:output :top :right :bottom :left))
    ("shortcut" :shortcut (:key :modifiers :repeat))
    ("pointer-binding" :pointer-binding (:button :modifiers :action))
    ("wheel-binding" :wheel-binding (:modifiers :action))
    ("gesture-binding" :gesture-binding (:gesture :fingers :modifiers :action)))
  "Protocol name, node kind and accepted properties of every scene node type.")

(defun kind-effects-p (kind)
  "Whether nodes of KIND can run through an effect."
  (member :shader (kind-props kind)))

(defun node-kind-animates-p (kind)
  "Camera nodes declare targets for compositor-owned cameras; they hold no channels."
  (not (eq kind :camera)))

(defparameter +event-names+
  '(("pointerdown" . :pointerdown) ("pointermove" . :pointermove) ("pointerup" . :pointerup)
    ("pointerenter" . :pointerenter) ("pointerleave" . :pointerleave) ("wheel" . :wheel)
    ("press" . :press) ("release" . :release)
    ("down" . :down) ("move" . :move) ("up" . :up)
    ("begin" . :begin) ("update" . :update) ("end" . :end)
    ("moverequest" . :moverequest) ("resizerequest" . :resizerequest)
    ("fullscreenrequest" . :fullscreenrequest) ("maximizerequest" . :maximizerequest)
    ("minimizerequest" . :minimizerequest) ("activaterequest" . :activaterequest)
    ("dragstart" . :dragstart) ("drag" . :drag) ("dragend" . :dragend)
    ("resizestart" . :resizestart) ("resize" . :resize) ("resizeend" . :resizeend)
    ("measure" . :measure) ("load" . :load) ("error" . :error) ("message" . :message)))

(defparameter +modifier-names+
  '(("shift" . :shift) ("control" . :control) ("alt" . :alt) ("logo" . :logo)))

(define-condition stage-protocol-error (error)
  ((message :initarg :message :reader stage-protocol-error-message))
  (:report (lambda (condition stream)
             (write-string (stage-protocol-error-message condition) stream))))

(defun protocol-error (control &rest arguments)
  (error 'stage-protocol-error :message (apply #'format nil control arguments)))

(defun find-node-kind (name)
  (or (find name +node-kinds+ :key #'first :test #'equal)
      (protocol-error "Unknown node type ~S." name)))

(defun kind-props (kind)
  (third (find kind +node-kinds+ :key #'second)))

(defparameter +prop-specs-by-key+
  (let ((table (make-hash-table :test #'eq)))
    (maphash (lambda (name spec)
               (declare (ignore name))
               (setf (gethash (prop-spec-key spec) table) spec))
             +prop-specs+)
    table))

(defun find-prop-spec (key)
  (or (gethash key +prop-specs-by-key+)
      (error "Unknown Stage property ~S." key)))

;;; Value decoding. JSON null resets a property to its default.

(defun %finite-number (value name)
  (unless (and (realp value)
               (< (abs value) 1d12))
    (protocol-error "Property ~A requires a finite number." name))
  (coerce value 'double-float))

(defun %json-list (value name)
  (unless (and (vectorp value) (not (stringp value)))
    (protocol-error "Property ~A requires an array." name))
  (coerce value 'list))

(defun decode-prop-value (spec value)
  (let ((name (prop-spec-name spec)))
    (if (null value)
        (prop-spec-default spec)
        (ecase (prop-spec-type spec)
          (:number
           (let ((number (%finite-number value name)))
             (when (and (eq (prop-spec-space spec) :log) (not (plusp number)))
               (protocol-error "Property ~A must be positive." name))
             number))
          (:color
           (let ((components (%json-list value name)))
             (unless (= 4 (length components))
               (protocol-error "Property ~A requires [r, g, b, a]." name))
             (map 'vector (lambda (component)
                            (max 0d0 (min 1d0 (%finite-number component name))))
                  components)))
          (:boolean
           (cond ((eq value t) t)
                 ((eq value :false) nil)
                 (t (protocol-error "Property ~A requires a boolean." name))))
          (:string
           (unless (stringp value)
             (protocol-error "Property ~A requires a string." name))
           value)
          (:id
           (unless (typep value '(integer 0 #.(expt 2 53)))
             (protocol-error "Property ~A requires a non-negative integer." name))
           value)
          (:choice
           (or (cdr (assoc value (prop-spec-choices spec) :test #'equal))
               (protocol-error "Property ~A has unknown value ~S." name value)))
          (:modifiers
           (mapcar (lambda (modifier)
                     (or (cdr (assoc modifier +modifier-names+ :test #'equal))
                         (protocol-error "Unknown modifier ~S." modifier)))
                   (%json-list value name)))))))

(defun %decode-ease (raw)
  "A CSS cubic-bezier (X1 Y1 X2 Y2), or NIL for linear."
  (when raw
    (let ((ease (mapcar (lambda (number) (%finite-number number "ease")) (%json-list raw "ease"))))
      (unless (and (= 4 (length ease)) (<= 0d0 (first ease) 1d0) (<= 0d0 (third ease) 1d0))
        (protocol-error "An ease must be a CSS cubic-bezier."))
      ease)))

(defun %decode-points (raw name &key (minimum 2) (maximum 1024))
  (let ((points (%json-list raw name)))
    (unless (<= minimum (length points) maximum)
      (protocol-error "~A needs ~D to ~D entries." name minimum maximum))
    points))

(defun %field (object name default &key (minimum 0d0) positive-p)
  "Numeric field NAME of OBJECT, at least MINIMUM (and positive with POSITIVE-P)."
  (let ((raw (gethash name object)))
    (if (null raw)
        default
        (let ((number (%finite-number raw name)))
          (when (or (< number minimum) (and positive-p (zerop number)))
            (protocol-error "Field ~A is out of range." name))
          number))))

(defun decode-motion (value)
  "Decode one canonical transition object into a MOTION."
  (unless (hash-table-p value)
    (protocol-error "A transition must be an object."))
  (flet ((repeat ()
           (let ((repeat (gethash "repeat" value)))
             (cond ((null repeat) 0)
                   ((equal repeat "forever") :forever)
                   ((typep repeat '(integer 0 10000)) repeat)
                   (t (protocol-error "repeat must be a count or \"forever\"."))))))
    (let ((type (gethash "type" value)))
      (cond
        ((equal type "spring")
         (make-motion :spring
                      :stiffness (%field value "stiffness" 170d0 :positive-p t)
                      :damping (%field value "damping" 26d0 :positive-p t)
                      :mass (%field value "mass" 1d0 :positive-p t)
                      :delay (%field value "delay" 0d0)))
        ((equal type "tween")
         (make-motion :tween :duration (%field value "duration" 0.25d0 :positive-p t)
                             :ease (%decode-ease (gethash "ease" value))
                             :delay (%field value "delay" 0d0) :repeat (repeat)))
        ((equal type "curve")
         (make-motion :curve :duration (%field value "duration" 0.25d0 :positive-p t)
                             :points (map 'vector (lambda (point) (%finite-number point "points"))
                                          (%decode-points (gethash "points" value) "points"))
                             :delay (%field value "delay" 0d0) :repeat (repeat)))
        ((equal type "instant") (make-motion :instant))
        (t (protocol-error "Unknown transition type ~S." type))))))

;;; Nodes.

(defstruct (stage-node (:constructor %make-stage-node (id kind)))
  (id 0 :type integer :read-only t)
  (kind nil :type keyword :read-only t)
  (parent nil)
  (children nil :type list)
  ;; Declared values by key, decoded. Absent keys use defaults.
  (props (make-hash-table :test #'eq) :read-only t)
  ;; Animated keys map to one channel, or a vector of four for colors.
  (channels (make-hash-table :test #'eq) :read-only t)
  ;; Transition per key; :DEFAULT applies to keys without their own entry.
  (motions (make-hash-table :test #'eq) :read-only t)
  (initial nil :type list)
  (exit nil :type list)
  (layout-id nil)
  (handlers nil :type list)
  ;; Running animation LAYERs, applied in order over the properties' values.
  (layers nil :type list)
  ;; Effect uniforms: (NAME . CHANNELS), sorted by name, a channel per component.
  (uniforms nil :type list)
  ;; Keys driven by direct manipulation; director values for them wait until it ends.
  (held nil :type list)
  ;; Derived from props by the node's kind: a text layout, a shared image or a page.
  (cache nil)
  ;; :LIVE, :REMOVED during the commit that removes it, :EXITING, then :DEAD.
  (state :live :type keyword))

(defun %prop-spec-for (node name)
  (let ((spec (gethash name +prop-specs+)))
    (unless (and spec (member (prop-spec-key spec) (kind-props (stage-node-kind node))))
      (protocol-error "A ~(~A~) node has no property ~S." (stage-node-kind node) name))
    spec))

(defun node-prop (node key)
  (multiple-value-bind (value present-p) (gethash key (stage-node-props node))
    (if present-p value (prop-spec-default (find-prop-spec key)))))

(defun node-declared-p (node key)
  (nth-value 1 (gethash key (stage-node-props node))))

(defun node-motion (node key)
  (or (gethash key (stage-node-motions node))
      (gethash :default (stage-node-motions node))))

(defun to-channel (spec value)
  "VALUE of SPEC as its channel holds it: logarithmic properties animate the log."
  (if (eq (prop-spec-space spec) :log) (log value) value))

(defun from-channel (spec number)
  (if (eq (prop-spec-space spec) :log) (exp number) number))

(defun node-number (node key &optional default)
  "Displayed value of a numeric property, or DEFAULT when it is unset."
  (let* ((channel (gethash key (stage-node-channels node)))
         (base (if channel
                   (from-channel (find-prop-spec key) (channel-value channel))
                   (or (node-prop node key) default))))
    (if (stage-node-layers node) (%layered node key base) base)))

(defparameter +gradient-ends+ '((:color-end . :color) (:border-color-end . :border-color))
  "Gradient end colors and the solid color each one falls back to while unset.")

(defun %base-color (node key)
  (let ((channels (gethash key (stage-node-channels node)))
        (color (node-prop node key)))
    (cond
      (channels
       (values (channel-value (svref channels 0)) (channel-value (svref channels 1))
               (channel-value (svref channels 2)) (channel-value (svref channels 3))))
      (color (values (aref color 0) (aref color 1) (aref color 2) (aref color 3)))
      (t (%base-color node (cdr (assoc key +gradient-ends+)))))))

(defun node-color (node key)
  "Displayed straight-alpha color as four values."
  (if (stage-node-layers node)
      (let ((color (%layered node key (multiple-value-call #'vector (%base-color node key)))))
        (values (aref color 0) (aref color 1) (aref color 2) (aref color 3)))
      (%base-color node key)))

;;; Animation layers.

(defstruct (layer (:constructor make-layer (id key track composite)))
  "A keyframe TRACK on property KEY, replacing its value or (COMPOSITE :ADD) added to it.
ID lets a later declaration of the same animation keep running instead of restarting."
  (id nil :read-only t)
  (key nil :type keyword :read-only t)
  (track nil :type track :read-only t)
  (composite :replace :type (member :replace :add) :read-only t)
  (start 0d0 :type double-float)
  ;; The value sampled for the current frame, or NIL while delayed or done.
  (current nil)
  ;; Finished layers stay until the director drops them, so declaring the same
  ;; animation again, e.g. next to a new one, does not replay it.
  (done-p nil))

(defun %add-value (base offset)
  (if (vectorp base)
      (map 'vector (lambda (low high) (max 0d0 (min 1d0 (+ low high)))) base offset)
      (+ base offset)))

(defun %layered (node key base)
  "BASE with NODE's running layers for KEY applied, in order."
  (dolist (layer (stage-node-layers node) base)
    (let ((current (layer-current layer)))
      (when (and current (eq (layer-key layer) key))
        (setf base (if (eq (layer-composite layer) :add)
                       (and base (%add-value base current))
                       current))))))

(defun %decode-layer (node object)
  "A LAYER from one entry of a node's `animate` list; its start is set by the scene."
  (unless (hash-table-p object) (protocol-error "Each animation must be an object."))
  (let* ((id (gethash "id" object))
         (name (gethash "property" object))
         (spec (%prop-spec-for node name))
         (keyframes (map 'vector (lambda (raw)
                                   (when (null raw) (protocol-error "Keyframes need values."))
                                   (decode-prop-value spec raw))
                         (%decode-points (gethash "keyframes" object) "keyframes")))
         (count (length keyframes))
         (offsets (let ((raw (gethash "offsets" object)))
                    (if raw
                        (map 'vector (lambda (offset) (%finite-number offset "offsets"))
                             (%decode-points raw "offsets" :minimum count :maximum count))
                        (coerce (loop for index below count collect (/ index (1- count) 1d0))
                                'vector))))
         (iterations (gethash "iterations" object)))
    (unless (or (stringp id) (typep id '(integer 0 #.(expt 2 53))))
      (protocol-error "An animation needs a string or numeric id."))
    (unless (and (prop-spec-animated-p spec) (node-kind-animates-p (stage-node-kind node)))
      (protocol-error "Property ~A cannot animate." name))
    (unless (and (= 0d0 (svref offsets 0)) (= 1d0 (svref offsets (1- count)))
                 (every #'<= offsets (subseq offsets 1)))
      (protocol-error "Keyframe offsets must rise from 0 to 1."))
    (make-layer id (prop-spec-key spec)
                (make-track keyframes offsets
                            :ease (%decode-ease (gethash "ease" object))
                            :duration (%field object "duration" 1d0 :positive-p t)
                            :delay (%field object "delay" 0d0)
                            :iterations (cond ((null iterations) 1)
                                              ((equal iterations "forever") :forever)
                                              ((typep iterations '(integer 1 1000000)) iterations)
                                              (t (protocol-error "iterations must be a count or \"forever\".")))
                            :direction (let ((direction (gethash "direction" object)))
                                         (cond ((null direction) :normal)
                                               ((equal direction "normal") :normal)
                                               ((equal direction "reverse") :reverse)
                                               ((equal direction "alternate") :alternate)
                                               ((equal direction "alternate-reverse") :alternate-reverse)
                                               (t (protocol-error "Unknown direction ~S." direction)))))
                (let ((composite (gethash "composite" object)))
                  (cond ((or (null composite) (equal composite "replace")) :replace)
                        ((equal composite "add") :add)
                        (t (protocol-error "Unknown composite ~S." composite)))))))

(defun %uniform-name-p (name)
  "A GLSL identifier outside the prefixes the effect prelude reserves."
  (and (stringp name) (<= 1 (length name) 32)
       (alpha-char-p (char name 0))
       (every (lambda (char) (or (alphanumericp char) (char= char #\_))) name)
       (not (find-if (lambda (prefix) (eql 0 (search prefix name))) '("gl_" "u_" "v_" "a_" "stage_")))))

(defun decode-uniforms (raw)
  "Effect uniforms from an object of names to a number or 2 or 4 numbers: an alist of
names to component vectors, sorted by name."
  (unless (hash-table-p raw) (protocol-error "uniforms must be an object."))
  (when (> (hash-table-count raw) 16) (protocol-error "At most 16 uniforms per effect."))
  (let ((uniforms nil))
    (maphash (lambda (name value)
               (unless (%uniform-name-p name)
                 (protocol-error "~S is not a usable uniform name." name))
               (let ((components (if (realp value)
                                     (vector (%finite-number value name))
                                     (map 'vector (lambda (component) (%finite-number component name))
                                          (%json-list value name)))))
                 (unless (member (length components) '(1 2 4))
                   (protocol-error "Uniform ~A needs 1, 2 or 4 numbers." name))
                 (push (cons name components) uniforms)))
             raw)
    (sort uniforms #'string< :key #'car)))

(defun decode-layers (node raw)
  "LAYERs from a node's `animate` list, or NIL for null."
  (when raw
    (let ((entries (%json-list raw "animate")))
      (when (> (length entries) 32) (protocol-error "At most 32 animations per node."))
      (mapcar (lambda (entry) (%decode-layer node entry)) entries))))

(defun sample-layers (node time)
  "Sample NODE's running layers at TIME."
  (dolist (layer (stage-node-layers node))
    (unless (layer-done-p layer)
      (let ((value (track-sample (layer-track layer) (- time (layer-start layer)))))
        (case value
          (:done (setf (layer-current layer) nil (layer-done-p layer) t))
          (:pending (setf (layer-current layer) nil))
          (t (setf (layer-current layer) value)))))))

(defun layers-running-p (node &optional finite-only-p)
  "True while any of NODE's layers runs; with FINITE-ONLY-P, any that will finish."
  (some (lambda (layer)
          (and (not (layer-done-p layer))
               (not (and finite-only-p (track-endless-p (layer-track layer))))))
        (stage-node-layers node)))

(defun node-handles-p (node event)
  (member event (stage-node-handlers node)))

(defparameter +bubbling-events+
  '(:pointerdown :pointermove :pointerup :pointerenter :pointerleave :wheel)
  "Pointer events the director passes up through a node's ancestors, as the DOM does.")

(defun node-receives-p (node event)
  "Whether NODE handles EVENT or, for a bubbling EVENT, any of its ancestors does."
  (if (member event +bubbling-events+)
      (loop for current = node then (stage-node-parent current)
            while current thereis (node-handles-p current event))
      (node-handles-p node event)))

(defun node-moving-p (node)
  (or (layers-running-p node)
      (loop for (nil . channels) in (stage-node-uniforms node)
              thereis (some #'channel-active-p channels))
      (loop for value being the hash-values of (stage-node-channels node)
              thereis (if (vectorp value)
                          (some #'channel-active-p value)
                          (channel-active-p value)))))
