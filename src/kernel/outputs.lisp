;;;; Output and frame mechanisms.
;;;;
;;;; Kernel configures wlr-output, acquires swapchain buffers, activates EGL,
;;;; and commits exactly the damage returned by World. It owns no presentation
;;;; graph, drawing, damage history, or fallback policy.

(in-package #:ataxia.kernel)

(cffi:defcfun ("glBindFramebuffer" %gl-bind-framebuffer) :void
  (target :uint32)
  (framebuffer :uint32))

(cffi:defcfun ("glViewport" %gl-viewport) :void
  (x :int32)
  (y :int32)
  (width :int32)
  (height :int32))

(defconstant +gl-framebuffer+ #x8d40)
(defconstant +output-state-buffer-configuration-fields+ #xbc)

(defun %refresh-output-object (output)
  (let ((runtime-output (output-runtime-object output)))
    (setf (output-width output) (ataxia.runtime:output-width runtime-output)
          (output-height output) (ataxia.runtime:output-height runtime-output)
          (output-scale output) (ataxia.runtime:output-scale runtime-output)
          (output-transform output)
          (ataxia.runtime:output-transform runtime-output)
          (output-enabled-p output)
          (ataxia.runtime:output-enabled-p runtime-output)))
  output)

(defun %prepare-runtime-output (kernel runtime-output)
  (handler-case
      (progn
        (ataxia.runtime:initialize-output-render
         runtime-output
         (ataxia.runtime:runtime-allocator (kernel-runtime kernel))
         (ataxia.runtime:runtime-renderer (kernel-runtime kernel)))
        (let ((state (ataxia.runtime:create-output-state runtime-output)))
          (unwind-protect
               (progn
                 (ataxia.runtime:output-state-set-enabled state t)
                 (let ((mode (ataxia.runtime:output-preferred-mode runtime-output)))
                   (if mode
                       (ataxia.runtime:output-state-set-mode state mode)
                       (ataxia.runtime:output-state-set-custom-mode
                        state
                        (max 1 (ataxia.runtime:output-width runtime-output))
                        (max 1 (ataxia.runtime:output-height runtime-output)))))
                 (unless (ataxia.runtime:output-test-state runtime-output state)
                   (error "wlroots rejected the initial output state."))
                 (unless (ataxia.runtime:output-commit-state runtime-output state)
                   (error "wlroots failed to commit the initial output state.")))
            (ataxia.runtime:destroy-output-state state)))
        (ataxia.runtime:create-output-global runtime-output)
        t)
    (serious-condition (cause)
      (format *error-output* "[kernel] output unavailable: ~A: ~A~%"
              (or (ataxia.runtime:output-name runtime-output) "unknown") cause)
      (finish-output *error-output*)
      nil)))

(defun %configure-new-output (kernel runtime-output)
  (when (%prepare-runtime-output kernel runtime-output)
    (let ((output
            (make-instance
             'kernel-output
             :kernel kernel
             :id (%allocate-object-id kernel)
             :runtime-object runtime-output
             :name (ataxia.runtime:output-name runtime-output)
             :description (ataxia.runtime:output-description runtime-output)
             :width (ataxia.runtime:output-width runtime-output)
             :height (ataxia.runtime:output-height runtime-output)
             :scale (ataxia.runtime:output-scale runtime-output)
             :transform (ataxia.runtime:output-transform runtime-output)
             :enabled-p (ataxia.runtime:output-enabled-p runtime-output))))
      (%register-object kernel output :runtime-object runtime-output)
      (setf (gethash runtime-output (%kernel-output-table kernel)) output)
      (%call-world kernel world-output-added output)
      output)))

(defun %reset-output-swapchain (output)
  (when (%output-swapchain output)
    (ataxia.runtime:destroy-output-swapchain (%output-swapchain output))
    (setf (%output-swapchain output) nil))
  (clrhash (%output-target-tokens output))
  output)

(defun %cancel-output-retry (output)
  (when (%output-retry-timer output)
    (ataxia.runtime:remove-event-loop-source (%output-retry-timer output))
    (setf (%output-retry-timer output) nil))
  output)

(defun %schedule-output-retry (output)
  (let* ((failures (incf (%output-consecutive-frame-failures output)))
         (delay (min 1000 (* 16 (ash 1 (min 6 (1- failures)))))))
    (if (> failures 8)
        (when (= failures 9)
          (format *error-output*
                  "[kernel] pausing automatic frame retries for output ~A.~%"
                  (output-name output)))
        (progn
          (unless (%output-retry-timer output)
            (setf (%output-retry-timer output)
                  (ataxia.runtime:add-event-loop-timer
                   (kernel-runtime (object-kernel output))
                   (lambda (source)
                     (declare (ignore source))
                     (when (eq (object-state output) :live)
                       (request-output-frame output))
                     0))))
          (ataxia.runtime:update-event-loop-timer
           (%output-retry-timer output) delay))))
  output)

(defun %retire-output (output &key (protocol-active-p t))
  (when (eq (object-state output) :live)
    (let ((kernel (object-kernel output)))
      (%call-world kernel world-output-removing output)
      (%cancel-output-retry output)
      (%reset-output-swapchain output)
      (dolist (surface (%hash-values (%kernel-surface-table kernel)))
        (when (gethash output (%surface-output-membership surface))
          (when protocol-active-p
            (ataxia.runtime:surface-send-leave
             (surface-runtime-object surface)
             (output-runtime-object output)))
          (remhash output (%surface-output-membership surface))))
      (remhash (output-runtime-object output) (%kernel-output-table kernel))
      (%retire-object
       kernel output :runtime-object (output-runtime-object output))))
  output)

(defun request-output-frame (output)
  "Request one frame; calls made during rendering latch one following frame."
  (check-type output kernel-output)
  (when (and (eq (object-state output) :live)
             (output-enabled-p output))
    (if (%output-frame-active-p output)
        (setf (%output-next-frame-requested-p output) t)
        (unless (%output-frame-requested-p output)
          (setf (%output-frame-requested-p output) t)
          (ataxia.runtime:output-schedule-frame
           (output-runtime-object output)))))
  output)

(defun %ensure-output-swapchain (output)
  (or (%output-swapchain output)
      (let ((swapchain
              (ataxia.runtime:configure-output-swapchain
               (output-runtime-object output))))
        (setf (%output-swapchain output) swapchain)
        (incf (%output-swapchain-generation output))
        (clrhash (%output-target-tokens output))
        swapchain)))

(defun %intern-target-token (output buffer)
  (let* ((address (ataxia.runtime:native-object-address buffer))
         (table (%output-target-tokens output)))
    (or (gethash address table)
        (setf (gethash address table)
              (make-instance
               'output-target-token
               :output output
               :generation (%output-swapchain-generation output)
               :native-address address)))))

(defun %frame-timestamp (kernel)
  (let* ((now (/ (get-internal-real-time)
                 (coerce internal-time-units-per-second 'double-float)))
         (sampled-at (%kernel-frame-clock-sampled-at kernel)))
    (when (or (minusp sampled-at) (> (- now sampled-at) 0.002d0))
      (setf (%kernel-frame-clock-time kernel) now
            (%kernel-frame-clock-sampled-at kernel) now))
    (%kernel-frame-clock-time kernel)))

(defun %valid-damage-rectangle-p (rectangle width height)
  (and (typep rectangle 'frame-damage-rectangle)
       (<= 0 (frame-damage-rectangle-x rectangle))
       (<= 0 (frame-damage-rectangle-y rectangle))
       (plusp (frame-damage-rectangle-width rectangle))
       (plusp (frame-damage-rectangle-height rectangle))
       (<= (+ (frame-damage-rectangle-x rectangle)
              (frame-damage-rectangle-width rectangle))
           width)
       (<= (+ (frame-damage-rectangle-y rectangle)
              (frame-damage-rectangle-height rectangle))
           height)))

(defun %validate-protocol-token (kernel token)
  (and (typep token 'surface-protocol-token)
       (let ((surface (%protocol-token-surface token)))
         (and (eq kernel (object-kernel surface))
              (eq (object-state surface) :live)
              (= (%protocol-token-generation token)
                 (surface-commit-sequence surface))))))

(defun %validate-frame-result (kernel lease result)
  (unless (typep result 'world-frame-result)
    (error "World returned ~S instead of WORLD-FRAME-RESULT." result))
  (unless (and (frame-result-complete-p result)
               (eq (frame-target-token lease)
                   (frame-result-target-token result)))
    (error "World returned an incomplete result or the wrong target token."))
  (map nil
       (lambda (rectangle)
         (unless (%valid-damage-rectangle-p
                  rectangle (frame-width lease) (frame-height lease))
           (error "World returned out-of-bounds frame damage ~S." rectangle)))
       (frame-result-damage result))
  (map nil
       (lambda (token)
         (unless (%validate-protocol-token kernel token)
           (error "World returned an invalid Wayland protocol token.")))
       (frame-result-presentation-tokens result))
  result)

(defun %runtime-damage (rectangles)
  (map 'list
   (lambda (rectangle)
     (ataxia.runtime:make-damage-rectangle
      (frame-damage-rectangle-x rectangle)
      (frame-damage-rectangle-y rectangle)
      (frame-damage-rectangle-width rectangle)
      (frame-damage-rectangle-height rectangle)))
   rectangles))

(defun %notify-presented-surfaces (output result)
  (let ((runtime-output (output-runtime-object output))
        (seen (make-hash-table :test #'eq)))
    (map nil
         (lambda (token)
           (let ((surface (%protocol-token-surface token)))
             (unless (gethash surface seen)
               (setf (gethash surface seen) t)
               (ataxia.runtime:mark-surface-textured-on-output
                (surface-runtime-object surface) runtime-output)
               (ataxia.runtime:surface-send-frame-done
                (surface-runtime-object surface)))))
         (frame-result-presentation-tokens result))))

(defun %execute-world-frame
    (output framebuffer target-token buffer-width buffer-height)
  (let* ((kernel (object-kernel output))
         (world (kernel-world kernel))
         (lease
           (make-instance
            'frame-lease
            :output output
            :target-token target-token
            :framebuffer framebuffer
            :width buffer-width
            :height buffer-height
            :scale (output-scale output)
            :transform (output-transform output)
            :timestamp (%frame-timestamp kernel)
            :generation (%output-swapchain-generation output))))
    (unwind-protect
         (ataxia.runtime:call-with-egl-context
          (ataxia.runtime:runtime-egl (kernel-runtime kernel))
          (lambda ()
            (%gl-bind-framebuffer +gl-framebuffer+ framebuffer)
            (%gl-viewport 0 0 buffer-width buffer-height)
            (%validate-frame-result
             kernel lease
             (%call-world-on kernel world world-render lease))))
      (setf (frame-lease-valid-p lease) nil))))

(defun %commit-world-frame (output buffer result)
  (let* ((kernel (object-kernel output))
         (runtime-output (output-runtime-object output))
         (state (ataxia.runtime:create-output-state runtime-output)))
    (unwind-protect
         (progn
           (ataxia.runtime:output-state-set-buffer state buffer)
           (ataxia.runtime:output-state-set-damage
            state (%runtime-damage (frame-result-damage result)))
           ;; This state only changes the rendered buffer and damage. The
           ;; swapchain is already configured, and commit validates the state
           ;; itself. A separate test duplicates the DRM atomic submission on
           ;; every frame. Configuration changes retain their explicit tests.
           (unless (ataxia.runtime:output-commit-state runtime-output state)
             (%call-world
              kernel world-frame-failed
              output result :output-commit-failed)
             (return-from %commit-world-frame nil))
           (%refresh-output-object output)
           (%call-world
            kernel world-frame-committed output result :committed)
           (%notify-presented-surfaces output result)
           t)
      (ataxia.runtime:destroy-output-state state))))

(defun %render-output-frame (output)
  (let ((kernel (object-kernel output))
        (buffer nil)
        (result nil)
        (committed-p nil))
    (setf (%output-frame-requested-p output) nil
          (%output-frame-active-p output) t)
    (unwind-protect
         (progn
           (handler-case
               (let* ((swapchain (%ensure-output-swapchain output))
                      (acquired-buffer
                        (ataxia.runtime:acquire-output-buffer swapchain)))
                 (setf buffer acquired-buffer)
                 (let* ((framebuffer
                          (ataxia.runtime:output-buffer-framebuffer
                           (ataxia.runtime:runtime-renderer
                            (kernel-runtime kernel))
                           buffer))
                        (target-token (%intern-target-token output buffer)))
                   (setf result
                         (%execute-world-frame
                          output framebuffer target-token
                          (ataxia.runtime:buffer-width buffer)
                          (ataxia.runtime:buffer-height buffer)))))
             (serious-condition (cause)
               (%call-world
                kernel world-frame-failed output result cause)
               (setf result nil)))
           (when result
             (setf committed-p (%commit-world-frame output buffer result))))
      (when buffer
        (ataxia.runtime:release-buffer buffer))
      (setf (%output-frame-active-p output) nil)
      (if committed-p
          (progn
            (setf (%output-consecutive-frame-failures output) 0)
            (%cancel-output-retry output)
            (when (%output-next-frame-requested-p output)
              (setf (%output-next-frame-requested-p output) nil)
              (request-output-frame output)))
          (progn
            (setf (%output-next-frame-requested-p output) nil)
            (when (eq (object-state output) :live)
              (%schedule-output-retry output)))))))

(defun set-wayland-surface-output-membership (token outputs)
  "Apply World-computed output membership for one opaque Wayland surface token."
  (unless (typep token 'surface-protocol-token)
    (error "Expected a Kernel-owned Wayland surface token."))
  (let* ((surface (%protocol-token-surface token))
         (kernel (object-kernel surface))
         (current (%surface-output-membership surface))
         (desired (make-hash-table :test #'eq)))
    (unless (%validate-protocol-token kernel token)
      (error "Wayland surface token is no longer live."))
    (dolist (output outputs)
      (check-type output kernel-output)
      (unless (and (eq kernel (object-kernel output))
                   (eq (object-state output) :live))
        (error "Output does not belong to this live Wayland surface."))
      (setf (gethash output desired) t)
      (unless (gethash output current)
        (ataxia.runtime:surface-send-enter
         (surface-runtime-object surface)
         (output-runtime-object output))))
    (maphash
     (lambda (output present-p)
       (declare (ignore present-p))
       (unless (gethash output desired)
         (ataxia.runtime:surface-send-leave
          (surface-runtime-object surface)
          (output-runtime-object output))))
     current)
    (clrhash current)
    (maphash
     (lambda (output present-p)
       (declare (ignore present-p))
       (setf (gethash output current) t))
     desired)
    (let ((preferred-scale
            (and outputs (reduce #'max outputs :key #'output-scale))))
      (unless (eql preferred-scale (%surface-preferred-scale surface))
        (setf (%surface-preferred-scale surface) preferred-scale)
        (when preferred-scale
          (ataxia.runtime:notify-surface-preferred-scale
           (surface-runtime-object surface) preferred-scale))))
    token))
