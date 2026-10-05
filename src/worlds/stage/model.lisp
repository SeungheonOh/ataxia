;;;; Scene node kinds and their property schema.
;;;;
;;;; The director sends canonical JSON values. These tables are the only place
;;;; that maps protocol names to keywords, so remote text is never interned.
;;;; Animated properties live in channels; every other declared value is kept
;;;; verbatim on the node.

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
               ;; Shell navigation: workspaces the status bar shows and switches.
               ("name" :name :string nil)
               ("count" :count :id 0)
               ("selected" :selected :id 0)
               ("active" :active :boolean t)
               ;; Screen space a world keeps for its own UI, in logical pixels.
               ("top" :top :number 0d0)
               ("right" :right :number 0d0)
               ("bottom" :bottom :number 0d0)
               ("left" :left :number 0d0)
               ("fit" :fit :choice :fill
                :choices (("fill" . :fill) ("contain" . :contain) ("cover" . :cover)))))
      (destructuring-bind (name key type default &rest options) row
        (setf (gethash name table)
              (apply #'%make-prop-spec :name name :key key :type type
                     :default default options))))
    table))

(defparameter +transform-props+
  '(:x :y :scale :rotation :opacity :origin-x :origin-y :visible))

(defparameter +box-props+
  '(:width :height :radius :border-width :border-color :border-color-end :border-angle
    :shadow-color :shadow-blur :shadow-spread :shadow-x :shadow-y :blur))

(defparameter +node-kinds+
  `(("group" :group (,@+transform-props+ :width :height :clip :draggable))
    ("rect" :rect (,@+transform-props+ ,@+box-props+ :color :color-end :fill-angle :clip :draggable))
    ("text" :text (,@+transform-props+ :width :text :markup :font :font-size :font-weight :italic
                   :color :align :line-height :max-lines :draggable))
    ("image" :image (,@+transform-props+ ,@+box-props+ :src :fit :draggable))
    ("web" :web (,@+transform-props+ ,@+box-props+ :src :data :revision :focusable :interactive
                 :auto-focus))
    ("window" :window (,@+transform-props+ ,@+box-props+ :window :fullscreen :maximized
                       :tiled :focusable :interactive :movable :resizable :dim))
    ("background" :background
     (:x :y :scale :rotation :opacity :visible :color :grid :grid-color :grid-spacing :grid-size
      :pan))
    ("camera" :camera (:output :x :y :zoom :rotation :min-zoom :max-zoom))
    ("screen" :screen (:output :x :y :scale :rotation :opacity :visible))
    ("shell" :shell (:name :count :selected :active))
    ("reserve" :reserve (:output :top :right :bottom :left))
    ("shortcut" :shortcut (:key :modifiers :repeat))
    ("pointer-binding" :pointer-binding (:button :modifiers :action))
    ("wheel-binding" :wheel-binding (:modifiers :action))
    ("gesture-binding" :gesture-binding (:gesture :fingers :modifiers :action)))
  "Protocol name, node kind and accepted properties of every scene node type.")

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
    ("minimizerequest" . :minimizerequest)
    ("dragstart" . :dragstart) ("drag" . :drag) ("dragend" . :dragend)
    ("resizestart" . :resizestart) ("resize" . :resize) ("resizeend" . :resizeend)
    ("measure" . :measure) ("load" . :load) ("error" . :error) ("message" . :message)
    ("navigate" . :navigate)))

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

(defun decode-motion (value)
  "Decode one canonical transition object into a MOTION."
  (unless (hash-table-p value)
    (protocol-error "A transition must be an object."))
  (flet ((field (name default &key (minimum 0d0) (positive-p nil))
           (let ((raw (gethash name value)))
             (if (null raw)
                 default
                 (let ((number (%finite-number raw name)))
                   (when (or (< number minimum) (and positive-p (zerop number)))
                     (protocol-error "Transition field ~A is out of range." name))
                   number)))))
    (let ((type (gethash "type" value)))
      (cond
        ((equal type "spring")
         (make-motion :spring
                      :stiffness (field "stiffness" 170d0 :positive-p t)
                      :damping (field "damping" 26d0 :positive-p t)
                      :mass (field "mass" 1d0 :positive-p t)
                      :delay (field "delay" 0d0)))
        ((equal type "tween")
         (let ((ease (gethash "ease" value))
               (repeat (gethash "repeat" value)))
           (when ease
             (setf ease (mapcar (lambda (number) (%finite-number number "ease"))
                                (%json-list ease "ease")))
             (unless (and (= 4 (length ease))
                          (<= 0d0 (first ease) 1d0) (<= 0d0 (third ease) 1d0))
               (protocol-error "Tween ease must be a CSS cubic-bezier.")))
           (make-motion :tween :duration (field "duration" 0.25d0 :positive-p t)
                               :ease ease :delay (field "delay" 0d0)
                               :repeat (cond ((null repeat) 0)
                                             ((equal repeat "forever") :forever)
                                             ((typep repeat '(integer 0 10000)) repeat)
                                             (t (protocol-error "repeat must be a count or \"forever\"."))))))
        ((equal type "instant") (make-motion :instant))
        (t (protocol-error "Unknown transition type ~S." type))))))

;;; Nodes.

(defstruct (stage-node (:constructor %make-stage-node (id kind)))
  (id 0 :type integer :read-only t)
  (kind nil :type keyword :read-only t)
  (parent nil)
  (children nil :type list)
  ;; Declared values by key, exactly as last sent. Absent keys use defaults.
  (props (make-hash-table :test #'eq) :read-only t)
  ;; Animated keys map to one channel, or a vector of four for colors.
  (channels (make-hash-table :test #'eq) :read-only t)
  ;; Transition per key; :DEFAULT applies to keys without their own entry.
  (motions (make-hash-table :test #'eq) :read-only t)
  (initial nil :type list)
  (exit nil :type list)
  (layout-id nil)
  (handlers nil :type list)
  ;; Keys driven by direct manipulation; director values for them wait until it ends.
  (held nil :type list)
  ;; Derived from props by the node's kind: a text layout or a shared image.
  (cache nil)
  ;; :LIVE, :REMOVED during the commit that removes it, or :EXITING.
  (state :live :type keyword))

(defun node-prop (node key)
  (multiple-value-bind (value present-p) (gethash key (stage-node-props node))
    (if present-p value (prop-spec-default (find-prop-spec key)))))

(defun node-declared-p (node key)
  (nth-value 1 (gethash key (stage-node-props node))))

(defun node-motion (node key)
  (or (gethash key (stage-node-motions node))
      (gethash :default (stage-node-motions node))))

(defun %channel-value (spec channel)
  (if (eq (prop-spec-space spec) :log)
      (exp (channel-value channel))
      (channel-value channel)))

(defun node-number (node key &optional default)
  "Displayed value of a numeric property, or DEFAULT when it is unset."
  (let ((channel (gethash key (stage-node-channels node))))
    (cond
      (channel (%channel-value (find-prop-spec key) channel))
      (t (let ((value (node-prop node key)))
           (if value value default))))))

(defparameter +gradient-ends+ '((:color-end . :color) (:border-color-end . :border-color))
  "Gradient end colors and the solid color each one falls back to while unset.")

(defun node-color (node key)
  "Displayed straight-alpha color as four values."
  (let ((channels (gethash key (stage-node-channels node)))
        (color (node-prop node key)))
    (cond
      (channels
       (values (channel-value (svref channels 0)) (channel-value (svref channels 1))
               (channel-value (svref channels 2)) (channel-value (svref channels 3))))
      (color (values (aref color 0) (aref color 1) (aref color 2) (aref color 3)))
      (t (node-color node (cdr (assoc key +gradient-ends+)))))))

(defun node-handles-p (node event)
  (member event (stage-node-handlers node)))

(defun node-moving-p (node)
  (loop for value being the hash-values of (stage-node-channels node)
          thereis (if (vectorp value)
                      (some #'channel-active-p value)
                      (channel-active-p value))))
