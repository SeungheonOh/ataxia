;;;; Wayland presentation and surface-sampling protocols.
;;;;
;;;; This module owns the viewporter, fractional-scale, and presentation-time
;;;; globals. It exposes exact wlroots operations while rendering policy stays
;;;; in the compositor and behavior packages.

(in-package #:ataxia.runtime.raw)

(defcfun ("wlr_viewporter_create" %wlr-viewporter-create) :pointer
  (display :pointer))
(defcfun ("wlr_fractional_scale_manager_v1_create"
          %wlr-fractional-scale-manager-v1-create) :pointer
  (display :pointer)
  (version :uint32))
(defcfun ("wlr_fractional_scale_v1_notify_scale"
          %wlr-fractional-scale-v1-notify-scale) :void
  (surface :pointer)
  (scale :double))
(defcfun ("wlr_surface_set_preferred_buffer_scale"
          %wlr-surface-set-preferred-buffer-scale) :void
  (surface :pointer)
  (scale :int32))
(defcfun ("wlr_presentation_create" %wlr-presentation-create) :pointer
  (display :pointer)
  (backend :pointer)
  (version :uint32))
(defcfun ("wlr_presentation_surface_textured_on_output"
          %wlr-presentation-surface-textured-on-output) :void
  (surface :pointer)
  (output :pointer))

(in-package #:ataxia.runtime)

(defconstant +fractional-scale-version+ 1)
(defconstant +presentation-time-version+ 2)

(defclass wlr-viewporter (native-object) ()
  (:documentation
   "Wraps the native wlr viewporter object. Runtime owns its listener registration and must invalidate the wrapper before the corresponding native object is destroyed."))
(defclass wlr-fractional-scale-manager-v1 (native-object) ()
  (:documentation
   "Wraps the native wlr fractional scale manager v1 object. Runtime owns its listener registration and must invalidate the wrapper before the corresponding native object is destroyed."))
(defclass wlr-presentation (native-object) ()
  (:documentation
   "Wraps the native wlr presentation object. Runtime owns its listener registration and must invalidate the wrapper before the corresponding native object is destroyed."))

(defun runtime-viewporter (runtime)
  (%runtime-viewporter runtime))

(defun runtime-fractional-scale-manager (runtime)
  (%runtime-fractional-scale-manager runtime))

(defun runtime-presentation (runtime)
  (%runtime-presentation runtime))

(defun create-presentation-protocols (runtime)
  "Publish protocols required for correct cropped, scaled, timed surfaces."
  (%assert-runtime-live runtime :create-presentation-protocols)
  (when (or (%runtime-viewporter runtime)
            (%runtime-fractional-scale-manager runtime)
            (%runtime-presentation runtime))
    (error 'native-call-failed
           :name :create-presentation-protocols
           :detail "presentation protocols already exist"))
  (let ((display (%object-pointer (%runtime-display runtime))))
    (setf
     (%runtime-viewporter runtime)
     (%wrap-pointer
      'wlr-viewporter
      (%require-pointer
       (ataxia.runtime.raw:%wlr-viewporter-create display)
       :wlr-viewporter-create)
      runtime)
     (%runtime-fractional-scale-manager runtime)
     (%wrap-pointer
      'wlr-fractional-scale-manager-v1
      (%require-pointer
       (ataxia.runtime.raw:%wlr-fractional-scale-manager-v1-create
        display +fractional-scale-version+)
       :wlr-fractional-scale-manager-v1-create)
      runtime)
     (%runtime-presentation runtime)
     (%wrap-pointer
      'wlr-presentation
      (%require-pointer
       (ataxia.runtime.raw:%wlr-presentation-create
        display (%object-pointer (%runtime-backend runtime))
        +presentation-time-version+)
       :wlr-presentation-create)
      runtime)))
  (values (%runtime-viewporter runtime)
          (%runtime-fractional-scale-manager runtime)
          (%runtime-presentation runtime)))

(defun notify-surface-preferred-scale (surface scale)
  (%ensure-live surface)
  (unless (and (realp scale) (plusp scale))
    (error 'native-call-failed
           :name :notify-surface-preferred-scale :detail scale))
  (let ((native (%object-pointer surface))
        (value (coerce scale 'double-float)))
    (ataxia.runtime.raw:%wlr-fractional-scale-v1-notify-scale native value)
    (ataxia.runtime.raw:%wlr-surface-set-preferred-buffer-scale
     native (ceiling value)))
  surface)

(defun mark-surface-textured-on-output (surface output)
  (%assert-object-runtime (%native-runtime surface) output
                          :mark-surface-textured-on-output)
  (ataxia.runtime.raw:%wlr-presentation-surface-textured-on-output
   (%object-pointer surface) (%object-pointer output))
  surface)

(defun surface-content-layout (surface)
  "Return logical size, normalized source box, and wl_output transform."
  (%ensure-live surface)
  (let ((native (%object-pointer surface)))
    (cffi:with-foreign-objects ((x :double) (y :double)
                                (width :double) (height :double))
      (unless (ataxia.runtime.raw:%surface-buffer-source-box
               native x y width height)
        (return-from surface-content-layout
          (values 0 0 0d0 0d0 0d0 0d0 0)))
      (let ((buffer-width
              (ataxia.runtime.raw:%surface-current-buffer-width native))
            (buffer-height
              (ataxia.runtime.raw:%surface-current-buffer-height native)))
        (values
         (ataxia.runtime.raw:%surface-current-width native)
         (ataxia.runtime.raw:%surface-current-height native)
         (/ (cffi:mem-ref x :double) (max 1 buffer-width))
         (/ (cffi:mem-ref y :double) (max 1 buffer-height))
         (/ (cffi:mem-ref width :double) (max 1 buffer-width))
         (/ (cffi:mem-ref height :double) (max 1 buffer-height))
         (ataxia.runtime.raw:%surface-current-transform native))))))
