;;;; CLOS identity and lifecycle for one interpreted RmlUi component.
;;;;
;;;; The component is a native World object. Its logical size and invalidation
;;;; callback belong to the World; RmlUi's opaque scene stays behind CFFI.

(in-package #:ataxia.world.rmlui)

(defclass rmlui-render-source (ataxia.kernel:render-source)
  ((texture :initarg :texture :reader %render-source-texture)
   (width :initarg :width :reader %render-source-width)
   (height :initarg :height :reader %render-source-height)
   (generation :initarg :generation :reader %render-source-generation)))

(defclass rmlui-component (ataxia.kernel:drawable ataxia.kernel:interactable)
  ((native :initarg :native :accessor %component-native)
   (width :initarg :width :accessor rmlui-component-width)
   (height :initarg :height :accessor rmlui-component-height)
   (scale :initarg :scale :accessor rmlui-component-scale)
   (texture :initform 0 :accessor %component-texture)
   (framebuffer :initform 0 :accessor %component-framebuffer)
   (stencil-buffer :initform 0 :accessor %component-stencil-buffer)
   (texture-width :initform 0 :accessor %component-texture-width)
   (texture-height :initform 0 :accessor %component-texture-height)
   (texture-generation :initform 0 :accessor %component-texture-generation)
   (revision :initform 0 :accessor %component-revision)
   (surfaces :initform #() :accessor %component-surfaces)
   (pressed-keys :initform (make-hash-table :test #'eql)
                 :reader %component-pressed-keys)
   (callbacks :initform (make-hash-table :test #'equal)
              :reader %component-callbacks)
   (invalidator :initarg :invalidator :initform nil
                :accessor %component-invalidator)
   (destroyed-p :initform nil :accessor %component-destroyed-p)))

(defun %physical-size (logical-size scale)
  (max 1 (round (* logical-size scale))))

(defun %live-native (component)
  (when (%component-destroyed-p component)
    (error "The RmlUi component is destroyed."))
  (%component-native component))

(defun %notify-change (component)
  (when (%component-invalidator component)
    (funcall (%component-invalidator component) component))
  component)

(defun make-rmlui-component
    (&key source (source-path "ataxia-component.rml") component-name
          (width 640d0) (height 360d0) (scale 1d0) invalidator)
  "Parse RML SOURCE and return a World-owned RmlUi drawable/interactable."
  (check-type source string)
  (check-type source-path string)
  (check-type width (real (0)))
  (check-type height (real (0)))
  (check-type scale (real (0)))
  (ataxia.world.rmlui.raw::initialize)
  (let* ((width (coerce width 'double-float))
         (height (coerce height 'double-float))
         (scale (coerce scale 'double-float))
         (native
           (ataxia.world.rmlui.raw::%component-create
            source source-path (or component-name "")
            (%physical-size width scale) (%physical-size height scale)
            (coerce scale 'single-float))))
    (when (cffi:null-pointer-p native)
      (ataxia.world.rmlui.raw::native-error :component-creation))
    (make-instance
     'rmlui-component :native native :width width :height height :scale scale
     :invalidator invalidator)))

(defun set-rmlui-component-invalidator (component function)
  (check-type component rmlui-component)
  (check-type function (or null function))
  (setf (%component-invalidator component) function)
  component)

(defun resize-rmlui-component (component width height &key (scale (rmlui-component-scale component)))
  (check-type width (real (0)))
  (check-type height (real (0)))
  (check-type scale (real (0)))
  (let ((width (coerce width 'double-float))
        (height (coerce height 'double-float))
        (scale (coerce scale 'double-float)))
    (%live-native component)
    (when (and (= width (rmlui-component-width component))
               (= height (rmlui-component-height component))
               (= scale (rmlui-component-scale component)))
      (return-from resize-rmlui-component component))
    (ataxia.world.rmlui.raw::check-result
     (ataxia.world.rmlui.raw::%component-resize
      (%live-native component)
      (%physical-size width scale) (%physical-size height scale)
      (coerce scale 'single-float))
     :resize)
    (setf (rmlui-component-width component) width
          (rmlui-component-height component) height
          (rmlui-component-scale component) scale)
    (%notify-change component)))

(defun destroy-rmlui-component (component)
  (when (and component (not (%component-destroyed-p component)))
    (when (plusp (%component-texture component))
      (error "Detach RmlUi component graphics before destroying it."))
    (ataxia.world.rmlui.raw::%component-destroy (%component-native component))
    (setf (%component-native component) (cffi:null-pointer)
          (%component-destroyed-p component) t
          (%component-invalidator component) nil)
    (clrhash (%component-callbacks component)))
  nil)

(defun set-rmlui-property (component name value)
  "Set a text or form value of the element named NAME and invalidate COMPONENT."
  (check-type name string)
  (let ((native (%live-native component)))
    (ataxia.world.rmlui.raw::check-result
     (etypecase value
       (string (ataxia.world.rmlui.raw::%set-string native name value))
       (real (ataxia.world.rmlui.raw::%set-number native name (coerce value 'double-float)))
       (boolean (ataxia.world.rmlui.raw::%set-boolean native name value)))
     :set-property))
  (%notify-change component))

(defun set-rmlui-callback (component name function)
  "Connect an ID:event (or ID for click) callback to a synchronous Lisp function."
  (check-type name string)
  (check-type function function)
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%register-callback
    (%live-native component) name)
   :register-callback)
  (setf (gethash name (%component-callbacks component)) function)
  component)

(defun remove-rmlui-callback (component name)
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%unregister-callback
    (%live-native component) name)
   :unregister-callback)
  (remhash name (%component-callbacks component))
  component)

(defun poll-rmlui-callbacks (component)
  "Dispatch queued RmlUi callbacks and return their count."
  (let* ((native (%live-native component))
         (count (ataxia.world.rmlui.raw::%callback-count native))
         (events
           (loop for index below count
                 collect
                 (cons (ataxia.world.rmlui.raw::%callback-name native index)
                       (ataxia.world.rmlui.raw::%callback-value native index)))))
    (ataxia.world.rmlui.raw::%clear-callbacks native)
    (dolist (event events)
      (let ((function (gethash (car event) (%component-callbacks component))))
        (when function
          (funcall function component (cdr event)))))
    count))

(defun rmlui-component-active-p (component)
  (ataxia.world.rmlui.raw::%component-active-p (%live-native component)))

(defun load-rmlui-font (path)
  (ataxia.world.rmlui.raw::initialize)
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%load-font (namestring (pathname path))) :load-font))

(defun set-rmlui-class (component id name enabled)
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%set-class (%live-native component) id name (not (null enabled))) :set-class)
  (%notify-change component))

(defun set-rmlui-attribute (component id name value)
  "Set an element attribute; NIL removes it (including boolean attributes)."
  (check-type value (or null string))
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%set-attribute (%live-native component) id name (or value "") (not (null value)))
   :set-attribute)
  (%notify-change component))

(defun set-rmlui-style (component id name value)
  "Set an inline RCSS property; ID empty selects the document body."
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%set-style (%live-native component) id name value) :set-style)
  (%notify-change component))

(defun reload-rmlui-component (component source &key (source-path "ataxia-component.rml"))
  "Replace the document after parsing and validating its callback targets."
  (ataxia.world.rmlui.raw::check-result
   (ataxia.world.rmlui.raw::%reload (%live-native component) source source-path) :reload)
  (%notify-change component))

(defun set-rmlui-model (component name value)
  "Set a typed scalar in the component's state data model."
  (check-type name string)
  (let ((native (%live-native component)))
    (ataxia.world.rmlui.raw::check-result
     (etypecase value
       (string (ataxia.world.rmlui.raw::%model-string native name value))
       (real (ataxia.world.rmlui.raw::%model-number native name (coerce value 'double-float)))
       (boolean (ataxia.world.rmlui.raw::%model-boolean native name value))) :set-model))
  (%notify-change component))

(defun rmlui-model-value (component name)
  "Read a scalar model value as a string, including user edits from data-value."
  (or (ataxia.world.rmlui.raw::%model-value (%live-native component) name)
      (ataxia.world.rmlui.raw::native-error :model-value)))
