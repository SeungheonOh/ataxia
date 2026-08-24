;;;; Runtime callback integration.
;;;;
;;;; Kernel specializes Runtime's exact wlroots/Wayland callbacks directly.
;;;; Each method updates Kernel-owned protocol state, then synchronously invokes
;;;; the corresponding typed World endpoint when policy is required.

(in-package #:ataxia.kernel)

(defun %retire-input-device (input-device &key protocol-active-p)
  (when (eq (object-state input-device) :live)
    (let ((kernel (object-kernel input-device)))
      (if protocol-active-p
          (%unassign-input-device input-device)
          (setf (input-seat input-device) nil))
      (remhash (input-runtime-object input-device) (%kernel-input-table kernel))
      (%retire-object
       kernel input-device :runtime-object (input-runtime-object input-device))))
  input-device)

(defun %retire-kernel-runtime-state (kernel)
  (dolist (application (%hash-values (%kernel-toplevel-table kernel)))
    (%retire-wayland-application application :runtime-stopping))
  (dolist (output (kernel-outputs kernel))
    (%retire-output output :protocol-active-p nil))
  (dolist (seat (kernel-seats kernel))
    (%retire-logical-seat seat))
  (dolist (input-device (kernel-input-devices kernel))
    (%retire-input-device input-device))
  (dolist (surface (%hash-values (%kernel-surface-table kernel)))
    (%retire-surface-node surface :protocol-active-p nil))
  kernel)

(defmethod ataxia.runtime:runtime-started
    ((kernel kernel) runtime)
  (unless (eq runtime (kernel-runtime kernel))
    (error "Runtime callback belongs to another Kernel."))
  (setf (kernel-state kernel) :running)
  (ataxia.runtime:call-with-egl-context
   (ataxia.runtime:runtime-egl runtime)
   (lambda ()
     (world-graphics-attached
      (kernel-world kernel) (ataxia.runtime:runtime-egl runtime))))
  (setf (%kernel-graphics-attached-p kernel) t)
  kernel)

(defmethod ataxia.runtime:runtime-stopping
    ((kernel kernel) runtime reason)
  (declare (ignore runtime))
  (unless (eq (kernel-state kernel) :stopping)
    (world-quiescing (kernel-world kernel) reason))
  (setf (kernel-state kernel) :stopping)
  (%retire-kernel-runtime-state kernel)
  kernel)

(defmethod ataxia.runtime:renderer-lost
    ((kernel kernel) runtime renderer)
  (declare (ignore renderer))
  (world-quiescing (kernel-world kernel) :renderer-lost)
  (handler-case
      (%detach-world-graphics kernel :renderer-lost)
    (serious-condition (cause)
      (format *error-output*
              "[kernel] graphics teardown after renderer loss failed: ~A~%"
              cause)))
  (setf (kernel-state kernel) :renderer-lost)
  (ataxia.runtime:request-runtime-stop runtime :renderer-lost)
  kernel)

(defmethod ataxia.runtime:backend-new-output
    ((kernel kernel) runtime runtime-output)
  (declare (ignore runtime))
  (%configure-new-output kernel runtime-output))

(defmethod ataxia.runtime:output-frame
    ((kernel kernel) runtime-output)
  (let ((output (gethash runtime-output (%kernel-output-table kernel))))
    (when (and output
               (output-enabled-p output)
               (%output-frame-requested-p output))
      (%render-output-frame output))))

(defmethod ataxia.runtime:output-needs-frame
    ((kernel kernel) runtime-output)
  (let ((output (gethash runtime-output (%kernel-output-table kernel))))
    (when output
      (request-output-frame output))))

(defmethod ataxia.runtime:output-damaged
    ((kernel kernel) event)
  (let* ((runtime-output (ataxia.runtime:output-damage-output event))
         (output (gethash runtime-output (%kernel-output-table kernel))))
    (when output
      (world-output-changed
       (kernel-world kernel)
       output
       (make-object-change
        :backend-damage
        (%runtime-damage-rectangles
         (ataxia.runtime:output-damage-rectangles event)))))))

(defmethod ataxia.runtime:output-present
    ((kernel kernel) event)
  (let ((output
          (gethash (ataxia.runtime:output-present-output event)
                   (%kernel-output-table kernel))))
    (when output
      (world-output-presented
       (kernel-world kernel) output
       (make-output-presentation
        :commit-sequence
        (ataxia.runtime:output-present-commit-sequence event)
        :presented-p (ataxia.runtime:output-present-presented-p event)
        :seconds (ataxia.runtime:output-present-seconds event)
        :nanoseconds (ataxia.runtime:output-present-nanoseconds event)
        :sequence (ataxia.runtime:output-present-sequence event)
        :refresh-nanoseconds
        (ataxia.runtime:output-present-refresh-nanoseconds event)
        :flags (ataxia.runtime:output-present-flags event))))))

(defmethod ataxia.runtime:output-request-state
    ((kernel kernel) runtime-output state)
  (let ((output (gethash runtime-output (%kernel-output-table kernel)))
        (fields (ataxia.runtime:output-state-committed-fields state)))
    (when (and output
               (ataxia.runtime:output-test-state runtime-output state)
               (ataxia.runtime:output-commit-state runtime-output state))
      (when (logtest +output-state-buffer-configuration-fields+ fields)
        (%reset-output-swapchain output))
      (%refresh-output-object output)
      (world-output-changed
       (kernel-world kernel) output
       (make-object-change :configuration nil)))))

(defmethod ataxia.runtime:output-destroying
    ((kernel kernel) runtime-output)
  (let ((output (gethash runtime-output (%kernel-output-table kernel))))
    (when output
      (%retire-output output))))

(defmethod ataxia.runtime:backend-new-input
    ((kernel kernel) runtime runtime-input)
  (declare (ignore runtime))
  (let ((input-device
          (make-instance
           'kernel-input-device
           :kernel kernel
           :id (%allocate-object-id kernel)
           :runtime-object runtime-input
           :name (ataxia.runtime:input-device-name runtime-input)
           :type (ataxia.runtime:input-device-type runtime-input))))
    (%register-object kernel input-device :runtime-object runtime-input)
    (setf (gethash runtime-input (%kernel-input-table kernel)) input-device)
    (when (typep runtime-input 'ataxia.runtime:wlr-keyboard)
      (ataxia.runtime:set-keyboard-keymap-from-names runtime-input)
      (ataxia.runtime:set-keyboard-repeat-info runtime-input 25 600))
    (when (%kernel-default-seat kernel)
      (assign-input-device input-device (%kernel-default-seat kernel)))
    input-device))

(defmethod ataxia.runtime:input-device-destroying
    ((kernel kernel) runtime-input)
  (let ((input-device
          (gethash runtime-input (%kernel-input-table kernel))))
    (when input-device
      (%retire-input-device input-device :protocol-active-p t))))

(defmethod ataxia.runtime:pointer-motion ((kernel kernel) event)
  (let* ((runtime-input (ataxia.runtime:pointer-motion-pointer event))
         (input-device (%event-input-device kernel runtime-input))
         (seat (and input-device (input-seat input-device))))
    (when seat
      (let ((manager
              (ataxia.runtime:runtime-relative-pointer-manager
               (kernel-runtime kernel))))
        (when manager
          (ataxia.runtime:relative-pointer-send-motion
           manager (seat-runtime-object seat)
           (* 1000 (ataxia.runtime:pointer-motion-time-msec event))
           (ataxia.runtime:pointer-motion-delta-x event)
           (ataxia.runtime:pointer-motion-delta-y event)
           (ataxia.runtime:pointer-motion-unaccelerated-delta-x event)
           (ataxia.runtime:pointer-motion-unaccelerated-delta-y event))))
      (world-cursor-motion
       (kernel-world kernel) seat
       (make-cursor-motion-input
        :device input-device
        :time-msec (ataxia.runtime:pointer-motion-time-msec event)
        :delta-x (ataxia.runtime:pointer-motion-delta-x event)
        :delta-y (ataxia.runtime:pointer-motion-delta-y event)
        :unaccelerated-delta-x
        (ataxia.runtime:pointer-motion-unaccelerated-delta-x event)
        :unaccelerated-delta-y
        (ataxia.runtime:pointer-motion-unaccelerated-delta-y event))))))

(defmethod ataxia.runtime:pointer-motion-absolute
    ((kernel kernel) event)
  (let* ((runtime-input
           (ataxia.runtime:pointer-motion-absolute-pointer event))
         (input-device (%event-input-device kernel runtime-input))
         (seat (and input-device (input-seat input-device))))
    (when seat
      (world-cursor-motion
       (kernel-world kernel) seat
       (make-cursor-motion-input
        :device input-device
        :time-msec (ataxia.runtime:pointer-motion-absolute-time-msec event)
        :absolute-p t
        :x (ataxia.runtime:pointer-motion-absolute-x event)
        :y (ataxia.runtime:pointer-motion-absolute-y event))))))

(defmethod ataxia.runtime:pointer-button ((kernel kernel) event)
  (let* ((runtime-input (ataxia.runtime:pointer-button-pointer event))
         (input-device (%event-input-device kernel runtime-input))
         (seat (and input-device (input-seat input-device))))
    (when seat
      (let* ((runtime-seat (seat-runtime-object seat))
             (button (ataxia.runtime:pointer-button-code event))
             (state (ataxia.runtime:pointer-button-state event))
             (press-count
               (ataxia.runtime:seat-pointer-button-press-count
                runtime-seat button)))
        (world-cursor-button
         (kernel-world kernel) seat
         (make-cursor-button-input
          :device input-device
          :time-msec (ataxia.runtime:pointer-button-time-msec event)
          :code button
          :state state))
        (when (and (eq state :released)
                   (plusp press-count)
                   (= press-count
                      (ataxia.runtime:seat-pointer-button-press-count
                       runtime-seat button)))
          (ataxia.runtime:seat-pointer-notify-button
           runtime-seat
           (ataxia.runtime:pointer-button-time-msec event)
           button
           :released))))))

(defmethod ataxia.runtime:pointer-axis ((kernel kernel) event)
  (let* ((runtime-input (ataxia.runtime:pointer-axis-pointer event))
         (input-device (%event-input-device kernel runtime-input))
         (seat (and input-device (input-seat input-device))))
    (when seat
      (world-cursor-axis
       (kernel-world kernel) seat
       (make-cursor-axis-input
        :device input-device
        :time-msec (ataxia.runtime:pointer-axis-time-msec event)
        :source (ataxia.runtime:pointer-axis-source event)
        :orientation (ataxia.runtime:pointer-axis-orientation event)
        :relative-direction
        (ataxia.runtime:pointer-axis-relative-direction event)
        :delta (ataxia.runtime:pointer-axis-delta event)
        :discrete-delta
        (ataxia.runtime:pointer-axis-discrete-delta event))))))

(defmethod ataxia.runtime:pointer-frame ((kernel kernel) runtime-pointer)
  (let ((seat (%event-seat kernel runtime-pointer)))
    (when seat
      (ataxia.runtime:seat-pointer-notify-frame
       (seat-runtime-object seat)))))

(defmethod ataxia.runtime:keyboard-key ((kernel kernel) event)
  (let* ((runtime-input (ataxia.runtime:keyboard-key-keyboard event))
         (input-device (%event-input-device kernel runtime-input))
         (seat (and input-device (input-seat input-device))))
    (when seat
      (ataxia.runtime:set-seat-keyboard
       (seat-runtime-object seat) runtime-input)
      (setf (%seat-keyboard seat) runtime-input)
      (world-key-event
       (kernel-world kernel) seat
       (make-key-input
        :device input-device
        :time-msec (ataxia.runtime:keyboard-key-time-msec event)
        :keycode (ataxia.runtime:keyboard-key-keycode event)
        :state (ataxia.runtime:keyboard-key-state event)
        :update-state-p
        (ataxia.runtime:keyboard-key-update-state-p event))))))

(defmethod ataxia.runtime:keyboard-modifiers ((kernel kernel) event)
  (let* ((runtime-input (ataxia.runtime:keyboard-modifiers-keyboard event))
         (input-device (%event-input-device kernel runtime-input))
         (seat (and input-device (input-seat input-device))))
    (when seat
      (ataxia.runtime:set-seat-keyboard
       (seat-runtime-object seat) runtime-input)
      (setf (%seat-keyboard seat) runtime-input)
      (world-key-event
       (kernel-world kernel) seat
       (make-modifiers-input
        :device input-device
        :depressed (ataxia.runtime:keyboard-modifiers-depressed event)
        :latched (ataxia.runtime:keyboard-modifiers-latched event)
        :locked (ataxia.runtime:keyboard-modifiers-locked event)
        :group (ataxia.runtime:keyboard-modifiers-group event))))))

(defmethod ataxia.runtime:seat-destroying
    ((kernel kernel) runtime-seat)
  (let ((seat (gethash runtime-seat (%kernel-seat-table kernel))))
    (when seat
      (%retire-logical-seat seat))))

(defmethod ataxia.runtime:seat-request-set-cursor
    ((kernel kernel) request)
  (unless (ataxia.runtime:seat-cursor-request-authorized-p request)
    (return-from ataxia.runtime:seat-request-set-cursor request))
  (let* ((seat
           (gethash (ataxia.runtime:seat-cursor-request-seat request)
                    (%kernel-seat-table kernel)))
         (runtime-surface
           (ataxia.runtime:seat-cursor-request-surface request))
         (surface
           (and runtime-surface
                (%ensure-surface-node kernel runtime-surface))))
    (when seat
      (when surface
        (setf (%surface-externally-exposed-p surface) t))
      (let ((stable-request
              (make-instance
               'cursor-surface-request
               :seat seat
               :surface surface
               :serial (ataxia.runtime:seat-cursor-request-serial request)
               :hotspot-x (ataxia.runtime:seat-cursor-request-hotspot-x request)
               :hotspot-y
               (ataxia.runtime:seat-cursor-request-hotspot-y request))))
        (setf (%seat-cursor-request seat) stable-request)
        (world-seat-cursor-request
         (kernel-world kernel) seat stable-request)))))

(defmethod ataxia.runtime:seat-request-start-drag
    ((kernel kernel) request)
  (declare (ignore kernel))
  (let ((seat (ataxia.runtime:seat-drag-request-seat request))
        (drag (ataxia.runtime:seat-drag-request-drag request))
        (origin (ataxia.runtime:seat-drag-request-origin request))
        (serial (ataxia.runtime:seat-drag-request-serial request)))
    (if (ataxia.runtime:seat-validate-pointer-grab-serial
         seat origin serial)
        (ataxia.runtime:seat-start-pointer-drag seat drag serial)
        (ataxia.runtime:destroy-drag drag))))

(defmethod ataxia.runtime:compositor-new-surface
    ((kernel kernel) runtime surface)
  (declare (ignore runtime))
  (%ensure-surface-node kernel surface))

(defmethod ataxia.runtime:surface-committed
    ((kernel kernel) runtime-surface commit)
  (let* ((surface (%ensure-surface-node kernel runtime-surface))
         (application (%surface-tree-application surface)))
    (%update-surface-node surface commit)
    (cond
      ((and application (eq (object-state application) :live))
       (%invalidate-application application))
      ((%surface-externally-exposed-p surface)
       (world-object-invalidated
        (kernel-world kernel) surface
        (make-drawable-invalidation
         (surface-commit-sequence surface) (%surface-damage surface)))))))

(defmethod ataxia.runtime:surface-mapped
    ((kernel kernel) runtime-surface)
  (let* ((surface (%ensure-surface-node kernel runtime-surface))
         (application (%surface-tree-application surface)))
    (setf (surface-mapped-p surface) t)
    (when application
      (%invalidate-application application))))

(defmethod ataxia.runtime:surface-unmapped
    ((kernel kernel) runtime-surface)
  (let* ((surface (%ensure-surface-node kernel runtime-surface))
         (application (%surface-tree-application surface)))
    (setf (surface-mapped-p surface) nil)
    (%release-surface-source surface)
    (when application
      (%invalidate-application application))))

(defmethod ataxia.runtime:surface-destroying
    ((kernel kernel) runtime-surface)
  (let ((surface (gethash runtime-surface (%kernel-surface-table kernel))))
    (when surface
      (dolist (seat (kernel-seats kernel))
        (let ((request (%seat-cursor-request seat)))
          (when (and request
                     (eq surface (cursor-surface-request-surface request)))
            (setf (%seat-cursor-request seat) nil))))
      (when (%surface-externally-exposed-p surface)
        (world-object-changed
         (kernel-world kernel) surface
         (make-object-change :destroying nil)))
      (%retire-surface-node surface))))

(defmethod ataxia.runtime:surface-new-subsurface
    ((kernel kernel) parent-runtime-surface subsurface)
  (let* ((parent (%ensure-surface-node kernel parent-runtime-surface))
         (child
           (%ensure-surface-node
            kernel (ataxia.runtime:subsurface-surface subsurface))))
    (%attach-surface-child
     parent child
     (ataxia.runtime:subsurface-x subsurface)
     (ataxia.runtime:subsurface-y subsurface))
    (setf (gethash subsurface (%kernel-runtime-index kernel)) child)
    (let ((application (%surface-tree-application parent)))
      (when application
        (%invalidate-application application)))))

(defmethod ataxia.runtime:subsurface-state-changed
    ((kernel kernel) subsurface)
  (let ((surface (%find-runtime-object kernel subsurface)))
    (when surface
      (setf (surface-local-x surface) (ataxia.runtime:subsurface-x subsurface)
            (surface-local-y surface) (ataxia.runtime:subsurface-y subsurface))
      (let ((application (%surface-tree-application surface)))
        (when application
          (%invalidate-application application))))))

(defmethod ataxia.runtime:subsurface-destroying
    ((kernel kernel) subsurface)
  (let ((surface (%find-runtime-object kernel subsurface)))
    (when surface
      (remhash subsurface (%kernel-runtime-index kernel))
      (let ((application (%surface-tree-application surface)))
        (%detach-surface-node surface)
        (when application
          (%invalidate-application application))))))

(defmethod ataxia.runtime:xdg-new-toplevel
    ((kernel kernel) toplevel)
  (%create-wayland-application kernel toplevel))

(defmethod ataxia.runtime:xdg-toplevel-mapped
    ((kernel kernel) toplevel)
  (let ((application (gethash toplevel (%kernel-toplevel-table kernel))))
    (when application
      (setf (application-mapped-p application) t)
      (world-object-changed
       (kernel-world kernel) application
       (make-object-change :mapped t))
      (%invalidate-application application))))

(defmethod ataxia.runtime:xdg-toplevel-unmapped
    ((kernel kernel) toplevel)
  (let ((application (gethash toplevel (%kernel-toplevel-table kernel))))
    (when application
      (setf (application-mapped-p application) nil)
      (world-object-changed
       (kernel-world kernel) application
       (make-object-change :mapped nil))
      (%invalidate-application application))))

(defmethod ataxia.runtime:xdg-toplevel-committed
    ((kernel kernel) toplevel commit initial-commit-p configured-p)
  (declare (ignore commit))
  (when (and initial-commit-p (not configured-p))
    (let ((decoration
            (ataxia.runtime:find-xdg-toplevel-decoration
             (kernel-runtime kernel) toplevel)))
      (when decoration
        (ataxia.runtime:xdg-toplevel-decoration-set-mode
         decoration :client-side)))
    (ataxia.runtime:xdg-surface-schedule-configure toplevel))
  (gethash toplevel (%kernel-toplevel-table kernel)))

(defmethod ataxia.runtime:xdg-toplevel-destroying
    ((kernel kernel) toplevel)
  (let ((application (gethash toplevel (%kernel-toplevel-table kernel))))
    (when application
      (%retire-wayland-application application :destroyed))))

(defun %request-application (kernel runtime-toplevel)
  (or (gethash runtime-toplevel (%kernel-toplevel-table kernel))
      (error "Client request references an unknown XDG toplevel.")))

(defun %request-seat-object (kernel runtime-seat)
  (or (gethash runtime-seat (%kernel-seat-table kernel))
      (error "Client request references an unknown Wayland seat.")))

(defmethod ataxia.runtime:xdg-toplevel-request-move
    ((kernel kernel) event)
  (let ((runtime-seat (ataxia.runtime:xdg-move-seat event))
        (serial (ataxia.runtime:xdg-move-serial event)))
    (when (ataxia.runtime:seat-validate-current-pointer-grab-serial
           runtime-seat serial)
      (world-client-request
       (kernel-world kernel)
       (%request-application kernel (ataxia.runtime:xdg-move-toplevel event))
       (make-instance
        'move-client-request
        :seat (%request-seat-object kernel runtime-seat)
        :serial serial)))))

(defmethod ataxia.runtime:xdg-toplevel-request-resize
    ((kernel kernel) event)
  (let ((runtime-seat (ataxia.runtime:xdg-resize-seat event))
        (serial (ataxia.runtime:xdg-resize-serial event)))
    (when (ataxia.runtime:seat-validate-current-pointer-grab-serial
           runtime-seat serial)
      (world-client-request
       (kernel-world kernel)
       (%request-application kernel (ataxia.runtime:xdg-resize-toplevel event))
       (make-instance
        'resize-client-request
        :seat (%request-seat-object kernel runtime-seat)
        :serial serial
        :edges (ataxia.runtime:xdg-resize-edges event))))))

(defun %send-state-client-request (kernel toplevel name value)
  (let ((application (%request-application kernel toplevel)))
    (world-client-request
     (kernel-world kernel) application
     (make-instance 'state-client-request :name name :value value))))

(defmethod ataxia.runtime:xdg-toplevel-request-maximize
    ((kernel kernel) toplevel requested-p)
  (%send-state-client-request kernel toplevel :maximized requested-p))

(defmethod ataxia.runtime:xdg-toplevel-request-minimize
    ((kernel kernel) toplevel requested-p)
  (%send-state-client-request kernel toplevel :minimized requested-p))

(defmethod ataxia.runtime:xdg-toplevel-request-fullscreen
    ((kernel kernel) request)
  (let* ((application
           (%request-application
            kernel (ataxia.runtime:xdg-fullscreen-toplevel request)))
         (runtime-output (ataxia.runtime:xdg-fullscreen-output request))
         (output
           (and runtime-output
                (gethash runtime-output (%kernel-output-table kernel)))))
    (world-client-request
     (kernel-world kernel) application
     (make-instance
      'fullscreen-client-request
      :name :fullscreen
      :value (ataxia.runtime:xdg-fullscreen-requested-p request)
      :output output))))

(defmethod ataxia.runtime:xdg-toplevel-request-show-window-menu
    ((kernel kernel) event)
  (let ((application
          (%request-application
           kernel (ataxia.runtime:xdg-window-menu-toplevel event))))
    (world-client-request
     (kernel-world kernel) application
     (make-instance
      'window-menu-client-request
      :seat
      (%request-seat-object kernel (ataxia.runtime:xdg-window-menu-seat event))
      :serial (ataxia.runtime:xdg-window-menu-serial event)
      :x (ataxia.runtime:xdg-window-menu-x event)
      :y (ataxia.runtime:xdg-window-menu-y event)))))

(defmethod ataxia.runtime:xdg-toplevel-parent-changed
    ((kernel kernel) toplevel)
  (let ((application (%request-application kernel toplevel)))
    (world-object-changed
     (kernel-world kernel) application
     (make-object-change :parent nil))))

(defmethod ataxia.runtime:xdg-new-toplevel-decoration
    ((kernel kernel) runtime decoration)
  (declare (ignore kernel runtime))
  (ataxia.runtime:xdg-toplevel-decoration-set-mode
   decoration :client-side))

(defmethod ataxia.runtime:xdg-toplevel-decoration-request-mode
    ((kernel kernel) decoration)
  (declare (ignore kernel))
  (ataxia.runtime:xdg-toplevel-decoration-set-mode
   decoration :client-side))

(defmethod ataxia.runtime:xdg-toplevel-decoration-destroying
    ((kernel kernel) decoration)
  (declare (ignore kernel decoration))
  nil)

(defmethod ataxia.runtime:xdg-activation-requested
    ((kernel kernel) runtime request)
  (declare (ignore runtime))
  (let* ((runtime-surface
           (ataxia.runtime:xdg-activation-request-target-surface request))
         (surface
           (and runtime-surface
                (gethash runtime-surface (%kernel-surface-table kernel))))
         (application (and surface (%surface-tree-application surface)))
         (runtime-seat (ataxia.runtime:xdg-activation-request-seat request))
         (seat (and runtime-seat
                    (gethash runtime-seat (%kernel-seat-table kernel)))))
    (when application
      (world-client-request
       (kernel-world kernel) application
       (make-instance 'state-client-request
                      :name :activation :value t :seat seat)))))

(defmethod ataxia.runtime:xdg-toplevel-title-changed
    ((kernel kernel) toplevel title)
  (let ((application (%request-application kernel toplevel)))
    (setf (application-title application) title)
    (world-object-changed
     (kernel-world kernel) application
     (make-object-change :title title))))

(defmethod ataxia.runtime:xdg-toplevel-app-id-changed
    ((kernel kernel) toplevel app-id)
  (let ((application (%request-application kernel toplevel)))
    (setf (application-app-id application) app-id)
    (world-object-changed
     (kernel-world kernel) application
     (make-object-change :app-id app-id))))

(defun %popup-surface-node (kernel popup)
  (gethash popup (%kernel-popup-table kernel)))

(defmethod ataxia.runtime:xdg-new-popup ((kernel kernel) popup)
  (let* ((runtime-parent (ataxia.runtime:xdg-popup-parent-surface popup))
         (parent (and runtime-parent
                      (%ensure-surface-node kernel runtime-parent)))
         (surface
           (%ensure-surface-node kernel (ataxia.runtime:xdg-popup-surface popup))))
    (multiple-value-bind (x y) (ataxia.runtime:xdg-popup-position popup)
      (when parent
        (%attach-surface-child parent surface x y)))
    (setf (gethash popup (%kernel-popup-table kernel)) surface
          (gethash popup (%kernel-runtime-index kernel)) surface)
    (let ((application (%surface-tree-application surface)))
      (when application
        (%invalidate-application application)))))

(defmethod ataxia.runtime:xdg-popup-mapped ((kernel kernel) popup)
  (let ((surface (%popup-surface-node kernel popup)))
    (when surface
      (setf (surface-mapped-p surface) t)
      (let ((application (%surface-tree-application surface)))
        (when application
          (%invalidate-application application))))))

(defmethod ataxia.runtime:xdg-popup-unmapped ((kernel kernel) popup)
  (let ((surface (%popup-surface-node kernel popup)))
    (when surface
      (setf (surface-mapped-p surface) nil)
      (let ((application (%surface-tree-application surface)))
        (when application
          (%invalidate-application application))))))

(defmethod ataxia.runtime:xdg-popup-committed
    ((kernel kernel) popup commit initial-commit-p configured-p)
  (declare (ignore kernel commit))
  (when (and initial-commit-p (not configured-p))
    (ataxia.runtime:xdg-surface-schedule-configure popup)))

(defmethod ataxia.runtime:xdg-popup-repositioned
    ((kernel kernel) popup)
  (let ((surface (%popup-surface-node kernel popup)))
    (when surface
      (multiple-value-bind (x y) (ataxia.runtime:xdg-popup-position popup)
        (setf (surface-local-x surface) x
              (surface-local-y surface) y))
      (let ((application (%surface-tree-application surface)))
        (when application
          (%invalidate-application application))))))

(defmethod ataxia.runtime:xdg-popup-destroying
    ((kernel kernel) popup)
  (let ((surface (%popup-surface-node kernel popup)))
    (when surface
      (let ((application (%surface-tree-application surface)))
        (%detach-surface-node surface)
        (when application
          (%invalidate-application application))))
    (remhash popup (%kernel-popup-table kernel))
    (remhash popup (%kernel-runtime-index kernel))))
