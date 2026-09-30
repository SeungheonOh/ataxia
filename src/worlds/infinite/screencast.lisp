;;;; Source selection, consent UI, and capture are World policy.
(in-package #:ataxia.infinite-world)
(eval-when (:compile-toplevel :load-toplevel :execute)
  (export '(enable-screen-sharing disable-screen-sharing)))

;; A captured application's drawable revision includes its popup/subsurface
;; changes. Keep unchanged pixels without waking an output or doing GL readback.
;; Weak keys also permit live code updates without changing session struct layout.
(defvar *share-frame-revisions* (make-hash-table :test #'eq :weakness :key))

(defvar *screen-sharing-kernels* (make-hash-table :test #'eq :weakness :key))

(defstruct share-session id app types window bounds (rotation 0d0) width height pixels active-p)
(defstruct share-controller world native source timer sessions current picker region indicators seat previous-focus due-p)
(defclass share-region-component (ataxia.world.web.ui:document-component)
  ((controller :initarg :controller :reader %share-region-controller)
   (start :initform nil :accessor %share-region-start)))

(defun %share-widget (controller file state width height &key (layer 5000) factory)
  (multiple-value-bind (ow oh) (%output-logical-size state)
    (ataxia.world:create-agent-widget 'ataxia.world.web.ui:document-widget
      (share-controller-world controller) ""
      :source-path (namestring (asdf:system-relative-pathname "ataxia-screencast"
                                (format nil "src/world/screencast/~A.html" file)))
      :component-factory (or factory (lambda (&rest args) (apply #'ataxia.world.web.ui:make-ui-component :world (share-controller-world controller) args)))
      :output (%canvas-output-output state) :width (min width ow) :height (min height oh)
      :x (max 0d0 (/ (- ow width) 2d0)) :y (max 0d0 (/ (- oh height) 2d0)) :layer layer)))

(defun %share-dismiss-picker (controller)
  (let ((world (share-controller-world controller)) (seat (share-controller-seat controller)))
    (dolist (widget (list (share-controller-picker controller) (share-controller-region controller)))
      (when widget (ataxia.world:remove-agent-widget world widget)))
    (when (and seat (member seat (%seat-states world)))
      (let ((previous (share-controller-previous-focus controller)))
        (when (and previous (%target-visible-p previous)) (%focus-target world seat previous))))
    (setf (share-controller-picker controller) nil (share-controller-region controller) nil
          (share-controller-seat controller) nil (share-controller-previous-focus controller) nil
          (share-controller-current controller) nil)))

(defun %share-close (controller session)
  (remhash session *share-frame-revisions*)
  (ataxia.screencast.native::close-session (share-controller-native controller) (share-session-id session))
  (setf (share-controller-sessions controller) (remove session (share-controller-sessions controller)))
  (when (eq session (share-controller-current controller)) (%share-dismiss-picker controller))
  (%share-indicators controller)
  (when (notany #'share-session-active-p (share-controller-sessions controller))
    (ataxia.runtime:update-event-loop-timer (share-controller-timer controller) 0))
  (%share-next-picker controller))

(defun %share-update-selection (controller session)
  (let ((widget (share-controller-picker controller))
        (window (share-session-window session)) (bounds (share-session-bounds session)))
    (when widget
      (ataxia.world.web.ui:set-widget-text widget "selection"
        (cond (window (format nil "Application: ~A" (or (ataxia.kernel:application-title (canvas-window-application window)) "Untitled")))
              (bounds (format nil "Canvas region: ~D × ~D" (round (third bounds)) (round (fourth bounds))))
              (t "Choose an application or draw a canvas region.")))
      (ataxia.world.web.ui:set-ui-attribute (overlay-component widget) "share" "disabled" (unless (or window bounds) "disabled"))
      (loop for candidate in (gethash :share-windows (ataxia.world.web.ui:widget-cache widget))
            for i from 0 for id = (format nil "app~D" i) do
        (ataxia.world.web.ui:cache-widget-value widget (list :selected i) (eq candidate window)
          (lambda (component) (ataxia.world.web.ui:set-ui-class component id "selected" (eq candidate window))))))))

(defun %share-select-window (controller session window)
  (when (and (eq session (share-controller-current controller)) (share-controller-picker controller)
             (member window (%world-stacking (share-controller-world controller))) (%window-visible-p window))
    (setf (share-session-window session) window (share-session-bounds session) nil (share-session-rotation session) 0d0)
    (%share-update-selection controller session)))

(defun %share-accept (controller session)
  ;; A queued second click must not renegotiate or close an accepted stream.
  (unless (and (eq session (share-controller-current controller)) (not (share-session-active-p session)))
    (return-from %share-accept nil))
  (let* ((world (share-controller-world controller)) (window (share-session-window session))
         (bounds (if window (multiple-value-list (ataxia.kernel:drawable-local-bounds (canvas-window-application window)))
                     (share-session-bounds session))))
    (unless (and bounds (plusp (third bounds)) (plusp (fourth bounds))
                 (or (null window) (and (member window (%world-stacking world)) (%window-visible-p window))))
      (return-from %share-accept nil))
    (let* ((factor (min 1d0 (/ 1920d0 (third bounds)) (/ 1080d0 (fourth bounds))))
           (width (max 1 (round (* factor (third bounds)))))
           (height (max 1 (round (* factor (fourth bounds))))))
      (setf (share-session-width session) width (share-session-height session) height
            (share-session-pixels session) (make-array (* width height 4) :element-type '(unsigned-byte 8))
            (share-session-active-p session) t)
      (ataxia.screencast.native::accept-source (share-controller-native controller) (share-session-id session)
        (if window 2 1) (max (- (expt 2 31)) (min (1- (expt 2 31)) (round (first bounds))))
        (max (- (expt 2 31)) (min (1- (expt 2 31)) (round (second bounds)))) width height)
      (%share-dismiss-picker controller)
      (%share-indicators controller)
      (%share-tick controller)
      (%share-next-picker controller))))

(defun %share-begin-region (controller)
  (unless (share-controller-picker controller) (return-from %share-begin-region nil))
  (let* ((world (share-controller-world controller)) (picker (share-controller-picker controller))
         (state (gethash (overlay-output picker) (%world-outputs world))))
    (ataxia.world:configure-agent-widget world picker :visible-p nil)
    (when (share-controller-region controller)
      (ataxia.world:remove-agent-widget world (share-controller-region controller)))
    (multiple-value-bind (width height) (%output-logical-size state)
      (let ((region (%share-widget controller "region" state width height :layer 5100
                      :factory (lambda (&rest args)
                                 (change-class (apply #'ataxia.world.web.ui:make-ui-component :world world args)
                                               'share-region-component :controller controller)))))
        (setf (share-controller-region controller) region)
        (when (share-controller-seat controller) (%focus-target world (share-controller-seat controller) region))))))

(defun %share-region-rectangle (component x y)
  (let* ((start (%share-region-start component)) (controller (%share-region-controller component))
         (widget (share-controller-region controller)))
    (when (and start widget)
      (let ((left (min (first start) x)) (top (min (second start) y))
            (width (abs (- x (first start)))) (height (abs (- y (second start)))))
        (ataxia.world.web.ui:set-widget-style widget "rectangle" "display" "block")
        (loop for property in '("left" "top" "width" "height") for value in (list left top width height) do
          (ataxia.world.web.ui:set-widget-style widget "rectangle" property (format nil "~,2Fdp" value)))
        (list left top width height)))))

(defmethod ataxia.kernel:interactable-pointer-motion
    ((component share-region-component) world seat x y input)
  (declare (ignore world seat input))
  (%share-region-rectangle component x y)
  (ataxia.kernel:make-interaction-result :status :delivered :object component))
(defmethod ataxia.kernel:interactable-pointer-button
    ((component share-region-component) world seat x y input)
  (declare (ignore seat))
  (when (= 272 (ataxia.kernel:cursor-button-input-code input))
    (if (eq :pressed (ataxia.kernel:cursor-button-input-state input))
        (setf (%share-region-start component) (list x y))
        (let* ((controller (%share-region-controller component))
               (rect (%share-region-rectangle component x y))
               (widget (share-controller-region controller))
               (state (gethash (overlay-output widget) (%world-outputs world)))
               (session (share-controller-current controller)))
          (when (and rect (>= (third rect) 8d0) (>= (fourth rect) 8d0))
            ;; Preserve the selected basis, not its world-space bounding box:
            ;; a rotated view must never reveal pixels outside the drawn region.
            (multiple-value-bind (left top) (%screen-to-world state (first rect) (second rect))
              (setf (share-session-window session) nil
                    (share-session-rotation session) (%canvas-output-rotation state)
                    (share-session-bounds session)
                    (list left top (/ (third rect) (%canvas-output-zoom state))
                                   (/ (fourth rect) (%canvas-output-zoom state)))))
            (ataxia.world:configure-agent-widget world widget :visible-p nil)
            (let ((picker (share-controller-picker controller)))
              (ataxia.world:configure-agent-widget world picker :visible-p t)
              (%share-update-selection controller session)
              (when (share-controller-seat controller) (%focus-target world (share-controller-seat controller) picker)))))))
  (ataxia.kernel:make-interaction-result :status :delivered :object component))

(defun %share-next-picker (controller)
  (unless (share-controller-current controller)
    (let* ((world (share-controller-world controller))
           (session (find-if-not #'share-session-active-p (share-controller-sessions controller)))
           (seat (find-if-not (lambda (s) (ataxia.world:agent-seat-p (%canvas-seat-seat s))) (%seat-states world)))
           (state (or (and seat (%canvas-seat-output seat)) (%first-output-state world))))
      (when session
        (unless state (%share-close controller session) (return-from %share-next-picker nil))
        (let* ((windows (when (logtest 2 (share-session-types session)) (remove-if-not #'%window-visible-p (reverse (%world-stacking world)))))
               (source (format nil "~{~A~}" (loop for w in windows for i from 0
                         collect (format nil "<input class='action' type='button' id='app~D' value='Application'>" i))))
               ;; Consecutive text rows, plus labels and wrapped narrow hints.
               (height (+ (if (< (nth-value 0 (%output-logical-size state)) 400d0) 130d0 98d0)
                          (* 16d0 (min 12 (max 3 (length windows))))))
               (widget (%share-widget controller "picker" state 540d0 height)))
          (ataxia.world.web.ui:set-ui-model (overlay-component widget) "sources" source)
          (setf (share-controller-current controller) session (share-controller-picker controller) widget
                (share-controller-seat controller) seat (share-controller-previous-focus controller) (and seat (%canvas-seat-focused seat)))
          (setf (gethash :share-windows (ataxia.world.web.ui:widget-cache widget)) windows)
          (ataxia.world.web.ui:set-widget-text widget "app"
            (format nil "~A wants to share your screen"
              (let ((app (share-session-app session)))
                (cond ((search "firefox" app :test #'char-equal) "Firefox")
                      ((search "discord" app :test #'char-equal) "Discord")
                      ((plusp (length app)) app) (t "An application")))))
          (unless (logtest 1 (share-session-types session)) (ataxia.world.web.ui:set-widget-style widget "region" "display" "none"))
          (loop for window in windows for i from 0 for id = (format nil "app~D" i) do
            (let ((window window))
              (ataxia.world.web.ui:set-widget-text widget id (or (ataxia.kernel:application-title (canvas-window-application window)) "Untitled application"))
              (bind-agent-widget-event widget id (lambda (source event) (declare (ignore source event)) (%share-select-window controller session window)))))
          (bind-agent-widget-event widget "cancel" (lambda (source event) (declare (ignore source event)) (%share-close controller session)))
          (bind-agent-widget-event widget "share" (lambda (source event) (declare (ignore source event)) (%share-accept controller session)))
          (bind-agent-widget-event widget "region" (lambda (source event) (declare (ignore source event)) (%share-begin-region controller)))
          (%share-update-selection controller session)
          (when seat (%focus-target world seat widget)))))))

(defun %share-indicators (controller)
  (let* ((world (share-controller-world controller))
         (active (remove-if-not #'share-session-active-p (share-controller-sessions controller))))
    (dolist (widget (share-controller-indicators controller)) (ataxia.world:remove-agent-widget world widget))
    (setf (share-controller-indicators controller) nil)
    (when active
      (dolist (state (%output-states world))
        (let ((widget (%share-widget controller "indicator" state 400d0 18d0 :layer 4900)))
          (ataxia.world:configure-agent-widget world widget :y 0d0)
          (ataxia.world.web.ui:set-widget-text widget "label" (format nil "Sharing ~D source~:P" (length active)))
          (bind-agent-widget-event widget "stop"
            (lambda (source event) (declare (ignore source event))
              (dolist (session (copy-list (share-controller-sessions controller))) (%share-close controller session))))
          (push widget (share-controller-indicators controller)))))))

(defun %share-events (controller)
  (cffi:with-foreign-object (event '(:struct ataxia.screencast.native::event))
    (loop while (plusp (ataxia.screencast.native::next (share-controller-native controller) event)) do
      (cffi:with-foreign-slots ((ataxia.screencast.native::kind ataxia.screencast.native::id ataxia.screencast.native::types)
                                event (:struct ataxia.screencast.native::event))
        (let ((id ataxia.screencast.native::id))
          (if (= 1 ataxia.screencast.native::kind)
              (setf (share-controller-sessions controller)
                    (append (share-controller-sessions controller)
                            (list (make-share-session :id id :types ataxia.screencast.native::types
                                    :app (cffi:foreign-string-to-lisp (cffi:foreign-slot-pointer event '(:struct ataxia.screencast.native::event) 'ataxia.screencast.native::app))))))
              (let ((session (find id (share-controller-sessions controller) :key #'share-session-id)))
                (when session (%share-close controller session))))))))
  (%share-next-picker controller))

(defun %share-complete-frames (window)
  (loop for surface across (ataxia.kernel:drawable-surfaces (canvas-window-application window))
        for token = (ataxia.kernel:drawable-surface-presentation-token surface)
        when token do (ataxia.kernel:complete-wayland-surface-frame token)))

(defun %share-window-revision (session)
  (let ((window (share-session-window session)))
    (when window
      (nth-value 1 (ataxia.kernel:drawable-surfaces (canvas-window-application window))))))

(defun %share-frame-current-p (session)
  (and (share-session-window session)
       (eql (%share-window-revision session) (gethash session *share-frame-revisions* :uncaptured))))

(defun %share-submit-frame (controller session)
  (let ((pixels (share-session-pixels session)))
    (sb-sys:with-pinned-objects (pixels)
      (ataxia.screencast.native::submit (share-controller-native controller) (share-session-id session)
                                      (sb-sys:vector-sap pixels) (length pixels)))))

(defun %share-tick (controller)
  (let* ((world (share-controller-world controller)) (state (%first-output-state world))
         (active (remove-if-not #'share-session-active-p (share-controller-sessions controller)))
         (capture-needed-p nil))
    (when (and state active)
      (dolist (session active)
        (if (share-session-window session) (%share-complete-frames (share-session-window session))
            (dolist (window (%world-stacking world)) (when (%window-visible-p window) (%share-complete-frames window))))
        (if (%share-frame-current-p session)
            (%share-submit-frame controller session)
            (setf capture-needed-p t)))
      (when capture-needed-p
        (setf (share-controller-due-p controller) t)
        (ataxia.world:request-world-capture world (%canvas-output-output state)))
      (ataxia.runtime:update-event-loop-timer (share-controller-timer controller) 33))))

(defun %share-window-frame-bounds (window width height)
  ;; Keep the negotiated stream dimensions stable when a client resizes, using
  ;; an opaque letterbox instead of changing the application's aspect ratio.
  (multiple-value-bind (x y w h) (ataxia.kernel:drawable-local-bounds (canvas-window-application window))
    (unless (and (plusp w) (plusp h)) (error "Shared application has no drawable content."))
    (let ((frame-ratio (/ width height)))
      (if (> (/ w h) frame-ratio)
          (let ((expanded (/ w frame-ratio))) (list x (- y (/ (- expanded h) 2d0)) w expanded))
          (let ((expanded (* h frame-ratio))) (list (- x (/ (- expanded w) 2d0)) y expanded h))))))

(defmethod ataxia.world:service-after-render ((controller share-controller) world lease)
  (when (and (share-controller-due-p controller)
             (%first-output-state world)
             (eq (ataxia.kernel:frame-output lease) (%canvas-output-output (%first-output-state world))))
    (setf (share-controller-due-p controller) nil)
    (dolist (session (copy-list (share-controller-sessions controller)))
      (when (and (share-session-active-p session) (not (%share-frame-current-p session)))
        (handler-case
            (let ((window (share-session-window session)) (pixels (share-session-pixels session))
                  (width (share-session-width session)) (height (share-session-height session)))
              (if window
                  (ataxia.world:capture-window-pixels world window
                    (%share-window-frame-bounds window width height) width height pixels)
                  (%capture-canvas-region world (share-session-bounds session) width height pixels (share-session-rotation session)))
              (when window
                (setf (gethash session *share-frame-revisions*) (%share-window-revision session)))
              (%share-submit-frame controller session))
          (error (cause) (format *error-output* "[screen-sharing] ~A~%" cause) (%share-close controller session)))))))

(defun enable-screen-sharing (world)
  (or (ataxia.world:world-service world :screen-sharing)
      (progn
        (ataxia.screencast.native::initialize)
        (let* ((native (ataxia.screencast.native::create))
               (controller (make-share-controller :world world :native native))
               (runtime (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))))
          (when (cffi:null-pointer-p native) (error "Could not own the Ataxia screen-sharing portal on the session bus."))
          (ataxia.world:attach-world-service world :screen-sharing controller)
          (handler-case
              (setf (share-controller-source controller)
                    (ataxia.runtime:add-event-loop-fd runtime (ataxia.screencast.native::fd native) ataxia.runtime:+event-readable+
                      (lambda (source fd mask) (declare (ignore source fd mask)) (%share-events controller) 0))
                    (share-controller-timer controller)
                    (ataxia.runtime:add-event-loop-timer runtime (lambda (source) (declare (ignore source)) (%share-tick controller) 0)))
            (error (cause) (disable-screen-sharing world) (error cause)))
          (setf (gethash (ataxia.kernel:world-kernel world) *screen-sharing-kernels*) t)
          controller))))

(defmethod ataxia.kernel:world-graphics-attached :after ((world infinite-world) context)
  (declare (ignore context))
  (when (gethash (ataxia.kernel:world-kernel world) *screen-sharing-kernels*)
    (handler-case (enable-screen-sharing world)
      (error (cause) (format *error-output* "[screen-sharing] ~A~%" cause)))))

(defun disable-screen-sharing (world &key keep-enabled-p)
  (unless keep-enabled-p (remhash (ataxia.kernel:world-kernel world) *screen-sharing-kernels*))
  (let ((controller (ataxia.world:world-service world :screen-sharing)))
    (when controller
      (%share-dismiss-picker controller)
      (dolist (widget (share-controller-indicators controller)) (ataxia.world:remove-agent-widget world widget))
      (dolist (source (list (share-controller-source controller) (share-controller-timer controller)))
        (when source (ataxia.runtime:remove-event-loop-source source)))
      (ataxia.screencast.native::destroy (share-controller-native controller))
      (ataxia.world:detach-world-service world :screen-sharing))))

(defmethod ataxia.world:service-quiescing ((controller share-controller) world reason)
  (declare (ignore reason)) (disable-screen-sharing world :keep-enabled-p t))
(defmethod ataxia.world:service-output-added ((controller share-controller) world output)
  (declare (ignore world output)) (%share-indicators controller) (%share-tick controller) (%share-next-picker controller))
(defmethod ataxia.kernel:world-output-removing :after ((world infinite-world) output)
  (let ((controller (ataxia.world:world-service world :screen-sharing)))
    (when controller
      ;; Run after World removes the output, so the next request cannot reopen
      ;; a picker or indicator on the monitor that just disappeared.
      (setf (share-controller-indicators controller)
            (remove output (share-controller-indicators controller) :key #'overlay-output))
      (when (and (share-controller-picker controller)
                 (eq output (overlay-output (share-controller-picker controller))))
        (setf (share-controller-picker controller) nil (share-controller-region controller) nil)
        (%share-close controller (share-controller-current controller)))
      (%share-indicators controller)
      (%share-tick controller))))
(defmethod ataxia.world:service-object-changed ((controller share-controller) world application change)
  (when (and (eq :mapped (ataxia.kernel:object-change-kind change))
             (null (ataxia.kernel:object-change-value change)))
    (ataxia.world:service-object-removing controller world application :unmapped)))
(defmethod ataxia.world:service-object-removing ((controller share-controller) world application reason)
  (declare (ignore world reason))
  (dolist (session (copy-list (share-controller-sessions controller)))
    (when (and (share-session-window session) (eq application (canvas-window-application (share-session-window session))))
      (%share-close controller session))))
(defmethod ataxia.world:service-key-event ((controller share-controller) world seat input)
  (declare (ignore world seat))
  (when (and (share-controller-current controller) (typep input 'ataxia.kernel:key-input)
             (eq :pressed (ataxia.kernel:key-input-state input))
             (find "Escape" (ataxia.kernel:key-input-keysyms input) :test #'equal))
    (%share-close controller (share-controller-current controller)) t))
