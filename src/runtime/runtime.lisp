;;;; Lisp-owned Wayland/wlroots runtime.
;;;;
;;;; This module constructs exact native objects, installs typed signal sinks,
;;;; owns callback safe points, and dispatches libwayland from the Lisp thread.

(in-package #:ataxia.runtime)

(defconstant +wl-compositor-version+ 6)
(defconstant +wlr-log-info+ 2)
(defconstant +wlr-log-debug+ 3)
(defconstant +seat-capability-pointer+ #x1)
(defconstant +seat-capability-keyboard+ #x2)
(defconstant +seat-capability-touch+ #x4)

(defclass runtime ()
  ((owner-thread :initform #+sb-thread sb-thread:*current-thread*
                 #-sb-thread nil
                 :reader %runtime-owner-thread)
   (sink :initarg :sink :reader %runtime-sink)
   (backend-kind :initarg :backend-kind :reader runtime-backend-kind)
   (headless-width :initarg :headless-width :reader %runtime-headless-width)
   (headless-height :initarg :headless-height :reader %runtime-headless-height)
   (socket-requested-p :initarg :socket-requested-p
                       :reader %runtime-socket-requested-p)
   (debug-p :initarg :debug-p :reader %runtime-debug-p)
   (state :initform :constructing :accessor %runtime-state)
   (socket-name :initform nil :accessor %runtime-socket-name)
   (display :initform nil :accessor %runtime-display)
   (event-loop :initform nil :accessor %runtime-event-loop)
   (backend :initform nil :accessor %runtime-backend)
   (renderer :initform nil :accessor %runtime-renderer)
   (egl :initform nil :accessor %runtime-egl)
   (allocator :initform nil :accessor %runtime-allocator)
   (compositor-global :initform nil :accessor %runtime-compositor-global)
   (subcompositor-global :initform nil
                         :accessor %runtime-subcompositor-global)
   (outputs :initform (make-hash-table :test #'eql)
            :reader %runtime-output-table)
   (input-devices :initform (make-hash-table :test #'eql)
                  :reader %runtime-input-table)
   (surfaces :initform (make-hash-table :test #'eql)
             :reader %runtime-surface-table)
   (subsurfaces :initform (make-hash-table :test #'eql)
                :reader %runtime-subsurface-table)
   (seats :initform (make-hash-table :test #'eql)
          :reader %runtime-seat-table)
   (xdg-shell :initform nil :accessor %runtime-xdg-shell)
   (data-device-manager :initform nil
                        :accessor %runtime-data-device-manager)
   (xdg-toplevels :initform (make-hash-table :test #'eql)
                  :reader %runtime-xdg-toplevel-table)
   (xdg-popups :initform (make-hash-table :test #'eql)
               :reader %runtime-xdg-popup-table)
   (event-sources :initform (make-hash-table :test #'eql)
                  :reader %runtime-event-source-table)
   (retained-buffers :initform (make-hash-table :test #'eq)
                     :reader %runtime-retained-buffer-table)
   (xkb-contexts :initform (make-hash-table :test #'eq)
                 :reader %runtime-xkb-context-table)
   (xkb-keymaps :initform (make-hash-table :test #'eq)
                :reader %runtime-xkb-keymap-table)
   (subscriptions :initform nil :accessor %runtime-subscriptions)
   (callback-depth :initform 0 :accessor %runtime-callback-depth)
   (active-signals :initform nil :accessor %runtime-active-signals)
   (deferred-actions :initform nil :accessor %runtime-deferred-actions)
   (stop-requested-p :initform nil :accessor %runtime-stop-requested-p)
   (stop-reason :initform nil :accessor %runtime-stop-reason)
   (last-fault :initform nil :accessor %runtime-last-fault)))

(defun runtime-state (runtime)
  (%runtime-state runtime))

(defun runtime-socket-name (runtime)
  (%runtime-socket-name runtime))

(defun runtime-last-fault (runtime)
  (%runtime-last-fault runtime))

(defun runtime-display (runtime)
  (%runtime-display runtime))

(defun runtime-event-loop (runtime)
  (%runtime-event-loop runtime))

(defun runtime-backend (runtime)
  (%runtime-backend runtime))

(defun runtime-renderer (runtime)
  (%runtime-renderer runtime))

(defun runtime-egl (runtime)
  (%runtime-egl runtime))

(defun runtime-allocator (runtime)
  (%runtime-allocator runtime))

(defun runtime-compositor-global (runtime)
  (%runtime-compositor-global runtime))

(defun runtime-subcompositor-global (runtime)
  (%runtime-subcompositor-global runtime))

(defun runtime-data-device-manager (runtime)
  (%runtime-data-device-manager runtime))

(defun %hash-values (table)
  (loop for value being the hash-values of table collect value))

(defun runtime-outputs (runtime)
  (%hash-values (%runtime-output-table runtime)))

(defun runtime-input-devices (runtime)
  (%hash-values (%runtime-input-table runtime)))

(defun runtime-surfaces (runtime)
  (%hash-values (%runtime-surface-table runtime)))

(defun runtime-subsurfaces (runtime)
  (%hash-values (%runtime-subsurface-table runtime)))

(defun runtime-seats (runtime)
  (%hash-values (%runtime-seat-table runtime)))

(defun %current-thread ()
  #+sb-thread sb-thread:*current-thread*
  #-sb-thread nil)

(defun %assert-owner-thread (runtime operation)
  (unless (eq (%runtime-owner-thread runtime) (%current-thread))
    (error 'wrong-owner-thread :operation operation))
  runtime)

(defun %runtime-callback-active-p (runtime)
  (plusp (%runtime-callback-depth runtime)))

(defun %runtime-callback-enter (runtime signal-name)
  (%assert-owner-thread runtime signal-name)
  (incf (%runtime-callback-depth runtime))
  (push signal-name (%runtime-active-signals runtime))
  runtime)

(defun %runtime-callback-leave (runtime)
  (when (%runtime-active-signals runtime)
    (pop (%runtime-active-signals runtime)))
  (decf (%runtime-callback-depth runtime))
  (when (minusp (%runtime-callback-depth runtime))
    (setf (%runtime-callback-depth runtime) 0)
    (error 'runtime-error))
  runtime)

(defun %record-runtime-callback-fault (runtime signal-name cause)
  (let ((fault
          (make-condition 'callback-fault
                          :signal signal-name
                          :cause cause)))
    (unless (runtime-last-fault runtime)
      (setf (%runtime-last-fault runtime) fault))
    (setf (%runtime-stop-requested-p runtime) t
          (%runtime-stop-reason runtime) :callback-fault)
    fault))

(defun %defer-runtime-action (runtime action)
  (check-type action function)
  (push action (%runtime-deferred-actions runtime))
  runtime)

(defun %run-safe-point-actions (runtime)
  (unless (%runtime-callback-active-p runtime)
    (let ((actions (nreverse (%runtime-deferred-actions runtime))))
      (setf (%runtime-deferred-actions runtime) nil)
      (dolist (action actions)
        (handler-case
            (funcall action)
          (serious-condition (cause)
            (%record-runtime-callback-fault runtime :safe-point cause))))))
  runtime)

(defun %register-runtime-subscription (runtime subscription)
  (push subscription (%runtime-subscriptions runtime))
  subscription)

(defun %unregister-runtime-subscription (runtime subscription)
  (setf (%runtime-subscriptions runtime)
        (delete subscription (%runtime-subscriptions runtime) :test #'eq))
  subscription)

(defun %require-pointer (pointer native-call &optional detail)
  (when (ataxia.runtime.raw:null-pointer-p pointer)
    (error 'native-call-failed :name native-call :detail detail))
  pointer)

(defun %wrap-pointer (class pointer runtime &rest initargs)
  (apply #'make-instance class
         :pointer (%require-pointer pointer class)
         :runtime runtime
         initargs))

(defun %pointer-key (pointer)
  (ataxia.runtime.raw:pointer-address pointer))

(defun %object-pointer (object)
  (%native-pointer (%ensure-live object)))

(defun %runtime-live-state-p (runtime)
  (member (%runtime-state runtime) '(:ready :running) :test #'eq))

(defun %assert-runtime-live (runtime operation)
  (%assert-owner-thread runtime operation)
  (unless (%runtime-live-state-p runtime)
    (error 'native-call-failed
           :name operation :detail (runtime-state runtime)))
  runtime)

(defun %assert-object-runtime (runtime object operation)
  (%ensure-live object)
  (unless (eq runtime (%native-runtime object))
    (error 'native-call-failed
           :name operation :detail "objects belong to different runtimes"))
  object)

(defun %adopt-core-surface (runtime pointer)
  (or (gethash (%pointer-key pointer) (%runtime-surface-table runtime))
      (progn
        (%handle-new-surface runtime pointer)
        (gethash (%pointer-key pointer) (%runtime-surface-table runtime)))))

(defun %diagnostic-line (sink control &rest arguments)
  (let ((stream (diagnostic-stream sink)))
    (apply #'format stream control arguments)
    (terpri stream)
    (finish-output stream)))

(defmethod runtime-started ((sink diagnostic-sink) runtime)
  (%diagnostic-line sink
                    "[runtime] running backend=~(~A~) socket=~A renderer=gles2"
                    (runtime-backend-kind runtime)
                    (or (runtime-socket-name runtime) "disabled")))

(defmethod runtime-stopping ((sink diagnostic-sink) runtime reason)
  (declare (ignore runtime))
  (%diagnostic-line sink "[runtime] stopping reason=~(~A~)" reason))

(defmethod backend-new-output
    ((sink diagnostic-sink) runtime (output wlr-output))
  (%diagnostic-line
   sink "[runtime] new-output name=~A description=~A size=~Dx~D enabled=~A"
   (or (output-name output) "unknown")
   (or (output-description output) "none")
   (output-width output) (output-height output) (output-enabled-p output)))

(defmethod backend-new-input
    ((sink diagnostic-sink) runtime (input-device wlr-input-device))
  (%diagnostic-line sink "[runtime] new-input type=~(~A~) name=~A"
                    (input-device-type input-device)
                    (or (input-device-name input-device) "unknown"))
  (let ((seat (first (runtime-seats runtime))))
    (when seat
      (when (typep input-device 'wlr-keyboard)
        (set-keyboard-keymap-from-names input-device)
        (set-keyboard-repeat-info input-device 25 600)
        (set-seat-keyboard seat input-device))
      (set-seat-capabilities
       seat
       (loop for device in (runtime-input-devices runtime)
             with capabilities = 0
             do (setf capabilities
                      (logior
                       capabilities
                       (case (input-device-type device)
                         (:pointer +seat-capability-pointer+)
                         (:keyboard +seat-capability-keyboard+)
                         (:touch +seat-capability-touch+)
                         (otherwise 0))))
             finally (return capabilities)))))
  input-device)

(defmethod backend-destroying
    ((sink diagnostic-sink) runtime (backend wlr-backend))
  (declare (ignore runtime backend))
  (%diagnostic-line sink "[runtime] backend-destroy"))

(defmethod renderer-lost
    ((sink diagnostic-sink) runtime (renderer wlr-renderer))
  (declare (ignore runtime renderer))
  (%diagnostic-line sink "[runtime] renderer-lost"))

(defmethod compositor-new-surface
    ((sink diagnostic-sink) runtime (surface wlr-surface))
  (declare (ignore runtime))
  (%diagnostic-line sink "[runtime] new-surface address=~X"
                    (native-object-address surface)))

(defmethod output-destroying ((sink diagnostic-sink) (output wlr-output))
  (%diagnostic-line sink "[runtime] output-destroy name=~A"
                    (or (output-name output) "unknown")))

(defmethod input-device-destroying
    ((sink diagnostic-sink) (input-device wlr-input-device))
  (%diagnostic-line sink "[runtime] input-destroy name=~A"
                    (or (input-device-name input-device) "unknown")))

(defmethod pointer-button ((sink diagnostic-sink) event)
  (%diagnostic-line sink "[runtime] pointer-button code=~D state=~(~A~)"
                    (pointer-button-code event)
                    (pointer-button-state event)))

(defmethod keyboard-key ((sink diagnostic-sink) event)
  (%diagnostic-line sink "[runtime] keyboard-key code=~D state=~(~A~)"
                    (keyboard-key-keycode event)
                    (keyboard-key-state event)))

(defmethod seat-destroying ((sink diagnostic-sink) (seat wlr-seat))
  (%diagnostic-line sink "[runtime] seat-destroy name=~A" (%seat-name seat)))

(defmethod seat-request-set-cursor
    ((sink diagnostic-sink) request)
  (%diagnostic-line
   sink "[runtime] seat-cursor surface=~A hotspot=~D,~D serial=~D"
   (if (seat-cursor-request-surface request) "set" "hidden")
   (seat-cursor-request-hotspot-x request)
   (seat-cursor-request-hotspot-y request)
   (seat-cursor-request-serial request)))

(defmethod surface-committed
    ((sink diagnostic-sink) (surface wlr-surface) event)
  (declare (ignore surface))
  (%diagnostic-line sink "[runtime] surface-commit seq=~D size=~Dx~D mapped=~A"
                    (surface-commit-sequence event)
                    (surface-commit-width event)
                    (surface-commit-height event)
                    (surface-commit-mapped-p event)))

(defmethod surface-mapped ((sink diagnostic-sink) (surface wlr-surface))
  (%diagnostic-line sink "[runtime] surface-map address=~X"
                    (native-object-address surface)))

(defmethod surface-unmapped ((sink diagnostic-sink) (surface wlr-surface))
  (%diagnostic-line sink "[runtime] surface-unmap address=~X"
                    (native-object-address surface)))

(defmethod surface-destroying ((sink diagnostic-sink) (surface wlr-surface))
  (%diagnostic-line sink "[runtime] surface-destroy address=~X"
                    (native-object-address surface)))

(defun %handle-new-output (runtime pointer)
  (let ((key (%pointer-key pointer)))
    (unless (gethash key (%runtime-output-table runtime))
      (let ((output (%refresh-output
                     (%wrap-pointer 'wlr-output pointer runtime))))
        (setf (gethash key (%runtime-output-table runtime)) output)
        (%attach-object-signal
         output :output-frame
         (ataxia.runtime.raw:%output-event-frame pointer)
         (lambda (data)
           (declare (ignore data))
           (%refresh-output output)
           (output-frame (%runtime-sink runtime) output)))
        (%install-output-extended-signals output)
        (%attach-object-signal
         output :output-destroy
         (ataxia.runtime.raw:%output-event-destroy pointer)
         (lambda (data)
           (declare (ignore data))
           (unwind-protect
             (output-destroying (%runtime-sink runtime) output)
             (dolist (mode (%output-modes output))
               (%invalidate-native-object mode))
             (setf (%output-modes output) nil)
             (%retire-object-listeners output :immediate-p t)
             (%invalidate-native-object output)
             (remhash key (%runtime-output-table runtime)))))
        (backend-new-output (%runtime-sink runtime) runtime output)))))

(defun %handle-new-input (runtime pointer)
  (let ((key (%pointer-key pointer)))
    (unless (gethash key (%runtime-input-table runtime))
      (let* ((type-code (ataxia.runtime.raw:%input-device-type pointer))
             (native-pointer
               (case type-code
                 (0 (%require-pointer
                     (ataxia.runtime.raw:%input-device-keyboard pointer)
                     :wlr-keyboard-from-input-device))
                 (1 (%require-pointer
                     (ataxia.runtime.raw:%input-device-pointer pointer)
                     :wlr-pointer-from-input-device))
                 (otherwise pointer)))
             (class
               (case type-code
                 (0 'wlr-keyboard)
                 (1 'wlr-pointer)
                 (otherwise 'wlr-input-device)))
             (input-device
               (%refresh-input-device
                (%wrap-pointer class native-pointer runtime))))
        (setf (gethash key (%runtime-input-table runtime)) input-device)
        (%attach-object-signal
         input-device :input-device-destroy
         (ataxia.runtime.raw:%input-device-event-destroy pointer)
         (lambda (data)
           (declare (ignore data))
           (unwind-protect
                (input-device-destroying
                 (%runtime-sink runtime) input-device)
             (%retire-object-listeners input-device :immediate-p t)
             (%invalidate-native-object input-device)
             (remhash key (%runtime-input-table runtime)))))
        (etypecase input-device
          (wlr-pointer (%install-pointer-signals input-device))
          (wlr-keyboard (%install-keyboard-signals input-device))
          (wlr-input-device nil))
        (backend-new-input (%runtime-sink runtime) runtime input-device)))))

(defun %install-pointer-signals (pointer)
  (let ((native-pointer (%object-pointer pointer))
        (sink (%runtime-sink (%native-runtime pointer))))
    (%attach-object-signal
     pointer :pointer-motion
     (ataxia.runtime.raw:%pointer-event-motion native-pointer)
     (lambda (event-pointer)
       (pointer-motion sink
                       (%pointer-motion-snapshot pointer event-pointer))))
    (%attach-object-signal
     pointer :pointer-motion-absolute
     (ataxia.runtime.raw:%pointer-event-motion-absolute native-pointer)
     (lambda (event-pointer)
       (pointer-motion-absolute
        sink (%pointer-motion-absolute-snapshot pointer event-pointer))))
    (%attach-object-signal
     pointer :pointer-button
     (ataxia.runtime.raw:%pointer-event-button native-pointer)
     (lambda (event-pointer)
       (pointer-button sink
                       (%pointer-button-snapshot pointer event-pointer))))
    (%attach-object-signal
     pointer :pointer-axis
     (ataxia.runtime.raw:%pointer-event-axis native-pointer)
     (lambda (event-pointer)
       (pointer-axis sink (%pointer-axis-snapshot pointer event-pointer))))
    (%attach-object-signal
     pointer :pointer-frame
     (ataxia.runtime.raw:%pointer-event-frame native-pointer)
     (lambda (data)
       (declare (ignore data))
       (pointer-frame sink pointer))))
  pointer)

(defun %install-keyboard-signals (keyboard)
  (let ((native-pointer (%object-pointer keyboard))
        (sink (%runtime-sink (%native-runtime keyboard))))
    (%attach-object-signal
     keyboard :keyboard-key
     (ataxia.runtime.raw:%keyboard-event-key native-pointer)
     (lambda (event-pointer)
       (keyboard-key sink
                     (%keyboard-key-snapshot keyboard event-pointer))))
    (%attach-object-signal
     keyboard :keyboard-modifiers
     (ataxia.runtime.raw:%keyboard-event-modifiers native-pointer)
     (lambda (data)
       (declare (ignore data))
       (keyboard-modifiers sink
                           (%keyboard-modifiers-snapshot keyboard))))
    (%attach-object-signal
     keyboard :keyboard-keymap
     (ataxia.runtime.raw:%keyboard-event-keymap native-pointer)
     (lambda (data)
       (declare (ignore data))
       (keyboard-keymap-changed sink keyboard)))
    (%attach-object-signal
     keyboard :keyboard-repeat-info
     (ataxia.runtime.raw:%keyboard-event-repeat-info native-pointer)
     (lambda (data)
       (declare (ignore data))
       (keyboard-repeat-info sink (%keyboard-repeat-snapshot keyboard)))))
  keyboard)

(defun %handle-new-surface (runtime pointer)
  (let ((key (%pointer-key pointer)))
    (unless (gethash key (%runtime-surface-table runtime))
      (let ((surface (%wrap-pointer 'wlr-surface pointer runtime)))
        (setf (gethash key (%runtime-surface-table runtime)) surface
              (surface-mapped-p surface)
              (ataxia.runtime.raw:%surface-mapped pointer))
        (%attach-object-signal
         surface :surface-commit
         (ataxia.runtime.raw:%surface-event-commit pointer)
         (lambda (data)
           (declare (ignore data))
           (let ((event (%surface-commit-snapshot surface)))
             (setf (surface-mapped-p surface)
                   (surface-commit-mapped-p event))
             (surface-committed (%runtime-sink runtime) surface event))))
        (%attach-object-signal
         surface :surface-map
         (ataxia.runtime.raw:%surface-event-map pointer)
         (lambda (data)
           (declare (ignore data))
           (setf (surface-mapped-p surface) t)
           (surface-mapped (%runtime-sink runtime) surface)))
        (%attach-object-signal
         surface :surface-unmap
         (ataxia.runtime.raw:%surface-event-unmap pointer)
         (lambda (data)
           (declare (ignore data))
           (setf (surface-mapped-p surface) nil)
           (surface-unmapped (%runtime-sink runtime) surface)))
        (%attach-object-signal
         surface :surface-destroy
         (ataxia.runtime.raw:%surface-event-destroy pointer)
         (lambda (data)
           (declare (ignore data))
           (unwind-protect
                (surface-destroying (%runtime-sink runtime) surface)
             (%retire-object-listeners surface :immediate-p t)
             (%invalidate-native-object surface)
             (remhash key (%runtime-surface-table runtime)))))
        (%install-subsurface-discovery surface)
        (compositor-new-surface (%runtime-sink runtime) runtime surface)))))

(defun %install-runtime-signals (runtime)
  (let* ((backend (%runtime-backend runtime))
         (backend-pointer (%object-pointer backend))
         (renderer (%runtime-renderer runtime))
         (renderer-pointer (%object-pointer renderer))
         (allocator (%runtime-allocator runtime))
         (allocator-pointer (%object-pointer allocator))
         (compositor (%runtime-compositor-global runtime))
         (compositor-pointer (%object-pointer compositor)))
    (%attach-object-signal
     backend :backend-new-output
     (ataxia.runtime.raw:%backend-event-new-output backend-pointer)
     (lambda (pointer) (%handle-new-output runtime pointer)))
    (%attach-object-signal
     backend :backend-new-input
     (ataxia.runtime.raw:%backend-event-new-input backend-pointer)
     (lambda (pointer) (%handle-new-input runtime pointer)))
    (%attach-object-signal
     backend :backend-destroy
     (ataxia.runtime.raw:%backend-event-destroy backend-pointer)
     (lambda (data)
       (declare (ignore data))
       (unwind-protect
            (backend-destroying (%runtime-sink runtime) runtime backend)
         (%retire-object-listeners backend :immediate-p t)
         (%invalidate-native-object backend)
         (setf (%runtime-backend runtime) nil
               (%runtime-stop-requested-p runtime) t))))
    (%attach-object-signal
     renderer :renderer-lost
     (ataxia.runtime.raw:%renderer-event-lost renderer-pointer)
     (lambda (data)
       (declare (ignore data))
       (renderer-lost (%runtime-sink runtime) runtime renderer)))
    (%attach-object-signal
     renderer :renderer-destroy
     (ataxia.runtime.raw:%renderer-event-destroy renderer-pointer)
     (lambda (data)
       (declare (ignore data))
       (%retire-object-listeners renderer :immediate-p t)
       (%invalidate-native-object (%runtime-egl runtime))
       (%invalidate-native-object renderer)
       (setf (%runtime-egl runtime) nil
             (%runtime-renderer runtime) nil)))
    (%attach-object-signal
     allocator :allocator-destroy
     (ataxia.runtime.raw:%allocator-event-destroy allocator-pointer)
     (lambda (data)
       (declare (ignore data))
       (%retire-object-listeners allocator :immediate-p t)
       (%invalidate-native-object allocator)
       (setf (%runtime-allocator runtime) nil)))
    (%attach-object-signal
     compositor :compositor-new-surface
     (ataxia.runtime.raw:%compositor-event-new-surface compositor-pointer)
     (lambda (pointer) (%handle-new-surface runtime pointer)))
    (%attach-object-signal
     compositor :compositor-destroy
     (ataxia.runtime.raw:%compositor-event-destroy compositor-pointer)
     (lambda (data)
       (declare (ignore data))
       (%retire-object-listeners compositor :immediate-p t)
       (%invalidate-native-object compositor)
       (setf (%runtime-compositor-global runtime) nil))))
  runtime)

(defun %construct-native-runtime (runtime)
  (ataxia.runtime.raw:%wlr-log-init
   (if (%runtime-debug-p runtime) +wlr-log-debug+ +wlr-log-info+)
   (ataxia.runtime.raw:null-pointer))
  (let* ((display-pointer
           (%require-pointer (ataxia.runtime.raw:%wl-display-create)
                             :wl-display-create))
         (display (%wrap-pointer 'wl-display display-pointer runtime))
         (event-loop-pointer
           (%require-pointer
            (ataxia.runtime.raw:%wl-display-get-event-loop display-pointer)
            :wl-display-get-event-loop))
         (event-loop (%wrap-pointer 'wl-event-loop event-loop-pointer runtime)))
    (setf (%runtime-display runtime) display
          (%runtime-event-loop runtime) event-loop)
    (let* ((backend-pointer
             (%require-pointer
              (ecase (runtime-backend-kind runtime)
                (:auto
                 (ataxia.runtime.raw:%wlr-backend-autocreate
                  event-loop-pointer (ataxia.runtime.raw:null-pointer)))
                (:headless
                 (ataxia.runtime.raw:%wlr-headless-backend-create
                  event-loop-pointer)))
              :wlr-backend-create (runtime-backend-kind runtime)))
           (backend (%wrap-pointer 'wlr-backend backend-pointer runtime))
           (renderer-pointer
             (%require-pointer
              (ataxia.runtime.raw:%wlr-renderer-autocreate backend-pointer)
              :wlr-renderer-autocreate))
           (renderer (%wrap-pointer 'wlr-renderer renderer-pointer runtime)))
      (unless (ataxia.runtime.raw:%wlr-renderer-is-gles2 renderer-pointer)
        (error 'native-call-failed
               :name :wlr-renderer-autocreate
               :detail "direct GLES2 renderer required"))
      (let* ((egl-pointer
               (%require-pointer
                (ataxia.runtime.raw:%wlr-gles2-renderer-get-egl
                 renderer-pointer)
                :wlr-gles2-renderer-get-egl))
             (egl (%wrap-pointer 'wlr-egl egl-pointer runtime))
             (allocator-pointer
               (%require-pointer
                (ataxia.runtime.raw:%wlr-allocator-autocreate
                 backend-pointer renderer-pointer)
                :wlr-allocator-autocreate))
             (allocator
               (%wrap-pointer 'wlr-allocator allocator-pointer runtime)))
        (unless (ataxia.runtime.raw:%wlr-renderer-init-wl-display
                 renderer-pointer display-pointer)
          (error 'native-call-failed :name :wlr-renderer-init-wl-display))
        (let* ((compositor-pointer
                 (%require-pointer
                  (ataxia.runtime.raw:%wlr-compositor-create
                   display-pointer +wl-compositor-version+ renderer-pointer)
                  :wlr-compositor-create))
               (subcompositor-pointer
                 (%require-pointer
                  (ataxia.runtime.raw:%wlr-subcompositor-create display-pointer)
                  :wlr-subcompositor-create)))
          (setf (%runtime-backend runtime) backend
                (%runtime-renderer runtime) renderer
                (%runtime-egl runtime) egl
                (%runtime-allocator runtime) allocator
                (%runtime-compositor-global runtime)
                (%wrap-pointer 'wlr-compositor compositor-pointer runtime)
                (%runtime-subcompositor-global runtime)
                (%wrap-pointer 'wlr-subcompositor
                               subcompositor-pointer runtime))
          (%install-runtime-signals runtime)
          (when (eq (runtime-backend-kind runtime) :headless)
            (%require-pointer
             (ataxia.runtime.raw:%wlr-headless-add-output
              backend-pointer
              (%runtime-headless-width runtime)
              (%runtime-headless-height runtime))
             :wlr-headless-add-output))
          (%run-safe-point-actions runtime)
          (when (runtime-last-fault runtime)
            (error (runtime-last-fault runtime)))))))
  (setf (%runtime-state runtime) :ready)
  runtime)

(defun create-runtime
    (&key (sink (make-instance 'diagnostic-sink))
          (backend :auto)
          (headless-width 1280)
          (headless-height 720)
          (socket-p t)
          debug-p)
  (check-type sink runtime-sink)
  (check-type headless-width (integer 1))
  (check-type headless-height (integer 1))
  (unless (member backend '(:auto :headless) :test #'eq)
    (error 'native-call-failed :name :backend-kind :detail backend))
  (ataxia.runtime.raw:load-native-libraries)
  (ataxia.runtime.raw:verify-native-abi)
  (let ((runtime
          (make-instance 'runtime
                         :sink sink
                         :backend-kind backend
                         :headless-width headless-width
                         :headless-height headless-height
                         :socket-requested-p socket-p
                         :debug-p debug-p)))
    (handler-case
        (%construct-native-runtime runtime)
      (serious-condition (cause)
        (ignore-errors (destroy-runtime runtime :construction-failure))
        (error cause)))))

(defun start-runtime (runtime)
  (%assert-owner-thread runtime :start-runtime)
  (unless (eq (runtime-state runtime) :ready)
    (error 'native-call-failed
           :name :start-runtime :detail (runtime-state runtime)))
  (when (%runtime-socket-requested-p runtime)
    (let ((socket-pointer
            (%require-pointer
             (ataxia.runtime.raw:%wl-display-add-socket-auto
              (%object-pointer (%runtime-display runtime)))
             :wl-display-add-socket-auto)))
      (setf (%runtime-socket-name runtime)
            (ataxia.runtime.raw:foreign-string-to-lisp socket-pointer))))
  (unless (ataxia.runtime.raw:%wlr-backend-start
           (%object-pointer (%runtime-backend runtime)))
    (%run-safe-point-actions runtime)
    (when (runtime-last-fault runtime)
      (error (runtime-last-fault runtime)))
    (error 'native-call-failed :name :wlr-backend-start))
  (%run-safe-point-actions runtime)
  (when (runtime-last-fault runtime)
    (error (runtime-last-fault runtime)))
  (setf (%runtime-state runtime) :running)
  (runtime-started (%runtime-sink runtime) runtime)
  runtime)

(defun request-runtime-stop (runtime &optional (reason :requested))
  (%assert-owner-thread runtime :request-runtime-stop)
  (setf (%runtime-stop-requested-p runtime) t
        (%runtime-stop-reason runtime) reason)
  runtime)

(defun run-runtime (runtime &key run-for)
  (%assert-owner-thread runtime :run-runtime)
  (when (eq (runtime-state runtime) :ready)
    (start-runtime runtime))
  (unless (eq (runtime-state runtime) :running)
    (error 'native-call-failed
           :name :run-runtime :detail (runtime-state runtime)))
  (let ((deadline-timer
          (when run-for
            (let ((source
                    (add-event-loop-timer
                     runtime
                     (lambda (timer)
                       (declare (ignore timer))
                       (request-runtime-stop runtime :deadline)
                       0))))
              (update-event-loop-timer
               source (max 1 (round (* run-for 1000))))
              source))))
    (unwind-protect
         (loop until (%runtime-stop-requested-p runtime)
               do (let ((result
                          (ataxia.runtime.raw:%wl-event-loop-dispatch
                           (%object-pointer (%runtime-event-loop runtime))
                           100)))
                    (when (minusp result)
                      (error 'native-call-failed
                             :name :wl-event-loop-dispatch :detail result)))
                  (%run-safe-point-actions runtime)
                  (when (runtime-last-fault runtime)
                    (error (runtime-last-fault runtime)))
                  (ataxia.runtime.raw:%wl-display-flush-clients
                   (%object-pointer (%runtime-display runtime))))
      (when (and deadline-timer (native-object-live-p deadline-timer))
        (remove-event-loop-source deadline-timer))))
  runtime)

(defun %teardown-step (runtime name function)
  (handler-case
      (progn
        (funcall function)
        (%run-safe-point-actions runtime)
        t)
    (serious-condition (cause)
      (format *error-output* "[runtime] teardown ~A failed: ~A~%" name cause)
      (finish-output *error-output*)
      nil)))

(defun %destroy-owned-object (runtime object destroy-function)
  (when (and object (native-object-live-p object))
    (funcall destroy-function (%native-pointer object))
    (%run-safe-point-actions runtime)
    (when (native-object-live-p object)
      (%invalidate-native-object object)))
  nil)

(defun destroy-runtime (runtime &optional reason)
  (when runtime
    (%assert-owner-thread runtime :destroy-runtime)
    (unless (eq (runtime-state runtime) :stopped)
      (let ((effective-reason
              (or reason (%runtime-stop-reason runtime) :shutdown)))
      (setf (%runtime-state runtime) :stopping
            (%runtime-stop-requested-p runtime) t
            (%runtime-stop-reason runtime) effective-reason)
      (%teardown-step
       runtime :sink
       (lambda ()
         (runtime-stopping (%runtime-sink runtime)
                           runtime effective-reason)))
      (%teardown-step
       runtime :clients
       (lambda ()
         (when (and (%runtime-display runtime)
                    (native-object-live-p (%runtime-display runtime)))
           (ataxia.runtime.raw:%wl-display-destroy-clients
            (%native-pointer (%runtime-display runtime))))))
      (%teardown-step
       runtime :event-sources
       (lambda () (%remove-runtime-event-sources runtime)))
      (dolist (seat (%hash-values (%runtime-seat-table runtime)))
        (%teardown-step runtime :seat (lambda () (destroy-seat seat))))
      (%teardown-step
       runtime :retained-buffers
       (lambda () (%release-runtime-buffers runtime)))
      (%teardown-step
       runtime :xkb
       (lambda () (%destroy-runtime-xkb-objects runtime)))
      (%teardown-step
       runtime :allocator
       (lambda ()
         (%destroy-owned-object runtime (%runtime-allocator runtime)
                                #'ataxia.runtime.raw:%wlr-allocator-destroy)))
      (%teardown-step
       runtime :renderer
       (lambda ()
         (%destroy-owned-object runtime (%runtime-renderer runtime)
                                #'ataxia.runtime.raw:%wlr-renderer-destroy)))
      (%teardown-step
       runtime :backend
       (lambda ()
         (%destroy-owned-object runtime (%runtime-backend runtime)
                                #'ataxia.runtime.raw:%wlr-backend-destroy)))
      (%teardown-step
       runtime :display
       (lambda ()
         (when (and (%runtime-display runtime)
                    (native-object-live-p (%runtime-display runtime)))
           (ataxia.runtime.raw:%wl-display-destroy
            (%native-pointer (%runtime-display runtime)))
           (%invalidate-native-object (%runtime-display runtime)))))
      (%run-safe-point-actions runtime)
      (when (%runtime-subscriptions runtime)
        (%retire-runtime-listeners runtime))
      (dolist (object (list (%runtime-event-loop runtime)
                            (%runtime-egl runtime)
                            (%runtime-compositor-global runtime)
                            (%runtime-subcompositor-global runtime)
                            (%runtime-data-device-manager runtime)))
        (when object (%invalidate-native-object object)))
      (clrhash (%runtime-output-table runtime))
      (clrhash (%runtime-input-table runtime))
      (clrhash (%runtime-surface-table runtime))
      (clrhash (%runtime-subsurface-table runtime))
      (clrhash (%runtime-seat-table runtime))
      (clrhash (%runtime-xdg-toplevel-table runtime))
      (clrhash (%runtime-xdg-popup-table runtime))
      (setf (%runtime-display runtime) nil
            (%runtime-event-loop runtime) nil
            (%runtime-backend runtime) nil
            (%runtime-renderer runtime) nil
            (%runtime-egl runtime) nil
            (%runtime-allocator runtime) nil
            (%runtime-compositor-global runtime) nil
            (%runtime-subcompositor-global runtime) nil
            (%runtime-xdg-shell runtime) nil
            (%runtime-data-device-manager runtime) nil
            (%runtime-socket-name runtime) nil
            (%runtime-state runtime) :stopped))))
  nil)

(defun call-with-runtime (function &rest options)
  (let ((runtime (apply #'create-runtime options)))
    (unwind-protect
         (progn
           (start-runtime runtime)
           (funcall function runtime))
      (destroy-runtime runtime))))

(defun create-seat (runtime name)
  (%assert-runtime-live runtime :create-seat)
  (check-type name string)
  (let* ((pointer
           (%require-pointer
            (ataxia.runtime.raw:%wlr-seat-create
             (%object-pointer (%runtime-display runtime)) name)
            :wlr-seat-create name))
         (key (%pointer-key pointer))
         (seat (%wrap-pointer 'wlr-seat pointer runtime :name name)))
    (setf (gethash key (%runtime-seat-table runtime)) seat)
    (%attach-object-signal
     seat :seat-request-set-cursor
     (ataxia.runtime.raw:%seat-event-request-set-cursor pointer)
     (lambda (event-pointer)
       (let ((surface-pointer
               (ataxia.runtime.raw:%seat-cursor-surface event-pointer)))
         (seat-request-set-cursor
          (%runtime-sink runtime)
          (%make-seat-cursor-request
           :seat seat
           :surface
           (unless (ataxia.runtime.raw:null-pointer-p surface-pointer)
             (%adopt-core-surface runtime surface-pointer))
           :serial (ataxia.runtime.raw:%seat-cursor-serial event-pointer)
           :hotspot-x
           (ataxia.runtime.raw:%seat-cursor-hotspot-x event-pointer)
           :hotspot-y
           (ataxia.runtime.raw:%seat-cursor-hotspot-y event-pointer))))))
    (%attach-object-signal
     seat :seat-destroy
     (ataxia.runtime.raw:%seat-event-destroy pointer)
     (lambda (data)
       (declare (ignore data))
       (unwind-protect
            (seat-destroying (%runtime-sink runtime) seat)
         (%retire-object-listeners seat :immediate-p t)
         (%invalidate-native-object seat)
         (remhash key (%runtime-seat-table runtime)))))
    seat))

(defun create-data-device-manager (runtime)
  (%assert-runtime-live runtime :create-data-device-manager)
  (when (%runtime-data-device-manager runtime)
    (error 'native-call-failed
           :name :create-data-device-manager
           :detail "data device manager already exists"))
  (let ((manager
          (%wrap-pointer
           'wlr-data-device-manager
           (%require-pointer
            (ataxia.runtime.raw:%wlr-data-device-manager-create
             (%object-pointer (%runtime-display runtime)))
            :wlr-data-device-manager-create)
           runtime)))
    (setf (%runtime-data-device-manager runtime) manager)
    manager))

(defun set-seat-capabilities (seat capabilities)
  (check-type capabilities (unsigned-byte 32))
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :set-seat-capabilities)
    (ataxia.runtime.raw:%wlr-seat-set-capabilities
     (%object-pointer seat) capabilities))
  seat)

(defun set-seat-name (seat name)
  (check-type name string)
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :set-seat-name)
    (ataxia.runtime.raw:%wlr-seat-set-name (%object-pointer seat) name)
    (setf (%seat-name seat) name))
  seat)

(defun set-seat-keyboard (seat keyboard)
  (check-type keyboard wlr-keyboard)
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :set-seat-keyboard)
    (%assert-object-runtime runtime keyboard :set-seat-keyboard)
    (ataxia.runtime.raw:%wlr-seat-set-keyboard
     (%object-pointer seat) (%object-pointer keyboard)))
  seat)

(defun clear-seat-keyboard (seat)
  "Remove wlroots' borrowed reference before the keyboard is destroyed."
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :clear-seat-keyboard)
    (ataxia.runtime.raw:%wlr-seat-set-keyboard
     (%object-pointer seat) (ataxia.runtime.raw:null-pointer)))
  seat)

(defun seat-pointer-notify-enter (seat surface surface-x surface-y)
  (check-type surface wlr-surface)
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-pointer-notify-enter)
    (%assert-object-runtime runtime surface :seat-pointer-notify-enter)
    (ataxia.runtime.raw:%wlr-seat-pointer-notify-enter
     (%object-pointer seat) (%object-pointer surface)
     (coerce surface-x 'double-float) (coerce surface-y 'double-float)))
  seat)

(defun seat-pointer-notify-clear-focus (seat)
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-pointer-notify-clear-focus)
    (ataxia.runtime.raw:%wlr-seat-pointer-notify-clear-focus
     (%object-pointer seat)))
  seat)

(defun seat-pointer-notify-motion (seat time-msec surface-x surface-y)
  (check-type time-msec (unsigned-byte 32))
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-pointer-notify-motion)
    (ataxia.runtime.raw:%wlr-seat-pointer-notify-motion
     (%object-pointer seat) time-msec
     (coerce surface-x 'double-float) (coerce surface-y 'double-float)))
  seat)

(defun %button-state-code (state)
  (etypecase state
    ((unsigned-byte 32) state)
    (keyword
     (ecase state
       (:released 0)
       (:pressed 1)))))

(defun seat-pointer-notify-button (seat time-msec button state)
  (check-type time-msec (unsigned-byte 32))
  (check-type button (unsigned-byte 32))
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-pointer-notify-button)
    (ataxia.runtime.raw:%wlr-seat-pointer-notify-button
     (%object-pointer seat) time-msec button (%button-state-code state))))

(defun %axis-orientation-code (orientation)
  (etypecase orientation
    ((unsigned-byte 32) orientation)
    (keyword
     (ecase orientation
       (:vertical 0)
       (:horizontal 1)))))

(defun %axis-source-code (source)
  (etypecase source
    ((unsigned-byte 32) source)
    (keyword
     (ecase source
       (:wheel 0)
       (:finger 1)
       (:continuous 2)
       (:wheel-tilt 3)))))

(defun %axis-relative-direction-code (direction)
  (etypecase direction
    ((unsigned-byte 32) direction)
    (keyword
     (ecase direction
       (:identical 0)
       (:inverted 1)))))

(defun seat-pointer-notify-axis
    (seat time-msec orientation value discrete-value source
     relative-direction)
  (check-type time-msec (unsigned-byte 32))
  (check-type discrete-value (signed-byte 32))
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-pointer-notify-axis)
    (ataxia.runtime.raw:%wlr-seat-pointer-notify-axis
     (%object-pointer seat)
     time-msec
     (%axis-orientation-code orientation)
     (coerce value 'double-float)
     discrete-value
     (%axis-source-code source)
     (%axis-relative-direction-code relative-direction)))
  seat)

(defun seat-pointer-notify-frame (seat)
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-pointer-notify-frame)
    (ataxia.runtime.raw:%wlr-seat-pointer-notify-frame
     (%object-pointer seat)))
  seat)

(defun seat-validate-pointer-grab-serial (seat origin serial)
  (check-type origin wlr-surface)
  (check-type serial (unsigned-byte 32))
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-validate-pointer-grab-serial)
    (%assert-object-runtime runtime origin
                            :seat-validate-pointer-grab-serial)
    (ataxia.runtime.raw:%wlr-seat-validate-pointer-grab-serial
     (%object-pointer seat) (%object-pointer origin) serial)))

(defun seat-keyboard-notify-key (seat time-msec keycode state)
  (check-type time-msec (unsigned-byte 32))
  (check-type keycode (unsigned-byte 32))
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-keyboard-notify-key)
    (ataxia.runtime.raw:%wlr-seat-keyboard-notify-key
     (%object-pointer seat) time-msec keycode (%button-state-code state)))
  seat)

(defun seat-keyboard-notify-modifiers (seat keyboard)
  (check-type keyboard wlr-keyboard)
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-keyboard-notify-modifiers)
    (%assert-object-runtime runtime keyboard
                            :seat-keyboard-notify-modifiers)
    (ataxia.runtime.raw:%seat-keyboard-notify-modifiers-current
     (%object-pointer seat) (%object-pointer keyboard)))
  seat)

(defun seat-keyboard-notify-enter (seat surface keyboard)
  (check-type surface wlr-surface)
  (check-type keyboard wlr-keyboard)
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-keyboard-notify-enter)
    (%assert-object-runtime runtime surface :seat-keyboard-notify-enter)
    (%assert-object-runtime runtime keyboard :seat-keyboard-notify-enter)
    (ataxia.runtime.raw:%seat-keyboard-notify-enter-current
     (%object-pointer seat) (%object-pointer surface)
     (%object-pointer keyboard)))
  seat)

(defun seat-keyboard-notify-clear-focus (seat)
  (let ((runtime (%native-runtime seat)))
    (%assert-runtime-live runtime :seat-keyboard-notify-clear-focus)
    (ataxia.runtime.raw:%wlr-seat-keyboard-notify-clear-focus
     (%object-pointer seat)))
  seat)

(defun destroy-seat (seat)
  (when (and seat (native-object-live-p seat))
    (let ((runtime (%native-runtime seat)))
      (%assert-owner-thread runtime :destroy-seat)
      (ataxia.runtime.raw:%wlr-seat-destroy (%native-pointer seat))
      (%run-safe-point-actions runtime)
      (when (native-object-live-p seat)
        (%retire-object-listeners seat :immediate-p t)
        (%invalidate-native-object seat))))
  nil)
