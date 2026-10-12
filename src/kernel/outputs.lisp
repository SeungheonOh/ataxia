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

(cffi:defcfun ("glGetString" %gl-get-string) :pointer
  (name :uint32))

(cffi:defcfun ("eglGetProcAddress" %egl-get-proc-address) :pointer
  (name :string))

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
      (when (%output-render-timer output)
        (ataxia.runtime:remove-event-loop-source (shiftf (%output-render-timer output) nil)))
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

;;; Frame pacing.
;;;
;;; While frames follow one another, each frame event comes as the previous one
;;; reaches the screen. Rendering then would leave anything clients commit in the
;;; rest of the refresh waiting a whole extra frame, so on outputs presenting on
;;; vblank such a frame starts as late as it can and still meet the next vblank:
;;; that is predicted from the last presentation and the refresh, and a frame's
;;; cost is the decaying peak of recent frames, grown whenever one misses. A frame
;;; that may not fit before the next vblank starts at once, as does one requested
;;; on a still screen and the few after it: an animation's first frames do more
;;; than the still frames before them, which their cost does not know yet.

(defconstant +frame-margin+ 2000000
  "Nanoseconds kept beyond a frame's measured cost, for the GPU and wakeup latency.")

(defconstant +flip-window+ 2000000
  "Nanoseconds from a vblank within which a frame event follows that frame's flip.")

(defconstant +paced-after+ 3
  "Frames in a row following flips before frames start late.")

(defun %monotonic-nanoseconds ()
  (multiple-value-bind (seconds nanoseconds) (sb-unix:clock-gettime sb-unix:clock-monotonic)
    (+ (* seconds 1000000000) nanoseconds)))

(defun %frame-delay (output)
  "Milliseconds before OUTPUT's frame must start to meet the next vblank; 0 starts it
now. Records the vblank a delayed frame aims for."
  (let* ((vblank (%output-vblank output))
         (refresh (%output-refresh output))
         (now (%monotonic-nanoseconds))
         (following-p (and vblank (plusp refresh) (<= (- now vblank) +flip-window+))))
    (setf (%output-target-vblank output) nil
          (%output-streak output) (if following-p (1+ (%output-streak output)) 0))
    (if (< (%output-streak output) +paced-after+)
        0
        (let* ((lead (+ (%output-frame-cost output) (%output-gpu-cost output) +frame-margin+))
               ;; Flip events report the vblank just presented a moment ahead of now.
               (next (+ vblank refresh))
               ;; Negative when the frame may miss NEXT; waiting for the vblank
               ;; after it would halve the frame rate, so it starts at once.
               (delay (floor (- next lead now) 1000000)))
          (when (plusp delay)
            (setf (%output-target-vblank output) next))
          (max 0 delay)))))

(defun %note-presentation (output nanoseconds refresh vsync-p)
  "Learn OUTPUT's vblank timing from a presentation; a frame that came out after the
vblank it aimed for makes later frames start earlier."
  (let ((target (shiftf (%output-target-vblank output) nil)))
    (when (and target (> nanoseconds (+ target (floor refresh 2))))
      (incf (%output-frame-cost output) +frame-margin+)))
  (setf (%output-vblank output) (and vsync-p nanoseconds)
        (%output-refresh output) refresh))

(defun %note-frame-cost (output nanoseconds)
  "Fold one frame's cost into OUTPUT's estimate: the peak, decaying 1/16 a frame."
  (setf (%output-frame-cost output)
        (max nanoseconds (floor (* 15 (%output-frame-cost output)) 16) 1000000)))

;;; GPU timing. A frame's cost is mostly the GPU's work, which runs after the
;;; CPU has submitted it. Timestamp queries around the World's drawing measure
;;; it without waiting; results are read a frame or two later.

(defconstant +gl-extensions+ #x1f03)
(defconstant +gl-timestamp+ #x8e28)
(defconstant +gl-query-result+ #x8866)
(defconstant +gl-query-result-available+ #x8867)

(defvar *gpu-timer* :unknown
  "Entry points of EXT_disjoint_timer_query: gen, counter, available and result; or
NIL when the driver lacks it.")

(defun %gpu-timer ()
  "Call with a GL context current."
  (when (eq *gpu-timer* :unknown)
    (let ((extensions (%gl-get-string +gl-extensions+)))
      (setf *gpu-timer*
            (and (not (cffi:null-pointer-p extensions))
                 (search "GL_EXT_disjoint_timer_query" (cffi:foreign-string-to-lisp extensions))
                 (mapcar #'%egl-get-proc-address
                         '("glGenQueriesEXT" "glQueryCounterEXT" "glGetQueryObjectivEXT"
                           "glGetQueryObjectui64vEXT"))))))
  *gpu-timer*)

(defun %gpu-timestamp (query)
  (cffi:foreign-funcall-pointer (second (%gpu-timer)) () :uint32 query :uint32 +gl-timestamp+ :void))

(defun %collect-gpu-cost (output)
  "Fold the GPU times of OUTPUT's finished frames into its estimate, as frame costs fold."
  (destructuring-bind (gen counter available result) (%gpu-timer)
    (declare (ignore gen counter))
    (cffi:with-foreign-objects ((ready :int32) (start :uint64) (end :uint64))
      (loop for pair in (reverse (%output-gpu-queries output))
            do (cffi:foreign-funcall-pointer available () :uint32 (cdr pair)
                                             :uint32 +gl-query-result-available+ :pointer ready :void)
               (when (zerop (cffi:mem-ref ready :int32)) (return))
               (cffi:foreign-funcall-pointer result () :uint32 (car pair) :uint32 +gl-query-result+
                                             :pointer start :void)
               (cffi:foreign-funcall-pointer result () :uint32 (cdr pair) :uint32 +gl-query-result+
                                             :pointer end :void)
               (setf (%output-gpu-cost output)
                     (max (- (cffi:mem-ref end :uint64) (cffi:mem-ref start :uint64))
                          (floor (* 15 (%output-gpu-cost output)) 16))
                     (%output-gpu-queries output) (remove pair (%output-gpu-queries output)))
               (push pair (%output-free-gpu-queries output))))))

(defun %begin-gpu-timing (output)
  "Start timing the GPU work of OUTPUT's frame; return the query pair, if any."
  (when (%gpu-timer)
    (%collect-gpu-cost output)
    ;; Results arrive within a frame or two; a backlog means they stopped coming.
    (when (< (length (%output-gpu-queries output)) 4)
      (let ((pair (or (pop (%output-free-gpu-queries output))
                      (cffi:with-foreign-object (ids :uint32 2)
                        (cffi:foreign-funcall-pointer (first (%gpu-timer)) () :int32 2 :pointer ids :void)
                        (cons (cffi:mem-aref ids :uint32 0) (cffi:mem-aref ids :uint32 1))))))
        (%gpu-timestamp (car pair))
        pair))))

(defun %end-gpu-timing (output pair)
  (when pair
    (%gpu-timestamp (cdr pair))
    (push pair (%output-gpu-queries output))))

;;; Garbage collection. A collection stops everything for 3-6 ms, however little
;;; is allocated; landing in a frame it makes that frame miss its vblank. When the
;;; heap nears its next collection, it runs where the CPU would wait anyway: while
;;; a frame waits to start, or after one is committed while the GPU draws it. A
;;; frame too close to its vblank for either starts at once instead of late,
;;; making room after it. Collections come at most a quarter of an allowance
;;; early, so there are hardly more of them.

(defconstant +collection-slack+ 8
  "Milliseconds of waiting a collection needs to run in it.")

(defun %collection-due-p ()
  "Whether the heap has allocated three quarters of what triggers its next collection."
  (< (- (sb-alien:extern-alien "auto_gc_trigger" sb-alien:unsigned) (sb-kernel:dynamic-usage))
     (floor (sb-ext:bytes-consed-between-gcs) 4)))

(defun %collect-before-vblank (output)
  "After OUTPUT's frame is committed, collect if one is due and the next vblank,
when the next frame starts, is far enough away."
  (let ((vblank (%output-vblank output))
        (refresh (%output-refresh output)))
    (when (and vblank (plusp refresh) (%collection-due-p))
      (let* ((now (%monotonic-nanoseconds))
             (next (+ vblank (* refresh (max 1 (ceiling (- now vblank) refresh))))))
        (when (>= (- next now) (* +collection-slack+ 1000000))
          (sb-ext:gc))))))

(defun start-output-frame (output)
  "Render OUTPUT's requested frame now, or as late as still meets the next vblank."
  (let ((delay (%frame-delay output)))
    (when (and (plusp delay) (%collection-due-p))
      (if (>= delay +collection-slack+)
          (let ((start (%monotonic-nanoseconds)))
            (sb-ext:gc)
            (setf delay (max 0 (- delay (ceiling (- (%monotonic-nanoseconds) start) 1000000)))))
          (setf delay 0)))
    (if (zerop delay)
        (%render-output-frame output)
        (ataxia.runtime:update-event-loop-timer
         (or (%output-render-timer output)
             (setf (%output-render-timer output)
                   (ataxia.runtime:add-event-loop-timer
                    (kernel-runtime (object-kernel output))
                    (lambda (source)
                      (declare (ignore source))
                      (when (and (eq (object-state output) :live)
                                 (output-enabled-p output)
                                 (%output-frame-requested-p output))
                        (%render-output-frame output))
                      0))))
         delay))))

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
  (dolist (tokens (list (frame-result-presentation-tokens result) (frame-result-callback-tokens result)))
    (map nil
         (lambda (token)
           (unless (%validate-protocol-token kernel token)
             (error "World returned an invalid Wayland protocol token.")))
         tokens))
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

(defun %frame-surfaces (result)
  "Surfaces RESULT shows, then those it only lets progress, each once."
  ;; A frame shows a handful of surfaces: a list beats a hash table made per frame.
  (let ((seen nil))
    (flet ((surfaces (tokens)
             (loop for token being the elements of tokens
                   for surface = (%protocol-token-surface token)
                   unless (member surface seen :test #'eq)
                     do (push surface seen)
                     and collect surface)))
      (let ((presented (surfaces (frame-result-presentation-tokens result))))
        (values presented (surfaces (frame-result-callback-tokens result)))))))

(defun %mark-presented-surfaces (output presented)
  "Attach the presentation feedback of PRESENTED surfaces to OUTPUT's next commit,
which wlroots requires to happen before that commit."
  (let ((runtime-output (output-runtime-object output)))
    (dolist (surface presented)
      (ataxia.runtime:mark-surface-textured-on-output (surface-runtime-object surface) runtime-output))))

(defun %send-frame-done (surfaces)
  (dolist (surface surfaces)
    (ataxia.runtime:surface-send-frame-done (surface-runtime-object surface))))

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
            (let ((timing (%begin-gpu-timing output)))
              (prog1 (%validate-frame-result
                      kernel lease
                      (%call-world-on kernel world world-render lease))
                (%end-gpu-timing output timing)))))
      (setf (frame-lease-valid-p lease) nil))))

(defun %commit-world-frame (output buffer result)
  (let* ((kernel (object-kernel output))
         (runtime-output (output-runtime-object output))
         (state (ataxia.runtime:create-output-state runtime-output)))
    (unwind-protect
         (multiple-value-bind (presented progressing) (%frame-surfaces result)
           (ataxia.runtime:output-state-set-buffer state buffer)
           (ataxia.runtime:output-state-set-damage
            state (%runtime-damage (frame-result-damage result)))
           (%mark-presented-surfaces output presented)
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
           (%send-frame-done presented)
           (%send-frame-done progressing)
           t)
      (ataxia.runtime:destroy-output-state state))))

(defun %render-output-frame (output)
  (let ((kernel (object-kernel output))
        (buffer nil)
        (result nil)
        (committed-p nil)
        (started (%monotonic-nanoseconds)))
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
            (%note-frame-cost output (- (%monotonic-nanoseconds) started))
            (%collect-before-vblank output)
            (setf (%output-consecutive-frame-failures output) 0)
            (%cancel-output-retry output)
            (when (%output-next-frame-requested-p output)
              (setf (%output-next-frame-requested-p output) nil)
              (request-output-frame output)))
          (progn
            (setf (%output-next-frame-requested-p output) nil)
            (when (eq (object-state output) :live)
              (%schedule-output-retry output)))))))

(defun complete-wayland-surface-frame (token)
  "Release frame callbacks for a live surface without claiming display presentation.
World uses this for offscreen consumers; the opaque token still identifies the
exact live surface commit, as it does for output rendering."
  (unless (and (typep token 'surface-protocol-token)
               (%validate-protocol-token (object-kernel (%protocol-token-surface token)) token))
    (error "Wayland surface token is no longer live."))
  (ataxia.runtime:surface-send-frame-done (surface-runtime-object (%protocol-token-surface token)))
  nil)

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
