;;;; XDG desktop interoperability protocols.
;;;;
;;;; Decoration and activation requests remain exact Wayland operations. This
;;;; module copies transient request data into typed Lisp values and delegates
;;;; every policy decision to the Runtime sink.

(in-package #:ataxia.runtime.raw)

(defcfun ("wlr_xdg_decoration_manager_v1_create"
          %wlr-xdg-decoration-manager-v1-create) :pointer
  (display :pointer))
(defcfun ("wlr_xdg_toplevel_decoration_v1_set_mode"
          %wlr-xdg-toplevel-decoration-v1-set-mode) :uint32
  (decoration :pointer)
  (mode :uint32))
(defcfun ("wlr_xdg_activation_v1_create" %wlr-xdg-activation-v1-create)
    :pointer
  (display :pointer))

(define-signal-binding %xdg-decoration-manager-event-new-toplevel
  "ataxia_xdg_decoration_manager_event_new_toplevel" manager)
(define-signal-binding %xdg-decoration-manager-event-destroy
  "ataxia_xdg_decoration_manager_event_destroy" manager)
(define-signal-binding %xdg-toplevel-decoration-event-request-mode
  "ataxia_xdg_toplevel_decoration_event_request_mode" decoration)
(define-signal-binding %xdg-toplevel-decoration-event-destroy
  "ataxia_xdg_toplevel_decoration_event_destroy" decoration)
(defcfun ("ataxia_xdg_toplevel_decoration_toplevel"
          %xdg-toplevel-decoration-toplevel) :pointer
  (decoration :pointer))
(defcfun ("ataxia_xdg_toplevel_decoration_requested_mode"
          %xdg-toplevel-decoration-requested-mode) :uint32
  (decoration :pointer))

(define-signal-binding %xdg-activation-event-request-activate
  "ataxia_xdg_activation_event_request_activate" activation)
(define-signal-binding %xdg-activation-event-destroy
  "ataxia_xdg_activation_event_destroy" activation)
(defcfun ("ataxia_xdg_activation_request_surface"
          %xdg-activation-request-surface) :pointer
  (event :pointer))
(defcfun ("ataxia_xdg_activation_request_token"
          %xdg-activation-request-token) :pointer
  (event :pointer))
(defcfun ("ataxia_xdg_activation_token_surface"
          %xdg-activation-token-surface) :pointer
  (token :pointer))
(defcfun ("ataxia_xdg_activation_token_seat"
          %xdg-activation-token-seat) :pointer
  (token :pointer))
(defcfun ("ataxia_xdg_activation_token_serial"
          %xdg-activation-token-serial) :uint32
  (token :pointer))
(defcfun ("ataxia_xdg_activation_token_app_id"
          %xdg-activation-token-app-id) :pointer
  (token :pointer))

(in-package #:ataxia.runtime)

(defclass wlr-xdg-decoration-manager-v1 (native-object) ())

(defclass wlr-xdg-toplevel-decoration-v1 (native-object)
  ((toplevel :initarg :toplevel :reader xdg-decoration-toplevel)
   (requested-mode :initform :none :accessor xdg-decoration-requested-mode)))

(defclass wlr-xdg-activation-v1 (native-object) ())

(defstruct (xdg-activation-request
             (:constructor %make-xdg-activation-request
                 (&key target-surface source-surface seat serial app-id)))
  target-surface source-surface seat
  (serial 0 :type (unsigned-byte 32) :read-only t)
  app-id)

(defgeneric xdg-new-toplevel-decoration (sink runtime decoration))
(defgeneric xdg-toplevel-decoration-request-mode (sink decoration))
(defgeneric xdg-toplevel-decoration-destroying (sink decoration))
(defgeneric xdg-activation-requested (sink runtime request))

(defmethod xdg-new-toplevel-decoration
    ((sink runtime-sink) runtime decoration)
  (declare (ignore runtime decoration))
  nil)
(defmethod xdg-toplevel-decoration-request-mode
    ((sink runtime-sink) decoration)
  (declare (ignore decoration))
  nil)
(defmethod xdg-toplevel-decoration-destroying
    ((sink runtime-sink) decoration)
  (declare (ignore decoration))
  nil)
(defmethod xdg-activation-requested
    ((sink runtime-sink) runtime request)
  (declare (ignore runtime request))
  nil)

(defun runtime-xdg-decoration-manager (runtime)
  (%runtime-xdg-decoration-manager runtime))

(defun runtime-xdg-decorations (runtime)
  (%hash-values (%runtime-xdg-decoration-table runtime)))

(defun find-xdg-toplevel-decoration (runtime toplevel)
  (find toplevel (runtime-xdg-decorations runtime)
        :key #'xdg-decoration-toplevel :test #'eq))

(defun runtime-xdg-activation (runtime)
  (%runtime-xdg-activation runtime))

(defun decoration-mode-keyword (mode)
  (case mode
    (1 :client-side)
    (2 :server-side)
    (otherwise :none)))

(defun refresh-xdg-decoration (decoration)
  (setf (xdg-decoration-requested-mode decoration)
        (decoration-mode-keyword
         (ataxia.runtime.raw:%xdg-toplevel-decoration-requested-mode
          (%object-pointer decoration))))
  decoration)

(defun retire-xdg-decoration (runtime decoration)
  (%retire-object-listeners decoration :immediate-p t)
  (remhash (native-object-address decoration)
           (%runtime-xdg-decoration-table runtime))
  (%invalidate-native-object decoration)
  decoration)

(defun handle-new-xdg-decoration (runtime pointer)
  (let* ((toplevel-pointer
           (ataxia.runtime.raw:%xdg-toplevel-decoration-toplevel pointer))
         (toplevel
           (gethash (%pointer-key toplevel-pointer)
                    (%runtime-xdg-toplevel-table runtime))))
    (unless toplevel
      (error 'native-call-failed
             :name :xdg-decoration-toplevel :detail "unknown toplevel"))
    (let ((decoration
            (%wrap-pointer 'wlr-xdg-toplevel-decoration-v1 pointer runtime
                           :toplevel toplevel)))
      (setf (gethash (%pointer-key pointer)
                     (%runtime-xdg-decoration-table runtime))
            decoration)
      (refresh-xdg-decoration decoration)
      (%attach-object-signal
       decoration :xdg-decoration-request-mode
       (ataxia.runtime.raw:%xdg-toplevel-decoration-event-request-mode pointer)
       (lambda (data)
         (declare (ignore data))
         (refresh-xdg-decoration decoration)
         (xdg-toplevel-decoration-request-mode
          (%runtime-sink runtime) decoration)))
      (%attach-object-signal
       decoration :xdg-decoration-destroy
       (ataxia.runtime.raw:%xdg-toplevel-decoration-event-destroy pointer)
       (lambda (data)
         (declare (ignore data))
         (unwind-protect
              (xdg-toplevel-decoration-destroying
               (%runtime-sink runtime) decoration)
           (retire-xdg-decoration runtime decoration))))
      (xdg-new-toplevel-decoration (%runtime-sink runtime) runtime decoration)
      decoration)))

(defun lookup-native-seat (runtime pointer)
  (unless (ataxia.runtime.raw:null-pointer-p pointer)
    (gethash (%pointer-key pointer) (%runtime-seat-table runtime))))

(defun lookup-native-surface (runtime pointer)
  (unless (ataxia.runtime.raw:null-pointer-p pointer)
    (%adopt-core-surface runtime pointer)))

(defun snapshot-xdg-activation-request (runtime event-pointer)
  (let* ((token
           (ataxia.runtime.raw:%xdg-activation-request-token event-pointer))
         (source-pointer
           (ataxia.runtime.raw:%xdg-activation-token-surface token))
         (seat-pointer
           (ataxia.runtime.raw:%xdg-activation-token-seat token))
         (app-id-pointer
           (ataxia.runtime.raw:%xdg-activation-token-app-id token)))
    (%make-xdg-activation-request
     :target-surface
     (lookup-native-surface
      runtime
      (ataxia.runtime.raw:%xdg-activation-request-surface event-pointer))
     :source-surface (lookup-native-surface runtime source-pointer)
     :seat (lookup-native-seat runtime seat-pointer)
     :serial (ataxia.runtime.raw:%xdg-activation-token-serial token)
     :app-id (unless (ataxia.runtime.raw:null-pointer-p app-id-pointer)
               (ataxia.runtime.raw:foreign-string-to-lisp app-id-pointer)))))

(defun create-desktop-shell-protocols (runtime)
  (%assert-runtime-live runtime :create-desktop-shell-protocols)
  (unless (%runtime-xdg-shell runtime)
    (error 'native-call-failed
           :name :create-desktop-shell-protocols
           :detail "XDG shell must exist first"))
  (when (or (%runtime-xdg-decoration-manager runtime)
            (%runtime-xdg-activation runtime))
    (error 'native-call-failed
           :name :create-desktop-shell-protocols
           :detail "desktop shell protocols already exist"))
  (let* ((display (%object-pointer (%runtime-display runtime)))
         (manager-pointer
           (%require-pointer
            (ataxia.runtime.raw:%wlr-xdg-decoration-manager-v1-create display)
            :wlr-xdg-decoration-manager-v1-create))
         (manager
           (%wrap-pointer 'wlr-xdg-decoration-manager-v1
                          manager-pointer runtime))
         (activation-pointer
           (%require-pointer
            (ataxia.runtime.raw:%wlr-xdg-activation-v1-create display)
            :wlr-xdg-activation-v1-create))
         (activation
           (%wrap-pointer 'wlr-xdg-activation-v1 activation-pointer runtime)))
    (setf (%runtime-xdg-decoration-manager runtime) manager
          (%runtime-xdg-activation runtime) activation)
    (%attach-object-signal
     manager :xdg-decoration-new-toplevel
     (ataxia.runtime.raw:%xdg-decoration-manager-event-new-toplevel
      manager-pointer)
     (lambda (decoration-pointer)
       (handle-new-xdg-decoration runtime decoration-pointer)))
    (%attach-object-signal
     activation :xdg-activation-request
     (ataxia.runtime.raw:%xdg-activation-event-request-activate
      activation-pointer)
     (lambda (event-pointer)
       (xdg-activation-requested
        (%runtime-sink runtime) runtime
        (snapshot-xdg-activation-request runtime event-pointer))))
    (values manager activation)))

(defun xdg-toplevel-decoration-set-mode (decoration mode)
  (%ensure-live decoration)
  (let ((native-mode
          (ecase mode (:client-side 1) (:server-side 2))))
    (ataxia.runtime.raw:%wlr-xdg-toplevel-decoration-v1-set-mode
     (%object-pointer decoration) native-mode)
    mode))
