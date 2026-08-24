;;;; XDG shell protocol bindings.
;;;;
;;;; This module owns the xdg_wm_base global, typed toplevel and popup wrappers,
;;;; exact request callbacks, and direct configure operations. Placement,
;;;; focus, movement, resize, and presentation decisions remain outside Runtime.

(in-package #:ataxia.runtime.raw)

(defcfun ("wlr_xdg_shell_create" %wlr-xdg-shell-create) :pointer
  (display :pointer)
  (version :uint32))
(defcfun ("wlr_xdg_surface_ping" %wlr-xdg-surface-ping) :void
  (surface :pointer))
(defcfun ("wlr_xdg_surface_surface_at" %wlr-xdg-surface-surface-at) :pointer
  (surface :pointer)
  (surface-x :double)
  (surface-y :double)
  (subsurface-x :pointer)
  (subsurface-y :pointer))
(defcfun ("wlr_xdg_surface_popup_surface_at"
          %wlr-xdg-surface-popup-surface-at)
    :pointer
  (surface :pointer)
  (surface-x :double)
  (surface-y :double)
  (subsurface-x :pointer)
  (subsurface-y :pointer))
(defcfun ("wlr_xdg_toplevel_set_size" %wlr-xdg-toplevel-set-size) :uint32
  (toplevel :pointer)
  (width :int32)
  (height :int32))
(defcfun ("wlr_xdg_toplevel_set_activated"
          %wlr-xdg-toplevel-set-activated)
    :uint32
  (toplevel :pointer)
  (activated :boolean))
(defcfun ("wlr_xdg_toplevel_set_maximized"
          %wlr-xdg-toplevel-set-maximized)
    :uint32
  (toplevel :pointer)
  (maximized :boolean))
(defcfun ("wlr_xdg_toplevel_set_fullscreen"
          %wlr-xdg-toplevel-set-fullscreen)
    :uint32
  (toplevel :pointer)
  (fullscreen :boolean))
(defcfun ("wlr_xdg_toplevel_set_resizing"
          %wlr-xdg-toplevel-set-resizing)
    :uint32
  (toplevel :pointer)
  (resizing :boolean))
(defcfun ("wlr_xdg_toplevel_set_tiled" %wlr-xdg-toplevel-set-tiled)
    :uint32
  (toplevel :pointer)
  (edges :uint32))
(defcfun ("wlr_xdg_toplevel_set_bounds" %wlr-xdg-toplevel-set-bounds)
    :uint32
  (toplevel :pointer)
  (width :int32)
  (height :int32))
(defcfun ("wlr_xdg_toplevel_set_wm_capabilities"
          %wlr-xdg-toplevel-set-wm-capabilities)
    :uint32
  (toplevel :pointer)
  (capabilities :uint32))
(defcfun ("wlr_xdg_toplevel_set_suspended"
          %wlr-xdg-toplevel-set-suspended)
    :uint32
  (toplevel :pointer)
  (suspended :boolean))
(defcfun ("wlr_xdg_toplevel_set_constrained"
          %wlr-xdg-toplevel-set-constrained)
    :uint32
  (toplevel :pointer)
  (edges :uint32))
(defcfun ("wlr_xdg_toplevel_send_close" %wlr-xdg-toplevel-send-close) :void
  (toplevel :pointer))
(defcfun ("wlr_xdg_popup_destroy" %wlr-xdg-popup-destroy) :void
  (popup :pointer))
(defcfun ("wlr_xdg_popup_get_position" %wlr-xdg-popup-get-position) :void
  (popup :pointer)
  (surface-x :pointer)
  (surface-y :pointer))
(defcfun ("wlr_xdg_surface_schedule_configure"
          %wlr-xdg-surface-schedule-configure)
    :uint32
  (surface :pointer))

(define-signal-binding %xdg-shell-event-new-toplevel
  "ataxia_xdg_shell_event_new_toplevel" shell)
(define-signal-binding %xdg-shell-event-new-popup
  "ataxia_xdg_shell_event_new_popup" shell)
(define-signal-binding %xdg-shell-event-destroy
  "ataxia_xdg_shell_event_destroy" shell)
(defcfun ("ataxia_xdg_toplevel_base" %xdg-toplevel-base) :pointer
  (toplevel :pointer))
(defcfun ("ataxia_xdg_surface_surface" %xdg-surface-surface) :pointer
  (surface :pointer))
(defcfun ("ataxia_xdg_surface_initial_commit" %xdg-surface-initial-commit)
    :boolean
  (surface :pointer))
(defcfun ("ataxia_xdg_surface_configured" %xdg-surface-configured) :boolean
  (surface :pointer))
(defcfun ("ataxia_xdg_surface_geometry" %xdg-surface-geometry) :boolean
  (surface :pointer)
  (geometry :pointer))
(define-signal-binding %xdg-surface-event-destroy
  "ataxia_xdg_surface_event_destroy" surface)
(defcfun ("ataxia_xdg_toplevel_title" %xdg-toplevel-title) :pointer
  (toplevel :pointer))
(defcfun ("ataxia_xdg_toplevel_app_id" %xdg-toplevel-app-id) :pointer
  (toplevel :pointer))
(defcfun ("ataxia_xdg_toplevel_requested_maximized"
          %xdg-toplevel-requested-maximized)
    :boolean
  (toplevel :pointer))
(defcfun ("ataxia_xdg_toplevel_requested_minimized"
          %xdg-toplevel-requested-minimized)
    :boolean
  (toplevel :pointer))
(defcfun ("ataxia_xdg_toplevel_requested_fullscreen"
          %xdg-toplevel-requested-fullscreen)
    :boolean
  (toplevel :pointer))
(defcfun ("ataxia_xdg_toplevel_requested_fullscreen_output"
          %xdg-toplevel-requested-fullscreen-output)
    :pointer
  (toplevel :pointer))
(define-signal-binding %xdg-toplevel-event-destroy
  "ataxia_xdg_toplevel_event_destroy" toplevel)
(define-signal-binding %xdg-toplevel-event-request-maximize
  "ataxia_xdg_toplevel_event_request_maximize" toplevel)
(define-signal-binding %xdg-toplevel-event-request-fullscreen
  "ataxia_xdg_toplevel_event_request_fullscreen" toplevel)
(define-signal-binding %xdg-toplevel-event-request-minimize
  "ataxia_xdg_toplevel_event_request_minimize" toplevel)
(define-signal-binding %xdg-toplevel-event-request-move
  "ataxia_xdg_toplevel_event_request_move" toplevel)
(define-signal-binding %xdg-toplevel-event-request-resize
  "ataxia_xdg_toplevel_event_request_resize" toplevel)
(define-signal-binding %xdg-toplevel-event-request-show-window-menu
  "ataxia_xdg_toplevel_event_request_show_window_menu" toplevel)
(define-signal-binding %xdg-toplevel-event-set-parent
  "ataxia_xdg_toplevel_event_set_parent" toplevel)
(define-signal-binding %xdg-toplevel-event-set-title
  "ataxia_xdg_toplevel_event_set_title" toplevel)
(define-signal-binding %xdg-toplevel-event-set-app-id
  "ataxia_xdg_toplevel_event_set_app_id" toplevel)
(defcfun ("ataxia_xdg_move_seat" %xdg-move-seat) :pointer
  (event :pointer))
(defcfun ("ataxia_xdg_move_serial" %xdg-move-serial) :uint32
  (event :pointer))
(defcfun ("ataxia_xdg_resize_seat" %xdg-resize-seat) :pointer
  (event :pointer))
(defcfun ("ataxia_xdg_resize_serial" %xdg-resize-serial) :uint32
  (event :pointer))
(defcfun ("ataxia_xdg_resize_edges" %xdg-resize-edges) :uint32
  (event :pointer))
(defcfun ("ataxia_xdg_window_menu_seat" %xdg-window-menu-seat) :pointer
  (event :pointer))
(defcfun ("ataxia_xdg_window_menu_serial" %xdg-window-menu-serial) :uint32
  (event :pointer))
(defcfun ("ataxia_xdg_window_menu_x" %xdg-window-menu-x) :int32
  (event :pointer))
(defcfun ("ataxia_xdg_window_menu_y" %xdg-window-menu-y) :int32
  (event :pointer))
(defcfun ("ataxia_xdg_popup_base" %xdg-popup-base) :pointer
  (popup :pointer))
(defcfun ("ataxia_xdg_popup_parent_surface" %xdg-popup-parent-surface)
    :pointer
  (popup :pointer))
(define-signal-binding %xdg-popup-event-destroy
  "ataxia_xdg_popup_event_destroy" popup)
(define-signal-binding %xdg-popup-event-reposition
  "ataxia_xdg_popup_event_reposition" popup)

(in-package #:ataxia.runtime)

(defconstant +xdg-shell-version+ 6)

(defclass wlr-xdg-shell (native-object) ())

(defclass wlr-xdg-surface (native-object)
  ((surface :initarg :surface :reader %xdg-surface-core-surface)))

(defclass wlr-xdg-toplevel (native-object)
  ((base :initarg :base :reader %xdg-toplevel-base-object)
   (surface :initarg :surface :reader xdg-toplevel-surface)
   (initialized-p :initform nil :accessor xdg-toplevel-initialized-p)
   (title :initform nil :accessor xdg-toplevel-title)
   (app-id :initform nil :accessor xdg-toplevel-app-id)))

(defclass wlr-xdg-popup (native-object)
  ((base :initarg :base :reader %xdg-popup-base-object)
   (surface :initarg :surface :reader xdg-popup-surface)
   (parent-surface :initarg :parent-surface
                   :reader xdg-popup-parent-surface)))

(defstruct (xdg-move-event
             (:constructor %make-xdg-move-event
                 (&key toplevel seat serial))
             (:conc-name xdg-move-))
  (toplevel nil :type wlr-xdg-toplevel :read-only t)
  (seat nil :type wlr-seat :read-only t)
  (serial 0 :type (unsigned-byte 32) :read-only t))

(defstruct (xdg-resize-event
             (:constructor %make-xdg-resize-event
                 (&key toplevel seat serial edges))
             (:conc-name xdg-resize-))
  (toplevel nil :type wlr-xdg-toplevel :read-only t)
  (seat nil :type wlr-seat :read-only t)
  (serial 0 :type (unsigned-byte 32) :read-only t)
  (edges 0 :type (unsigned-byte 32) :read-only t))

(defstruct (xdg-window-menu-event
             (:constructor %make-xdg-window-menu-event
                 (&key toplevel seat serial x y))
             (:conc-name xdg-window-menu-))
  (toplevel nil :type wlr-xdg-toplevel :read-only t)
  (seat nil :type wlr-seat :read-only t)
  (serial 0 :type (unsigned-byte 32) :read-only t)
  (x 0 :type (signed-byte 32) :read-only t)
  (y 0 :type (signed-byte 32) :read-only t))

(defstruct (xdg-fullscreen-request
             (:constructor %make-xdg-fullscreen-request
                 (&key toplevel requested-p output))
             (:conc-name xdg-fullscreen-))
  (toplevel nil :type wlr-xdg-toplevel :read-only t)
  (requested-p nil :type boolean :read-only t)
  (output nil :type (or null wlr-output) :read-only t))

(defgeneric xdg-new-toplevel (sink toplevel))
(defgeneric xdg-new-popup (sink popup))
(defgeneric xdg-toplevel-mapped (sink toplevel))
(defgeneric xdg-toplevel-unmapped (sink toplevel))
(defgeneric xdg-toplevel-committed
    (sink toplevel commit initial-commit-p configured-p))
(defgeneric xdg-toplevel-destroying (sink toplevel))
(defgeneric xdg-toplevel-request-move (sink event))
(defgeneric xdg-toplevel-request-resize (sink event))
(defgeneric xdg-toplevel-request-maximize (sink toplevel requested-p))
(defgeneric xdg-toplevel-request-minimize (sink toplevel requested-p))
(defgeneric xdg-toplevel-request-fullscreen (sink request))
(defgeneric xdg-toplevel-request-show-window-menu (sink event))
(defgeneric xdg-toplevel-parent-changed (sink toplevel))
(defgeneric xdg-toplevel-title-changed (sink toplevel title))
(defgeneric xdg-toplevel-app-id-changed (sink toplevel app-id))
(defgeneric xdg-popup-mapped (sink popup))
(defgeneric xdg-popup-unmapped (sink popup))
(defgeneric xdg-popup-committed
    (sink popup commit initial-commit-p configured-p))
(defgeneric xdg-popup-repositioned (sink popup))
(defgeneric xdg-popup-destroying (sink popup))

(defmethod xdg-new-toplevel ((sink runtime-sink) toplevel)
  (declare (ignore sink toplevel)))
(defmethod xdg-new-popup ((sink runtime-sink) popup)
  (declare (ignore sink popup)))
(defmethod xdg-toplevel-mapped ((sink runtime-sink) toplevel)
  (declare (ignore sink toplevel)))
(defmethod xdg-toplevel-unmapped ((sink runtime-sink) toplevel)
  (declare (ignore sink toplevel)))
(defmethod xdg-toplevel-committed
    ((sink runtime-sink) toplevel commit initial-commit-p configured-p)
  (declare (ignore sink toplevel commit initial-commit-p configured-p)))
(defmethod xdg-toplevel-destroying ((sink runtime-sink) toplevel)
  (declare (ignore sink toplevel)))
(defmethod xdg-toplevel-request-move ((sink runtime-sink) event)
  (declare (ignore sink event)))
(defmethod xdg-toplevel-request-resize ((sink runtime-sink) event)
  (declare (ignore sink event)))
(defmethod xdg-toplevel-request-maximize
    ((sink runtime-sink) toplevel requested-p)
  (declare (ignore sink toplevel requested-p)))
(defmethod xdg-toplevel-request-minimize
    ((sink runtime-sink) toplevel requested-p)
  (declare (ignore sink toplevel requested-p)))
(defmethod xdg-toplevel-request-fullscreen ((sink runtime-sink) request)
  (declare (ignore sink request)))
(defmethod xdg-toplevel-request-show-window-menu
    ((sink runtime-sink) event)
  (declare (ignore sink event)))
(defmethod xdg-toplevel-parent-changed ((sink runtime-sink) toplevel)
  (declare (ignore sink toplevel)))
(defmethod xdg-toplevel-title-changed ((sink runtime-sink) toplevel title)
  (declare (ignore sink toplevel title)))
(defmethod xdg-toplevel-app-id-changed ((sink runtime-sink) toplevel app-id)
  (declare (ignore sink toplevel app-id)))
(defmethod xdg-popup-mapped ((sink runtime-sink) popup)
  (declare (ignore sink popup)))
(defmethod xdg-popup-unmapped ((sink runtime-sink) popup)
  (declare (ignore sink popup)))
(defmethod xdg-popup-committed
    ((sink runtime-sink) popup commit initial-commit-p configured-p)
  (declare (ignore sink popup commit initial-commit-p configured-p)))
(defmethod xdg-popup-repositioned ((sink runtime-sink) popup)
  (declare (ignore sink popup)))
(defmethod xdg-popup-destroying ((sink runtime-sink) popup)
  (declare (ignore sink popup)))

(defmethod xdg-new-toplevel ((sink diagnostic-sink) toplevel)
  (%diagnostic-line sink "[runtime] xdg-new-toplevel app-id=~A title=~A"
                    (or (xdg-toplevel-app-id toplevel) "none")
                    (or (xdg-toplevel-title toplevel) "none")))

(defmethod xdg-new-popup ((sink diagnostic-sink) popup)
  (%diagnostic-line sink "[runtime] xdg-new-popup address=~X"
                    (native-object-address popup)))

(defmethod xdg-toplevel-destroying ((sink diagnostic-sink) toplevel)
  (%diagnostic-line sink "[runtime] xdg-toplevel-destroy app-id=~A"
                    (or (xdg-toplevel-app-id toplevel) "none")))

(defmethod xdg-toplevel-committed
    ((sink diagnostic-sink) toplevel commit initial-commit-p configured-p)
  (when (and initial-commit-p (not configured-p))
    (xdg-toplevel-set-size toplevel 900 700))
  (when (surface-commit-mapped-p commit)
    (let ((buffer (retain-surface-buffer (xdg-toplevel-surface toplevel))))
      (when buffer
        (unwind-protect
             (let ((texture (buffer-texture buffer)))
               (when texture
                 (let ((attributes (texture-gles-attributes texture)))
                   (%diagnostic-line
                    sink
                    "[runtime] xdg-buffer size=~Dx~D texture=~D target=0x~X alpha=~A"
                    (buffer-width buffer) (buffer-height buffer)
                    (gles-texture-name attributes)
                    (gles-texture-target attributes)
                    (gles-texture-has-alpha-p attributes)))))
          (release-buffer buffer)))))
  commit)

(defmethod xdg-popup-destroying ((sink diagnostic-sink) popup)
  (%diagnostic-line sink "[runtime] xdg-popup-destroy address=~X"
                    (native-object-address popup)))

(defun runtime-xdg-shell (runtime)
  (%runtime-xdg-shell runtime))

(defun runtime-xdg-toplevels (runtime)
  (%hash-values (%runtime-xdg-toplevel-table runtime)))

(defun runtime-xdg-popups (runtime)
  (%hash-values (%runtime-xdg-popup-table runtime)))

(defun %lookup-runtime-object (table pointer operation)
  (unless (ataxia.runtime.raw:null-pointer-p pointer)
    (or (gethash (%pointer-key pointer) table)
        (error 'native-call-failed :name operation
               :detail "unregistered native object"))))

(defun %refresh-xdg-toplevel (toplevel)
  (let ((pointer (%object-pointer toplevel)))
    (setf (xdg-toplevel-title toplevel)
          (%copy-native-string
           (ataxia.runtime.raw:%xdg-toplevel-title pointer))
          (xdg-toplevel-app-id toplevel)
          (%copy-native-string
           (ataxia.runtime.raw:%xdg-toplevel-app-id pointer))))
  toplevel)

(defun %xdg-commit-state (base)
  (let ((pointer (%object-pointer base)))
    (values (ataxia.runtime.raw:%xdg-surface-initial-commit pointer)
            (ataxia.runtime.raw:%xdg-surface-configured pointer))))

(defun %attach-xdg-surface-lifecycle
    (runtime role base surface mapped-callback unmapped-callback
     committed-callback)
  (let ((surface-pointer (%object-pointer surface)))
    (%attach-object-signal
     role :xdg-surface-map
     (ataxia.runtime.raw:%surface-event-map surface-pointer)
     (lambda (data)
       (declare (ignore data))
       (funcall mapped-callback)))
    (%attach-object-signal
     role :xdg-surface-unmap
     (ataxia.runtime.raw:%surface-event-unmap surface-pointer)
     (lambda (data)
       (declare (ignore data))
       (funcall unmapped-callback)))
    (%attach-object-signal
     role :xdg-surface-commit
     (ataxia.runtime.raw:%surface-event-commit surface-pointer)
     (lambda (data)
       (declare (ignore data))
       (multiple-value-bind (initial-commit-p configured-p)
           (%xdg-commit-state base)
         (funcall committed-callback
                  (%surface-commit-snapshot surface)
                  initial-commit-p configured-p))))
  runtime))

(defun %adopt-xdg-base (runtime pointer core-surface)
  (let ((base (%wrap-pointer 'wlr-xdg-surface pointer runtime
                             :surface core-surface)))
    (%attach-object-signal
     base :xdg-surface-destroy
     (ataxia.runtime.raw:%xdg-surface-event-destroy pointer)
     (lambda (data)
       (declare (ignore data))
       (%retire-object-listeners base :immediate-p t)
       (%invalidate-native-object base)))
    base))

(defun %request-seat (runtime pointer operation)
  (%lookup-runtime-object (%runtime-seat-table runtime) pointer operation))

(defun %handle-xdg-new-toplevel (runtime pointer)
  (let ((key (%pointer-key pointer)))
    (unless (gethash key (%runtime-xdg-toplevel-table runtime))
      (let* ((base-pointer
               (%require-pointer
                (ataxia.runtime.raw:%xdg-toplevel-base pointer)
                :xdg-toplevel-base))
             (surface-pointer
               (%require-pointer
                (ataxia.runtime.raw:%xdg-surface-surface base-pointer)
                :xdg-surface-surface))
             (surface (%adopt-core-surface runtime surface-pointer))
             (base (%adopt-xdg-base runtime base-pointer surface))
             (toplevel
               (%refresh-xdg-toplevel
                (%wrap-pointer 'wlr-xdg-toplevel pointer runtime
                               :base base :surface surface)))
             (sink (%runtime-sink runtime)))
        (setf (gethash key (%runtime-xdg-toplevel-table runtime)) toplevel)
        (%attach-xdg-surface-lifecycle
         runtime toplevel base surface
         (lambda () (xdg-toplevel-mapped sink toplevel))
         (lambda () (xdg-toplevel-unmapped sink toplevel))
         (lambda (commit initial-commit-p configured-p)
           (when initial-commit-p
             (setf (xdg-toplevel-initialized-p toplevel) t))
           (xdg-toplevel-committed sink toplevel commit
                                    initial-commit-p configured-p)))
        (%attach-object-signal
         toplevel :xdg-toplevel-destroy
         (ataxia.runtime.raw:%xdg-toplevel-event-destroy pointer)
         (lambda (data)
           (declare (ignore data))
           (unwind-protect
                (xdg-toplevel-destroying sink toplevel)
             (%retire-object-listeners toplevel :immediate-p t)
             (%invalidate-native-object toplevel)
             (remhash key (%runtime-xdg-toplevel-table runtime)))))
        (%attach-object-signal
         toplevel :xdg-toplevel-request-move
         (ataxia.runtime.raw:%xdg-toplevel-event-request-move pointer)
         (lambda (event-pointer)
           (xdg-toplevel-request-move
            sink
            (%make-xdg-move-event
             :toplevel toplevel
             :seat (%request-seat
                    runtime
                    (ataxia.runtime.raw:%xdg-move-seat event-pointer)
                    :xdg-request-move)
             :serial
             (ataxia.runtime.raw:%xdg-move-serial event-pointer)))))
        (%attach-object-signal
         toplevel :xdg-toplevel-request-resize
         (ataxia.runtime.raw:%xdg-toplevel-event-request-resize pointer)
         (lambda (event-pointer)
           (xdg-toplevel-request-resize
            sink
            (%make-xdg-resize-event
             :toplevel toplevel
             :seat (%request-seat
                    runtime
                    (ataxia.runtime.raw:%xdg-resize-seat event-pointer)
                    :xdg-request-resize)
             :serial
             (ataxia.runtime.raw:%xdg-resize-serial event-pointer)
             :edges
             (ataxia.runtime.raw:%xdg-resize-edges event-pointer)))))
        (%attach-object-signal
         toplevel :xdg-toplevel-request-maximize
         (ataxia.runtime.raw:%xdg-toplevel-event-request-maximize pointer)
         (lambda (data)
           (declare (ignore data))
           (xdg-toplevel-request-maximize
            sink toplevel
            (ataxia.runtime.raw:%xdg-toplevel-requested-maximized pointer))))
        (%attach-object-signal
         toplevel :xdg-toplevel-request-minimize
         (ataxia.runtime.raw:%xdg-toplevel-event-request-minimize pointer)
         (lambda (data)
           (declare (ignore data))
           (xdg-toplevel-request-minimize
            sink toplevel
            (ataxia.runtime.raw:%xdg-toplevel-requested-minimized pointer))))
        (%attach-object-signal
         toplevel :xdg-toplevel-request-fullscreen
         (ataxia.runtime.raw:%xdg-toplevel-event-request-fullscreen pointer)
         (lambda (data)
           (declare (ignore data))
           (let ((output-pointer
                   (ataxia.runtime.raw:%xdg-toplevel-requested-fullscreen-output
                    pointer)))
             (xdg-toplevel-request-fullscreen
              sink
              (%make-xdg-fullscreen-request
               :toplevel toplevel
               :requested-p
               (ataxia.runtime.raw:%xdg-toplevel-requested-fullscreen pointer)
               :output
               (unless (ataxia.runtime.raw:null-pointer-p output-pointer)
                 (%lookup-runtime-object
                  (%runtime-output-table runtime) output-pointer
                  :xdg-request-fullscreen)))))))
        (%attach-object-signal
         toplevel :xdg-toplevel-request-show-window-menu
         (ataxia.runtime.raw:%xdg-toplevel-event-request-show-window-menu
          pointer)
         (lambda (event-pointer)
           (xdg-toplevel-request-show-window-menu
            sink
            (%make-xdg-window-menu-event
             :toplevel toplevel
             :seat (%request-seat
                    runtime
                    (ataxia.runtime.raw:%xdg-window-menu-seat event-pointer)
                    :xdg-request-show-window-menu)
             :serial
             (ataxia.runtime.raw:%xdg-window-menu-serial event-pointer)
             :x (ataxia.runtime.raw:%xdg-window-menu-x event-pointer)
             :y (ataxia.runtime.raw:%xdg-window-menu-y event-pointer)))))
        (%attach-object-signal
         toplevel :xdg-toplevel-set-parent
         (ataxia.runtime.raw:%xdg-toplevel-event-set-parent pointer)
         (lambda (data)
           (declare (ignore data))
           (xdg-toplevel-parent-changed sink toplevel)))
        (%attach-object-signal
         toplevel :xdg-toplevel-set-title
         (ataxia.runtime.raw:%xdg-toplevel-event-set-title pointer)
         (lambda (data)
           (declare (ignore data))
           (%refresh-xdg-toplevel toplevel)
           (xdg-toplevel-title-changed
            sink toplevel (xdg-toplevel-title toplevel))))
        (%attach-object-signal
         toplevel :xdg-toplevel-set-app-id
         (ataxia.runtime.raw:%xdg-toplevel-event-set-app-id pointer)
         (lambda (data)
           (declare (ignore data))
           (%refresh-xdg-toplevel toplevel)
           (xdg-toplevel-app-id-changed
            sink toplevel (xdg-toplevel-app-id toplevel))))
        (xdg-new-toplevel sink toplevel)))))

(defun %handle-xdg-new-popup (runtime pointer)
  (let ((key (%pointer-key pointer)))
    (unless (gethash key (%runtime-xdg-popup-table runtime))
      (let* ((base-pointer
               (%require-pointer
                (ataxia.runtime.raw:%xdg-popup-base pointer)
                :xdg-popup-base))
             (surface-pointer
               (%require-pointer
                (ataxia.runtime.raw:%xdg-surface-surface base-pointer)
                :xdg-surface-surface))
             (parent-pointer
               (ataxia.runtime.raw:%xdg-popup-parent-surface pointer))
             (surface (%adopt-core-surface runtime surface-pointer))
             (parent
               (unless (ataxia.runtime.raw:null-pointer-p parent-pointer)
                 (%adopt-core-surface runtime parent-pointer)))
             (base (%adopt-xdg-base runtime base-pointer surface))
             (popup
               (%wrap-pointer 'wlr-xdg-popup pointer runtime
                              :base base :surface surface
                              :parent-surface parent))
             (sink (%runtime-sink runtime)))
        (setf (gethash key (%runtime-xdg-popup-table runtime)) popup)
        (%attach-xdg-surface-lifecycle
         runtime popup base surface
         (lambda () (xdg-popup-mapped sink popup))
         (lambda () (xdg-popup-unmapped sink popup))
         (lambda (commit initial-commit-p configured-p)
           (xdg-popup-committed sink popup commit
                                initial-commit-p configured-p)))
        (%attach-object-signal
         popup :xdg-popup-reposition
         (ataxia.runtime.raw:%xdg-popup-event-reposition pointer)
         (lambda (data)
           (declare (ignore data))
           (xdg-popup-repositioned sink popup)))
        (%attach-object-signal
         popup :xdg-popup-destroy
         (ataxia.runtime.raw:%xdg-popup-event-destroy pointer)
         (lambda (data)
           (declare (ignore data))
           (unwind-protect
                (xdg-popup-destroying sink popup)
             (%retire-object-listeners popup :immediate-p t)
             (%invalidate-native-object popup)
             (remhash key (%runtime-xdg-popup-table runtime)))))
        (xdg-new-popup sink popup)))))

(defun create-xdg-shell (runtime &key (version +xdg-shell-version+))
  (%assert-runtime-live runtime :create-xdg-shell)
  (check-type version (integer 1))
  (when (%runtime-xdg-shell runtime)
    (error 'native-call-failed
           :name :create-xdg-shell :detail "XDG shell already exists"))
  (let* ((pointer
           (%require-pointer
            (ataxia.runtime.raw:%wlr-xdg-shell-create
             (%object-pointer (%runtime-display runtime)) version)
            :wlr-xdg-shell-create))
         (shell (%wrap-pointer 'wlr-xdg-shell pointer runtime)))
    (setf (%runtime-xdg-shell runtime) shell)
    (%attach-object-signal
     shell :xdg-shell-new-toplevel
     (ataxia.runtime.raw:%xdg-shell-event-new-toplevel pointer)
     (lambda (toplevel-pointer)
       (%handle-xdg-new-toplevel runtime toplevel-pointer)))
    (%attach-object-signal
     shell :xdg-shell-new-popup
     (ataxia.runtime.raw:%xdg-shell-event-new-popup pointer)
     (lambda (popup-pointer)
       (%handle-xdg-new-popup runtime popup-pointer)))
    (%attach-object-signal
     shell :xdg-shell-destroy
     (ataxia.runtime.raw:%xdg-shell-event-destroy pointer)
     (lambda (data)
       (declare (ignore data))
       (%retire-object-listeners shell :immediate-p t)
       (%invalidate-native-object shell)
       (setf (%runtime-xdg-shell runtime) nil)))
    shell))

(defun %xdg-base-pointer (object)
  (etypecase object
    (wlr-xdg-surface (%object-pointer object))
    (wlr-xdg-toplevel
     (%object-pointer (%xdg-toplevel-base-object object)))
    (wlr-xdg-popup
     (%object-pointer (%xdg-popup-base-object object)))))

(defun xdg-surface-ping (object)
  (let ((runtime (%native-runtime object)))
    (%assert-runtime-live runtime :xdg-surface-ping)
    (ataxia.runtime.raw:%wlr-xdg-surface-ping (%xdg-base-pointer object)))
  object)

(defun xdg-surface-geometry (object)
  (let ((runtime (%native-runtime object)))
    (%assert-runtime-live runtime :xdg-surface-geometry)
    (cffi:with-foreign-object (geometry :int32 4)
      (when (ataxia.runtime.raw:%xdg-surface-geometry
             (%xdg-base-pointer object) geometry)
        (values (cffi:mem-aref geometry :int32 0)
                (cffi:mem-aref geometry :int32 1)
                (cffi:mem-aref geometry :int32 2)
                (cffi:mem-aref geometry :int32 3))))))

(defun %xdg-surface-at (object surface-x surface-y function operation)
  (let ((runtime (%native-runtime object)))
    (%assert-runtime-live runtime operation)
    (cffi:with-foreign-objects ((subsurface-x :double)
                                (subsurface-y :double))
      (let ((pointer
              (funcall function
                       (%xdg-base-pointer object)
                       (coerce surface-x 'double-float)
                       (coerce surface-y 'double-float)
                       subsurface-x subsurface-y)))
        (unless (ataxia.runtime.raw:null-pointer-p pointer)
          (values (%adopt-core-surface runtime pointer)
                  (cffi:mem-ref subsurface-x :double)
                  (cffi:mem-ref subsurface-y :double)))))))

(defun xdg-surface-at (object surface-x surface-y)
  (%xdg-surface-at
   object surface-x surface-y
   #'ataxia.runtime.raw:%wlr-xdg-surface-surface-at
   :xdg-surface-at))

(defun xdg-popup-surface-at (object surface-x surface-y)
  (%xdg-surface-at
   object surface-x surface-y
   #'ataxia.runtime.raw:%wlr-xdg-surface-popup-surface-at
   :xdg-popup-surface-at))

(defun %call-xdg-toplevel-serial (toplevel operation function &rest arguments)
  (check-type toplevel wlr-xdg-toplevel)
  (%assert-runtime-live (%native-runtime toplevel) operation)
  (apply function (%object-pointer toplevel) arguments))

(defun xdg-toplevel-set-size (toplevel width height)
  (check-type width (signed-byte 32))
  (check-type height (signed-byte 32))
  (%call-xdg-toplevel-serial
   toplevel :xdg-toplevel-set-size
   #'ataxia.runtime.raw:%wlr-xdg-toplevel-set-size width height))

(defun xdg-toplevel-set-activated (toplevel activated-p)
  (%call-xdg-toplevel-serial
   toplevel :xdg-toplevel-set-activated
   #'ataxia.runtime.raw:%wlr-xdg-toplevel-set-activated
   (not (null activated-p))))

(defun xdg-toplevel-set-maximized (toplevel maximized-p)
  (%call-xdg-toplevel-serial
   toplevel :xdg-toplevel-set-maximized
   #'ataxia.runtime.raw:%wlr-xdg-toplevel-set-maximized
   (not (null maximized-p))))

(defun xdg-toplevel-set-fullscreen (toplevel fullscreen-p)
  (%call-xdg-toplevel-serial
   toplevel :xdg-toplevel-set-fullscreen
   #'ataxia.runtime.raw:%wlr-xdg-toplevel-set-fullscreen
   (not (null fullscreen-p))))

(defun xdg-toplevel-set-resizing (toplevel resizing-p)
  (%call-xdg-toplevel-serial
   toplevel :xdg-toplevel-set-resizing
   #'ataxia.runtime.raw:%wlr-xdg-toplevel-set-resizing
   (not (null resizing-p))))

(defun xdg-toplevel-set-tiled (toplevel edges)
  (check-type edges (unsigned-byte 32))
  (%call-xdg-toplevel-serial
   toplevel :xdg-toplevel-set-tiled
   #'ataxia.runtime.raw:%wlr-xdg-toplevel-set-tiled edges))

(defun xdg-toplevel-set-bounds (toplevel width height)
  (check-type width (signed-byte 32))
  (check-type height (signed-byte 32))
  (%call-xdg-toplevel-serial
   toplevel :xdg-toplevel-set-bounds
   #'ataxia.runtime.raw:%wlr-xdg-toplevel-set-bounds width height))

(defun xdg-toplevel-set-wm-capabilities (toplevel capabilities)
  (check-type capabilities (unsigned-byte 32))
  (%call-xdg-toplevel-serial
   toplevel :xdg-toplevel-set-wm-capabilities
   #'ataxia.runtime.raw:%wlr-xdg-toplevel-set-wm-capabilities capabilities))

(defun xdg-toplevel-set-suspended (toplevel suspended-p)
  (%call-xdg-toplevel-serial
   toplevel :xdg-toplevel-set-suspended
   #'ataxia.runtime.raw:%wlr-xdg-toplevel-set-suspended
   (not (null suspended-p))))

(defun xdg-toplevel-set-constrained (toplevel edges)
  (check-type edges (unsigned-byte 32))
  (%call-xdg-toplevel-serial
   toplevel :xdg-toplevel-set-constrained
   #'ataxia.runtime.raw:%wlr-xdg-toplevel-set-constrained edges))

(defun xdg-toplevel-send-close (toplevel)
  (check-type toplevel wlr-xdg-toplevel)
  (%assert-runtime-live (%native-runtime toplevel) :xdg-toplevel-send-close)
  (ataxia.runtime.raw:%wlr-xdg-toplevel-send-close
   (%object-pointer toplevel))
  toplevel)

(defun xdg-popup-destroy (popup)
  (check-type popup wlr-xdg-popup)
  (%assert-runtime-live (%native-runtime popup) :xdg-popup-destroy)
  (ataxia.runtime.raw:%wlr-xdg-popup-destroy (%object-pointer popup))
  (%run-safe-point-actions (%native-runtime popup))
  nil)

(defun xdg-popup-position (popup)
  (check-type popup wlr-xdg-popup)
  (%assert-runtime-live (%native-runtime popup) :xdg-popup-position)
  (cffi:with-foreign-objects ((surface-x :double) (surface-y :double))
    (ataxia.runtime.raw:%wlr-xdg-popup-get-position
     (%object-pointer popup) surface-x surface-y)
    (values (cffi:mem-ref surface-x :double)
            (cffi:mem-ref surface-y :double))))

(defun xdg-surface-schedule-configure (object)
  (unless (typep object '(or wlr-xdg-toplevel wlr-xdg-popup))
    (error 'type-error
           :datum object
           :expected-type '(or wlr-xdg-toplevel wlr-xdg-popup)))
  (%assert-runtime-live
   (%native-runtime object) :xdg-surface-schedule-configure)
  (ataxia.runtime.raw:%wlr-xdg-surface-schedule-configure
   (%xdg-base-pointer object)))
