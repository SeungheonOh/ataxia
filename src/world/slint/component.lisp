;;;; CLOS identity and lifecycle for one interpreted Slint component.
;;;;
;;;; The component is a native World object. Its logical size and invalidation
;;;; callback belong to the World; Slint's opaque scene stays behind CFFI.

(in-package #:ataxia.world.slint)

(defclass slint-render-source (ataxia.kernel:render-source)
  ((texture :initarg :texture :reader %render-source-texture)
   (width :initarg :width :reader %render-source-width)
   (height :initarg :height :reader %render-source-height)
   (generation :initarg :generation :reader %render-source-generation)))

(defclass slint-component (ataxia.kernel:drawable ataxia.kernel:interactable)
  ((native :initarg :native :accessor %component-native)
   (width :initarg :width :accessor slint-component-width)
   (height :initarg :height :accessor slint-component-height)
   (scale :initarg :scale :accessor slint-component-scale)
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
    (error "The Slint component is destroyed."))
  (%component-native component))

(defun %notify-change (component)
  (when (%component-invalidator component)
    (funcall (%component-invalidator component) component))
  component)

(defun make-slint-component
    (&key source (source-path "ataxia-component.slint") component-name
          (width 640d0) (height 360d0) (scale 1d0) invalidator)
  "Compile SOURCE and return a World-owned Slint drawable/interactable."
  (check-type source string)
  (check-type source-path string)
  (check-type width (real (0)))
  (check-type height (real (0)))
  (check-type scale (real (0)))
  (ataxia.world.slint.raw::initialize)
  (let* ((width (coerce width 'double-float))
         (height (coerce height 'double-float))
         (scale (coerce scale 'double-float))
         (native
           (ataxia.world.slint.raw::%component-create
            source source-path (or component-name "")
            (%physical-size width scale) (%physical-size height scale)
            (coerce scale 'single-float))))
    (when (cffi:null-pointer-p native)
      (ataxia.world.slint.raw::native-error :component-creation))
    (make-instance
     'slint-component :native native :width width :height height :scale scale
     :invalidator invalidator)))

(defun set-slint-component-invalidator (component function)
  (check-type component slint-component)
  (check-type function (or null function))
  (setf (%component-invalidator component) function)
  component)

(defun resize-slint-component (component width height &key (scale (slint-component-scale component)))
  (check-type width (real (0)))
  (check-type height (real (0)))
  (check-type scale (real (0)))
  (let ((width (coerce width 'double-float))
        (height (coerce height 'double-float))
        (scale (coerce scale 'double-float)))
    (%live-native component)
    (when (and (= width (slint-component-width component))
               (= height (slint-component-height component))
               (= scale (slint-component-scale component)))
      (return-from resize-slint-component component))
    (ataxia.world.slint.raw::check-result
     (ataxia.world.slint.raw::%component-resize
      (%live-native component)
      (%physical-size width scale) (%physical-size height scale)
      (coerce scale 'single-float))
     :resize)
    (setf (slint-component-width component) width
          (slint-component-height component) height
          (slint-component-scale component) scale)
    (%notify-change component)))

(defun destroy-slint-component (component)
  (when (and component (not (%component-destroyed-p component)))
    (when (plusp (%component-texture component))
      (error "Detach Slint component graphics before destroying it."))
    (ataxia.world.slint.raw::%component-destroy (%component-native component))
    (setf (%component-native component) (cffi:null-pointer)
          (%component-destroyed-p component) t
          (%component-invalidator component) nil)
    (clrhash (%component-callbacks component)))
  nil)

(defun set-slint-property (component name value)
  "Set a public string, number, or boolean property and invalidate COMPONENT."
  (check-type name string)
  (let ((native (%live-native component)))
    (ataxia.world.slint.raw::check-result
     (etypecase value
       (string (ataxia.world.slint.raw::%set-string native name value))
       (real (ataxia.world.slint.raw::%set-number native name (coerce value 'double-float)))
       (boolean (ataxia.world.slint.raw::%set-boolean native name value)))
     :set-property))
  (%notify-change component))

(defun set-slint-callback (component name function)
  "Connect a public Slint callback to a synchronous Lisp function."
  (check-type name string)
  (check-type function function)
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%register-callback
    (%live-native component) name)
   :register-callback)
  (setf (gethash name (%component-callbacks component)) function)
  component)

(defun remove-slint-callback (component name)
  (ataxia.world.slint.raw::check-result
   (ataxia.world.slint.raw::%unregister-callback
    (%live-native component) name)
   :unregister-callback)
  (remhash name (%component-callbacks component))
  component)

(defun poll-slint-callbacks (component)
  "Dispatch queued Slint callbacks and return their count."
  (let* ((native (%live-native component))
         (count (ataxia.world.slint.raw::%callback-count native))
         (events
           (loop for index below count
                 collect
                 (cons (ataxia.world.slint.raw::%callback-name native index)
                       (ataxia.world.slint.raw::%callback-value native index)))))
    (ataxia.world.slint.raw::%clear-callbacks native)
    (dolist (event events)
      (let ((function (gethash (car event) (%component-callbacks component))))
        (when function
          (funcall function component (cdr event)))))
    count))

(defun update-slint-timers ()
  (ataxia.world.slint.raw::%update-timers))

(defun slint-next-timer-milliseconds ()
  (ataxia.world.slint.raw::%next-timer-milliseconds))

(defun slint-component-active-p (component)
  (ataxia.world.slint.raw::%component-active-p (%live-native component)))
