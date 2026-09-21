;;;; Exact XWayland wrappers, copied requests, callbacks and native lifetime.
(in-package #:ataxia.runtime)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (export '(wlr-xwayland wlr-xwayland-surface create-xwayland destroy-xwayland
            xwayland-display-name xwayland-set-seat xwayland-surface-server
            xwayland-surface-parent xwayland-surface-surface xwayland-surface-consider-map
            xwayland-surface-title xwayland-surface-class xwayland-surface-x xwayland-surface-y
            xwayland-surface-width xwayland-surface-height xwayland-surface-override-redirect-p
            xwayland-surface-configure xwayland-surface-activate xwayland-surface-close
            xwayland-surface-set-fullscreen xwayland-surface-set-maximized xwayland-surface-set-minimized
            xwayland-ready xwayland-destroying xwayland-new-surface
            xwayland-surface-associated xwayland-surface-dissociated xwayland-surface-destroying
            xwayland-surface-title-changed xwayland-surface-class-changed xwayland-surface-geometry-changed
            xwayland-surface-request-configure xwayland-surface-request-fullscreen
            xwayland-surface-request-maximize xwayland-surface-request-minimize
            xwayland-surface-request-move xwayland-surface-request-resize xwayland-surface-request-activate
            xwayland-configure-x xwayland-configure-y xwayland-configure-width
            xwayland-configure-height xwayland-configure-mask)))

(cffi:defcfun ("wlr_xwayland_create" %xwayland-create) :pointer (display :pointer) (compositor :pointer) (lazy :bool))
(cffi:defcfun ("wlr_xwayland_destroy" %xwayland-destroy) :void (server :pointer))
(cffi:defcfun ("wlr_xwayland_set_seat" %xwayland-set-seat) :void (server :pointer) (seat :pointer))
(cffi:defcfun ("ataxia_xwayland_signal" %xwayland-signal) :pointer (server :pointer) (event :int))
(cffi:defcfun ("ataxia_xwayland_display" %xwayland-display) :string (server :pointer))
(cffi:defcfun ("ataxia_xsurface_signal" %xsurface-signal) :pointer (surface :pointer) (event :int))
(cffi:defcfun ("ataxia_xsurface_surface" %xsurface-surface) :pointer (surface :pointer))
(cffi:defcfun ("ataxia_xsurface_consider_map" %xsurface-consider-map) :void (surface :pointer))
(cffi:defcfun ("ataxia_xsurface_parent" %xsurface-parent) :pointer (surface :pointer))
(cffi:defcfun ("ataxia_xsurface_text" %xsurface-text) :string (surface :pointer) (field :int))
(cffi:defcfun ("ataxia_xsurface_value" %xsurface-value) :int (surface :pointer) (field :int))
(cffi:defcfun ("ataxia_xconfigure_value" %xconfigure-value) :int (event :pointer) (field :int))
(cffi:defcfun ("ataxia_xminimize_value" %xminimize-value) :bool (event :pointer))
(cffi:defcfun ("ataxia_xresize_edges" %xresize-edges) :uint32 (event :pointer))
(cffi:defcfun ("wlr_xwayland_surface_configure" %xsurface-configure) :void (surface :pointer) (x :int16) (y :int16) (width :uint16) (height :uint16))
(cffi:defcfun ("wlr_xwayland_surface_activate" %xsurface-activate) :void (surface :pointer) (active :bool))
(cffi:defcfun ("wlr_xwayland_surface_close" %xsurface-close) :void (surface :pointer))
(cffi:defcfun ("wlr_xwayland_surface_set_fullscreen" %xsurface-fullscreen) :void (surface :pointer) (value :bool))
(cffi:defcfun ("wlr_xwayland_surface_set_maximized" %xsurface-maximized) :void (surface :pointer) (horizontal :bool) (vertical :bool))
(cffi:defcfun ("wlr_xwayland_surface_set_minimized" %xsurface-minimized) :void (surface :pointer) (value :bool))

(defclass wlr-xwayland (native-object)
  ((surfaces :initform (make-hash-table :test #'eql) :reader %xwayland-surfaces)))
(defclass wlr-xwayland-surface (native-object)
  ((server :initarg :server :reader xwayland-surface-server)))
(defstruct (xwayland-configure (:constructor %make-xwayland-configure (x y width height mask)))
  (x 0 :read-only t) (y 0 :read-only t) (width 0 :read-only t)
  (height 0 :read-only t) (mask 0 :read-only t))

(defmacro %define-xwayland-sink (name &rest arguments)
  `(defgeneric ,name (sink ,@arguments)
     (:method ((sink runtime-sink) ,@arguments) (declare (ignore sink ,@arguments)))))
(%define-xwayland-sink xwayland-ready server)
(%define-xwayland-sink xwayland-destroying server)
(%define-xwayland-sink xwayland-new-surface server surface)
(%define-xwayland-sink xwayland-surface-associated surface)
(%define-xwayland-sink xwayland-surface-dissociated surface)
(%define-xwayland-sink xwayland-surface-destroying surface)
(%define-xwayland-sink xwayland-surface-title-changed surface)
(%define-xwayland-sink xwayland-surface-class-changed surface)
(%define-xwayland-sink xwayland-surface-geometry-changed surface)
(%define-xwayland-sink xwayland-surface-request-configure surface request)
(%define-xwayland-sink xwayland-surface-request-fullscreen surface value)
(%define-xwayland-sink xwayland-surface-request-maximize surface value)
(%define-xwayland-sink xwayland-surface-request-minimize surface value)
(%define-xwayland-sink xwayland-surface-request-move surface)
(%define-xwayland-sink xwayland-surface-request-resize surface edges)
(%define-xwayland-sink xwayland-surface-request-activate surface)

(defun %xwayland-pointer (object operation)
  (%assert-runtime-live (%native-runtime object) operation)
  (%object-pointer object))

(defmacro %define-xwayland-value (name field &optional boolean-p)
  `(defun ,name (surface)
     (let ((value (%xsurface-value (%xwayland-pointer surface ',name) ,field)))
       ,(if boolean-p '(not (zerop value)) 'value))))
(%define-xwayland-value xwayland-surface-x 0)
(%define-xwayland-value xwayland-surface-y 1)
(%define-xwayland-value xwayland-surface-width 2)
(%define-xwayland-value xwayland-surface-height 3)
(%define-xwayland-value xwayland-surface-override-redirect-p 4 t)
(defun xwayland-surface-title (surface)
  (%xsurface-text (%xwayland-pointer surface :xwayland-surface-title) 0))
(defun xwayland-surface-class (surface)
  (%xsurface-text (%xwayland-pointer surface :xwayland-surface-class) 1))
(defun xwayland-surface-parent (surface)
  (gethash (%pointer-key (%xsurface-parent (%xwayland-pointer surface :xwayland-surface-parent)))
           (%xwayland-surfaces (xwayland-surface-server surface))))
(defun xwayland-surface-surface (surface)
  (let ((pointer (%xsurface-surface (%xwayland-pointer surface :xwayland-surface-surface))))
    (unless (cffi:null-pointer-p pointer) (%adopt-core-surface (%native-runtime surface) pointer))))
(defun xwayland-surface-consider-map (surface)
  (%xsurface-consider-map (%xwayland-pointer surface :xwayland-surface-consider-map)))
(defun xwayland-display-name (server)
  (%xwayland-display (%xwayland-pointer server :xwayland-display-name)))
(defun xwayland-set-seat (server seat)
  (%assert-object-runtime (%native-runtime server) seat :xwayland-set-seat)
  (%xwayland-set-seat (%xwayland-pointer server :xwayland-set-seat) (%object-pointer seat)))
(defun xwayland-surface-configure (surface x y width height)
  (%xsurface-configure (%xwayland-pointer surface :xwayland-surface-configure) x y width height))
(defun xwayland-surface-activate (surface active)
  (%xsurface-activate (%xwayland-pointer surface :xwayland-surface-activate) (not (null active))))
(defun xwayland-surface-close (surface)
  (%xsurface-close (%xwayland-pointer surface :xwayland-surface-close)))
(defun xwayland-surface-set-fullscreen (surface value)
  (%xsurface-fullscreen (%xwayland-pointer surface :xwayland-surface-set-fullscreen) (not (null value))))
(defun xwayland-surface-set-maximized (surface value)
  (%xsurface-maximized (%xwayland-pointer surface :xwayland-surface-set-maximized) (not (null value)) (not (null value))))
(defun xwayland-surface-set-minimized (surface value)
  (%xsurface-minimized (%xwayland-pointer surface :xwayland-surface-set-minimized) (not (null value))))

(defun %adopt-xwayland-surface (server pointer)
  (let* ((runtime (%native-runtime server)) (sink (%runtime-sink runtime))
         (table (%xwayland-surfaces server)) (key (%pointer-key pointer))
         (surface (%wrap-pointer 'wlr-xwayland-surface pointer runtime :server server))
         (complete-p nil))
    (unwind-protect
         (progn
           (labels ((subscribe (event name callback)
                      (%attach-object-signal surface name (%xsurface-signal pointer event) callback))
                    (notify (event function)
                      (subscribe event function
                                 (lambda (data) (declare (ignore data)) (funcall function sink surface)))))
             (notify 0 'xwayland-surface-associated)
             (notify 1 'xwayland-surface-dissociated)
             (subscribe 2 :xwayland-surface-destroy
                        (lambda (data)
                          (declare (ignore data))
                          (unwind-protect (xwayland-surface-destroying sink surface)
                            (remhash key table)
                            (%retire-object-listeners surface :immediate-p t)
                            (%invalidate-native-object surface))))
             (subscribe 3 :xwayland-request-configure
                        (lambda (event)
                          (xwayland-surface-request-configure
                           sink surface (%make-xwayland-configure
                                         (%xconfigure-value event 0) (%xconfigure-value event 1)
                                         (%xconfigure-value event 2) (%xconfigure-value event 3)
                                         (%xconfigure-value event 4)))))
             (notify 4 'xwayland-surface-title-changed)
             (notify 5 'xwayland-surface-class-changed)
             (notify 6 'xwayland-surface-geometry-changed)
             (subscribe 7 :xwayland-request-fullscreen
                        (lambda (data) (declare (ignore data))
                          (xwayland-surface-request-fullscreen sink surface (not (zerop (%xsurface-value pointer 5))))))
             (subscribe 8 :xwayland-request-maximize
                        (lambda (data) (declare (ignore data))
                          (xwayland-surface-request-maximize sink surface (not (zerop (%xsurface-value pointer 6))))))
             (subscribe 9 :xwayland-request-minimize
                        (lambda (data) (xwayland-surface-request-minimize sink surface (%xminimize-value data))))
             (notify 10 'xwayland-surface-request-move)
             (subscribe 11 :xwayland-request-resize
                        (lambda (data) (xwayland-surface-request-resize sink surface (%xresize-edges data))))
             (notify 12 'xwayland-surface-request-activate))
           (setf (gethash key table) surface complete-p t)
           surface)
      (unless complete-p
        (%retire-object-listeners surface :immediate-p t)
        (%invalidate-native-object surface)))))

(defun %adopt-xwayland (runtime pointer)
  (let ((server (%wrap-pointer 'wlr-xwayland pointer runtime)) (complete-p nil))
    (unwind-protect
         (progn
           (%attach-object-signal server :xwayland-new-surface (%xwayland-signal pointer 0)
             (lambda (surface) (xwayland-new-surface (%runtime-sink runtime) server (%adopt-xwayland-surface server surface))))
           (%attach-object-signal server :xwayland-ready (%xwayland-signal pointer 1)
             (lambda (data) (declare (ignore data)) (xwayland-ready (%runtime-sink runtime) server)))
           (%attach-object-signal server :xwayland-destroy (%xwayland-signal pointer 2)
             (lambda (data)
               (declare (ignore data))
               (unwind-protect (xwayland-destroying (%runtime-sink runtime) server)
                 (%retire-object-listeners server :immediate-p t)
                 (%invalidate-native-object server)
                 (when (eq server (%runtime-xwayland runtime)) (setf (%runtime-xwayland runtime) nil)))))
           (setf (%runtime-xwayland runtime) server complete-p t)
           server)
      (unless complete-p
        (%retire-object-listeners server :immediate-p t)
        (%invalidate-native-object server)))))

(defun create-xwayland (runtime &key (lazy t))
  (%assert-runtime-live runtime :create-xwayland)
  (or (%runtime-xwayland runtime)
      (let ((pointer (%require-pointer
                      (%xwayland-create (%object-pointer (%runtime-display runtime))
                                        (%object-pointer (%runtime-compositor-global runtime)) lazy)
                      :create-xwayland))
            (complete-p nil))
        (unwind-protect
             (prog1 (%adopt-xwayland runtime pointer) (setf complete-p t))
          (unless complete-p (%xwayland-destroy pointer))))))

(defun destroy-xwayland (server)
  (%assert-owner-thread (%native-runtime server) :destroy-xwayland)
  (when (native-object-live-p server) (%xwayland-destroy (%object-pointer server))))

(defmethod runtime-stopping :after ((sink runtime-sink) runtime reason)
  (declare (ignore sink reason))
  (when (%runtime-xwayland runtime) (destroy-xwayland (%runtime-xwayland runtime))))
