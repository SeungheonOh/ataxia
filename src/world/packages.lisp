;;;; Packages for reusable World-side mechanisms.
;;;;
;;;; These packages are implementation libraries. They do not receive Kernel
;;;; callbacks and never constitute another compositor layer.

(defpackage #:ataxia.world
  (:use #:cl)
  (:export
   #:rectangle
   #:make-rectangle
   #:rectangle-x
   #:rectangle-y
   #:rectangle-width
   #:rectangle-height
   #:rectangle-right
   #:rectangle-bottom
   #:rectangle-pixel-bounds
   #:rectangle-empty-p
   #:rectangle-intersection
   #:rectangle-union
   #:normalize-region
   #:clip-region
   #:region-intersects-p
   #:region-to-frame-damage
   #:frame-damage-to-region
   #:application-binding
   #:binding-application
   #:animator
   #:make-animator
   #:start-animation
   #:cancel-animation
   #:cancel-subject-animations
   #:advance-animations
   #:animations-active-p
   #:linear-easing
   #:ease-in-cubic
   #:ease-out-cubic
   #:ease-in-out-cubic
   #:damage-tracker
   #:make-damage-tracker
   #:damage-add-region
   #:damage-full-output
   #:damage-reset-output
   #:damage-forget-output
   #:damage-pending-p
   #:damage-begin-frame
   #:damage-commit-frame
   #:damage-fail-frame
   #:damage-frame-region
   #:damage-debug-mode-p
   #:set-damage-debug-mode
   #:refresh-world
   #:interaction-delivered-p))

(defpackage #:ataxia.world.gles
  (:use #:cl)
  (:export
   #:+texture-2d+
   #:+texture-external-oes+
   #:gles-program
   #:make-gles-program
   #:destroy-gles-program
   #:gles-program-handle
   #:gles-use-program
   #:gles-uniform-location
   #:gles-uniform-1f
   #:gles-uniform-1i
   #:gles-uniform-2f
   #:gles-uniform-4f
   #:gles-create-buffer
   #:gles-destroy-buffer
   #:gles-upload-floats
   #:gles-enable-attribute
   #:gles-disable-attribute
   #:gles-bind-texture
   #:call-with-gles-linear-filter
   #:gles-clear
   #:gles-set-scissor
   #:gles-set-scissor-enabled
   #:gles-set-blending-enabled
   #:gles-reset-state
   #:gles-draw-triangles
   #:gles-flush
   #:gles-check-error))
