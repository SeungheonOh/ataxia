;;;; Screen sharing through the desktop portal.
;;;;
;;;; The native bridge owns the portal's ScreenCast backend and one PipeWire
;;;; stream per session. What to share is the director's choice: requests reach
;;;; it in `shares` reports and return as `share-accept` or `share-cancel`. An
;;;; accepted window is captured from its own surfaces, a screen or region from
;;;; Stage's display list, both through the EGL context so sharing never forces
;;;; an output frame. A source is captured only after it changed, at most 30
;;;; times a second; a still one is resent four times a second to keep its
;;;; stream alive. With no share running, nothing wakes.

(in-package #:ataxia.stage-world)

(defparameter +share-interval+ 0.033d0 "Shortest time between captures of one source.")
(defparameter +share-keepalive+ 0.25d0 "Longest time a still source goes without a frame.")
(defparameter +share-size+ '(1920 . 1080) "Largest stream size; larger sources scale down.")

(defstruct (share (:constructor %make-share (id types app)))
  (id 0 :read-only t)
  ;; Portal source types the client accepts: 1 screen, 2 window.
  (types 0 :read-only t)
  (app "" :read-only t)
  ;; NIL until accepted, then :WINDOW or :SCREEN.
  (source nil)
  (window nil)
  (output nil)
  ;; Output-logical (X Y WIDTH HEIGHT) shared from OUTPUT.
  (region nil)
  (width 0 :type fixnum)
  (height 0 :type fixnum)
  (pixels nil)
  (dirty-p t)
  (submitted-at 0d0 :type double-float)
  ;; Render targets at the stream's size and, for screens, at the output's.
  (target nil)
  (output-target nil))

(defstruct (share-controller (:constructor %make-share-controller (native)))
  (native nil :read-only t)
  (source nil)
  (timer nil)
  (shares nil :type list))

(defun %sharing (world)
  (ataxia.world:world-service world :screen-sharing))

(defun share-descriptions (world)
  "Copied share states for the director."
  (let ((controller (%sharing world)))
    (if (null controller)
        #()
        (map 'vector
           (lambda (share)
             (list :id (share-id share) :app (share-app share)
                   :types (coerce (append (when (logtest 1 (share-types share)) '("screen"))
                                          (when (logtest 2 (share-types share)) '("window")))
                                  'vector)
                   :source (and (share-source share) (string-downcase (symbol-name (share-source share))))
                   :window (and (share-window share) (stage-window-id (share-window share)))
                   :output (and (share-output share) (%output-name (share-output share)))))
           (share-controller-shares controller)))))

(defun %report-shares (world)
  (%send world (list :type "shares" :shares (share-descriptions world))))

(defun %release-share-targets (world share)
  (when (or (share-target share) (share-output-target share))
    (%call-with-gl world (lambda ()
                           (destroy-render-target (share-target share))
                           (destroy-render-target (share-output-target share))))
    (setf (share-target share) nil
          (share-output-target share) nil)))

(defun %forget-share (world share)
  (let ((controller (%sharing world)))
    (%release-share-targets world share)
    (setf (share-controller-shares controller) (remove share (share-controller-shares controller)))
    (%schedule-capture controller)
    (%report-shares world)))

(defun %close-share (world share)
  (ataxia.screencast.native::close-session (share-controller-native (%sharing world)) (share-id share))
  (%forget-share world share))

(defun %share-events (world controller)
  (cffi:with-foreign-object (event '(:struct ataxia.screencast.native::event))
    (loop while (plusp (ataxia.screencast.native::next (share-controller-native controller) event))
          do (cffi:with-foreign-slots ((ataxia.screencast.native::kind ataxia.screencast.native::id
                                        ataxia.screencast.native::types)
                                       event (:struct ataxia.screencast.native::event))
               (let ((id ataxia.screencast.native::id))
                 (if (= 1 ataxia.screencast.native::kind)
                     (setf (share-controller-shares controller)
                           (append (share-controller-shares controller)
                                   (list (%make-share
                                          id ataxia.screencast.native::types
                                          (cffi:foreign-string-to-lisp
                                           (cffi:foreign-slot-pointer
                                            event '(:struct ataxia.screencast.native::event)
                                            'ataxia.screencast.native::app))))))
                     ;; The client or the portal ended the session.
                     (let ((share (find id (share-controller-shares controller) :key #'share-id)))
                       (when share (%forget-share world share))))))))
  (%report-shares world))

(defun %find-share (world id)
  (let ((controller (or (%sharing world) (protocol-error "Screen sharing is not enabled."))))
    (or (find id (share-controller-shares controller) :key #'share-id)
        (protocol-error "Unknown share ~S." id))))

(defun accept-share (world id &key window output region)
  "Start sharing WINDOW, or OUTPUT's REGION (or all of it), for request ID."
  (let ((share (%find-share world id))
        (type (if window 2 1)))
    (when (share-source share) (protocol-error "Share ~S is already running." id))
    (unless (logtest type (share-types share))
      (protocol-error "The client did not ask to share a ~:[window~;screen~]." (= type 1)))
    (multiple-value-bind (x y source-width source-height) (source-pixels window output region)
      (multiple-value-bind (width height)
          (fit-size source-width source-height (car +share-size+) (cdr +share-size+))
        (setf (share-source share) (if window :window :screen)
              (share-window share) window
              (share-output share) output
              (share-region share) region
              (share-width share) width
              (share-height share) height
              (share-pixels share) (make-array (* width height 4) :element-type '(unsigned-byte 8))
              (share-dirty-p share) t)
        (ataxia.screencast.native::accept-source (share-controller-native (%sharing world))
                                                 id type x y width height)))
    (%schedule-capture (%sharing world))
    (%report-shares world)))

(defun cancel-share (world id)
  (%close-share world (%find-share world id)))

;;; Change tracking.

(defun %running-shares (controller)
  (remove nil (share-controller-shares controller) :key #'share-source))

(defun %share-due-at (share)
  "When SHARE next needs a frame: soon after a change, else to keep its stream alive."
  (+ (share-submitted-at share) (if (share-dirty-p share) +share-interval+ +share-keepalive+)))

(defun %schedule-capture (controller)
  "Wake when the next running share is due; with none running, never."
  (let ((running (%running-shares controller)))
    (ataxia.runtime:update-event-loop-timer
     (share-controller-timer controller)
     (if running
         (max 1 (ceiling (* 1000 (- (reduce #'min running :key #'%share-due-at) (%now)))))
         0))))

(defun %mark-changed (world predicate)
  "Mark the clean running shares PREDICATE accepts as changed."
  (let ((controller (%sharing world))
        (changed nil))
    (when controller
      (dolist (share (%running-shares controller))
        (when (and (not (share-dirty-p share)) (funcall predicate share))
          (setf (share-dirty-p share) t changed t)))
      (when changed (%schedule-capture controller)))))

(defun %share-area (share)
  "The buffer rectangle a screen SHARE shows of its output, or NIL for all of it."
  (let ((region (share-region share)))
    (when region
      (destructuring-bind (x y width height) region
        (affine-rectangle-bounds (%buffer-transform (share-output share)) x y width height)))))

(defun note-output-presented (world stage-output damage)
  "STAGE-OUTPUT repainted the buffer rectangles DAMAGE; screen shares showing any of them change."
  (%mark-changed world (lambda (share)
                         (and (eq stage-output (share-output share))
                              (let ((area (%share-area share)))
                                (or (null area)
                                    (some (lambda (rectangle) (%rectangles-overlap-p rectangle area))
                                          damage)))))))

(defun note-window-changed (world window &key gone-p)
  "WINDOW committed new content, or with GONE-P stopped existing for sharing."
  (if gone-p
      (let ((controller (%sharing world)))
        (when controller
          (dolist (share (share-controller-shares controller))
            (when (eq window (share-window share)) (%close-share world share)))))
      (%mark-changed world (lambda (share) (eq window (share-window share))))))

(defmethod ataxia.world:service-output-removing ((controller share-controller) world output)
  (dolist (share (share-controller-shares controller))
    (let ((stage-output (share-output share)))
      (when (and stage-output (eq output (stage-output-output stage-output)))
        (%close-share world share)))))

;;; Capture.

(defun %window-share-bounds (window width height)
  "WINDOW's bounds letterboxed to the stream's aspect, which stays fixed as it resizes."
  (multiple-value-bind (x y content-width content-height) (%window-bounds window)
    (let ((ratio (/ width height)))
      (if (> (/ content-width (max 1d0 content-height)) ratio)
          (let ((expanded (/ content-width ratio)))
            (list x (- y (/ (- expanded content-height) 2)) content-width expanded))
          (let ((expanded (* content-height ratio)))
            (list (- x (/ (- expanded content-width) 2)) y expanded content-height))))))

(defun %capture (world share)
  "Read SHARE's source into its pixels."
  (let* ((width (share-width share))
         (height (share-height share))
         (target (setf (share-target share) (fitted-target (share-target share) width height))))
    (if (eq (share-source share) :screen)
        (let ((stage-output (share-output share)))
          (setf (share-output-target share)
                (fitted-target (share-output-target share) (stage-output-buffer-width stage-output)
                               (stage-output-buffer-height stage-output)))
          (read-output-pixels world stage-output (share-region share) width height (share-pixels share)
                              (share-output-target share) target))
        (let ((window (share-window share)))
          (read-window-pixels world window (%window-share-bounds window width height) width height
                              (share-pixels share) target)
          ;; A shared window keeps drawing even where no output shows it.
          (loop for surface across (ataxia.kernel:drawable-surfaces (stage-window-application window))
                for token = (ataxia.kernel:drawable-surface-presentation-token surface)
                when token do (ataxia.kernel:complete-wayland-surface-frame token))))))

(defun %submit (controller share)
  (let ((pixels (share-pixels share)))
    (sb-sys:with-pinned-objects (pixels)
      (ataxia.screencast.native::submit (share-controller-native controller) (share-id share)
                                        (sb-sys:vector-sap pixels) (length pixels))))
  (setf (share-submitted-at share) (%now)))

(defun %share-tick (world controller)
  (let ((timer (share-controller-timer controller)))
    (if (null (%renderer world))
        ;; Nothing can be captured without graphics; look again shortly.
        (ataxia.runtime:update-event-loop-timer timer (ceiling (* 1000 +share-keepalive+)))
        (let* ((now (%now))
               (due (remove-if-not (lambda (share) (<= (%share-due-at share) now))
                                   (%running-shares controller)))
               (failed nil))
          (%call-with-gl world
                         (lambda ()
                           (dolist (share due)
                             (handler-case
                                 (progn
                                   (when (share-dirty-p share) (%capture world share))
                                   (setf (share-dirty-p share) nil)
                                   (%submit controller share))
                               (error (cause)
                                 (%log "screen sharing stopped: ~A" cause)
                                 (push share failed))))))
          (mapc (lambda (share) (%close-share world share)) failed)
          (%schedule-capture controller)))))

;;; Lifecycle.

(defun enable-screen-sharing (world)
  "Own the portal's ScreenCast backend for WORLD. Call on the owner thread."
  (or (%sharing world)
      (let* ((native (progn (ataxia.screencast.native::initialize) (ataxia.screencast.native::create)))
             (controller (%make-share-controller native))
             (runtime (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))))
        (when (cffi:null-pointer-p native)
          (error "Could not own the Ataxia screen-sharing portal on the session bus."))
        (setf (share-controller-source controller)
              (ataxia.runtime:add-event-loop-fd
               runtime (ataxia.screencast.native::fd native) ataxia.runtime:+event-readable+
               (%guarded world :stage-screencast
                         (lambda (source fd mask)
                           (declare (ignore source fd mask))
                           (%share-events world controller))))
              (share-controller-timer controller)
              (ataxia.runtime:add-event-loop-timer
               runtime (%guarded world :stage-screencast
                                 (lambda (source)
                                   (declare (ignore source))
                                   (%share-tick world controller)))))
        (ataxia.world:attach-world-service world :screen-sharing controller))))

(defun disable-screen-sharing (world)
  (let ((controller (%sharing world)))
    (when controller
      (dolist (share (share-controller-shares controller))
        (%release-share-targets world share))
      (dolist (source (list (share-controller-source controller) (share-controller-timer controller)))
        (ataxia.runtime:remove-event-loop-source source))
      (ataxia.screencast.native::destroy (share-controller-native controller))
      (ataxia.world:detach-world-service world :screen-sharing))))

(defmethod ataxia.world:service-quiescing ((controller share-controller) world reason)
  (declare (ignore reason))
  (disable-screen-sharing world))
