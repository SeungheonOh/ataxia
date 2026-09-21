;;;; Direct drag-icon/committed-offset accessors, separate from the core ABI.
(in-package #:ataxia.runtime)

(cffi:defcfun ("ataxia_drag_wlroots_version" %drag-wlroots-version) :string)
(cffi:defcfun ("ataxia_drag_icon_surface" %drag-icon-surface) :pointer (drag :pointer))
(cffi:defcfun ("ataxia_surface_commit_offset" %surface-commit-offset) :void
  (surface :pointer) (x :pointer) (y :pointer))
(defvar *drag-library* nil)
(defun %load-drag-library ()
  (unless *drag-library*
    (setf *drag-library*
          (cffi:load-foreign-library
           (asdf:system-relative-pathname "ataxia-runtime" "build/libataxia-wlr-drag.so")))
    (unless (string= (%drag-wlroots-version) ataxia.runtime.raw::+expected-wlroots-version+)
      (error "Drag helper was built against a different wlroots version."))))

(defun drag-icon-surface (drag)
  (%assert-runtime-live (%native-runtime drag) :drag-icon-surface)
  (%load-drag-library)
  (let ((pointer (%drag-icon-surface (%object-pointer drag))))
    (unless (cffi:null-pointer-p pointer)
      (%adopt-core-surface (%native-runtime drag) pointer))))

(defun surface-commit-offset (surface)
  "Committed relative buffer displacement, consumed once per surface commit."
  (%assert-runtime-live (%native-runtime surface) :surface-commit-offset)
  (%load-drag-library)
  (cffi:with-foreign-objects ((x :int32) (y :int32))
    (%surface-commit-offset (%object-pointer surface) x y)
    (values (cffi:mem-ref x :int32) (cffi:mem-ref y :int32))))
