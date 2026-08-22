;;;; Slint components embedded by the packed atlas World.
;;;;
;;;; Atlas owns placement, damage projection, frame scheduling, and lifetime.
;;;; The reusable Slint engine owns only scene rendering and local input.

(in-package #:ataxia.atlas-world)

(defparameter +atlas-panel-source+
  "export component AtaxiaPanel inherits Window {
    background: #111827ee;
    in-out property <int> pulse-count: 0;
    in-out property <string> command: \"type here\";

    HorizontalLayout {
        padding: 12px;
        spacing: 12px;

        VerticalLayout {
            width: 150px;
            spacing: 2px;
            Text {
                text: \"ATAXIA\";
                color: #f8fafc;
                font-size: 20px;
                font-weight: 700;
            }
            Text {
                text: \"SLINT WORLD COMPONENT\";
                color: #7dd3fc;
                font-size: 10px;
            }
        }

        Rectangle {
            width: 152px;
            border-radius: 9px;
            background: pulse.pressed ? #0ea5e9 : pulse.has-hover ? #0284c7 : #0369a1;
            animate background { duration: 120ms; easing: ease-out; }
            Text {
                text: \"Pulse  \" + root.pulse-count;
                color: white;
                font-size: 15px;
                horizontal-alignment: center;
                vertical-alignment: center;
            }
            pulse := TouchArea {
                clicked => { root.pulse-count += 1; }
            }
        }

        Rectangle {
            min-width: 220px;
            border-radius: 9px;
            border-width: editor.has-focus ? 2px : 1px;
            border-color: editor.has-focus ? #38bdf8 : #475569;
            background: #020617cc;
            animate border-color { duration: 120ms; }
            editor := TextInput {
                x: 12px;
                y: 8px;
                width: parent.width - 24px;
                height: parent.height - 16px;
                text <=> root.command;
                color: #f8fafc;
                selection-background-color: #0369a1;
                font-size: 15px;
                single-line: true;
            }
        }
    }
}")

(defun %panel-size (state)
  (multiple-value-bind (width height) (%output-logical-size state)
    (values (max 260d0 (min 680d0 (- width 48d0)))
            (max 64d0 (min 82d0 (- height 48d0))))))

(defun %make-output-panel (world state)
  (multiple-value-bind (width height) (%panel-size state)
    (let* ((output (%atlas-output-output state))
           (component
             (ataxia.world.slint:make-slint-component
              :source +atlas-panel-source+
              :source-path "atlas-panel.slint"
              :component-name "AtaxiaPanel"
              :width width :height height
              :scale (ataxia.kernel:output-scale output)))
           (panel (%make-atlas-slint-panel component state 24d0 24d0)))
      (ataxia.world.slint:set-slint-component-invalidator
       component
       (lambda (ignored)
         (declare (ignore ignored))
         (unless (%world-quiescing-p world)
           (%request-output-state-frame world state)
           (%schedule-slint-timer world))))
      panel)))

(defun %resize-output-panel (panel)
  (let* ((state (%atlas-slint-panel-output-state panel))
         (output (%atlas-output-output state)))
    (multiple-value-bind (width height) (%panel-size state)
      (ataxia.world.slint:resize-slint-component
       (%panel-component panel) width height
       :scale (ataxia.kernel:output-scale output))))
  panel)

(defun %panel-at-screen-point (world state x y)
  (let ((panel (and state (gethash (%atlas-output-output state)
                                  (%world-slint-panels world)))))
    (when panel
      (multiple-value-bind (panel-x panel-y width height)
          (%panel-screen-geometry panel)
        (when (and (<= panel-x x (+ panel-x width))
                   (<= panel-y y (+ panel-y height)))
          panel)))))

(defun %panel-local-position (panel x y)
  (values (- x (%atlas-slint-panel-x panel))
          (- y (%atlas-slint-panel-y panel))))

(defun %damage-panel-region (world panel region)
  (let* ((state (%atlas-slint-panel-output-state panel))
         (output (%atlas-output-output state)))
    (when (and (gethash output (%world-outputs world)) region)
      (ataxia.world:damage-add-region
       (%world-damage world) output
       (mapcar
        (lambda (rectangle)
          (%screen-rectangle-to-buffer
           state
           (+ (%atlas-slint-panel-x panel)
              (ataxia.world:rectangle-x rectangle))
           (+ (%atlas-slint-panel-y panel)
              (ataxia.world:rectangle-y rectangle))
           (ataxia.world:rectangle-width rectangle)
           (ataxia.world:rectangle-height rectangle)))
        region))))
  panel)

(defun %slint-animation-active-p (world)
  (some (lambda (panel)
          (ataxia.world.slint:slint-component-active-p
           (%panel-component panel)))
        (%hash-values (%world-slint-panels world))))

(defun %schedule-slint-timer (world)
  (let ((timer (%world-slint-timer world)))
    (when timer
      (let* ((deadline (ataxia.world.slint:slint-next-timer-milliseconds))
             (delay
               (cond
                 ((%slint-animation-active-p world)
                  (if (zerop deadline) 16 (max 1 (min 16 deadline))))
                 ((= deadline #xffffffffffffffff) 86400000)
                 (t (max 1 (min deadline 86400000))))))
        (ataxia.runtime:update-event-loop-timer timer delay))))
  world)

(defun %slint-timer-fired (world source)
  (declare (ignore source))
  (unless (%world-quiescing-p world)
    (ataxia.world.slint:update-slint-timers)
    (%request-all-frames world)
    (%schedule-slint-timer world))
  0)

(defun %install-slint-timer (world)
  (unless (%world-slint-timer world)
    (setf (%world-slint-timer world)
          (ataxia.runtime:add-event-loop-timer
           (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))
           (lambda (source) (%slint-timer-fired world source))))
    (%schedule-slint-timer world))
  world)

(defun %remove-slint-timer (world)
  (when (%world-slint-timer world)
    (ataxia.runtime:remove-event-loop-source (%world-slint-timer world))
    (setf (%world-slint-timer world) nil))
  world)

(defun %render-output-panel (world state)
  (let ((panel (gethash (%atlas-output-output state)
                        (%world-slint-panels world))))
    (when panel
      (let ((component (%panel-component panel)))
        (unless (ataxia.world.slint:slint-component-graphics-attached-p component)
          (ataxia.world.slint:attach-slint-component-graphics component))
        (multiple-value-bind (damage active-p)
            (ataxia.world.slint:render-slint-component component)
          (%damage-panel-region world panel damage)
          (when active-p (%request-output-state-frame world state))))))
  (%schedule-slint-timer world)
  world)

(defun %retire-output-panel (world output)
  (let ((panel (gethash output (%world-slint-panels world))))
    (when panel
      (ataxia.world.slint:set-slint-component-invalidator
       (%panel-component panel) nil)
      (remhash output (%world-slint-panels world))
      (push panel (%world-retired-slint-panels world))))
  world)

(defun %reap-retired-slint-panels (world)
  (dolist (panel (%world-retired-slint-panels world))
    (let ((component (%panel-component panel)))
      (when (ataxia.world.slint:slint-component-graphics-attached-p component)
        (ataxia.world.slint:detach-slint-component-graphics component))
      (ataxia.world.slint:destroy-slint-component component)))
  (setf (%world-retired-slint-panels world) nil)
  world)

(defun %destroy-slint-panels (world)
  (maphash
   (lambda (output panel)
     (declare (ignore output))
     (let ((component (%panel-component panel)))
       (ataxia.world.slint:set-slint-component-invalidator component nil)
       (when (ataxia.world.slint:slint-component-graphics-attached-p component)
         (ataxia.world.slint:detach-slint-component-graphics component))
       (ataxia.world.slint:destroy-slint-component component)))
   (%world-slint-panels world))
  (clrhash (%world-slint-panels world))
  (%reap-retired-slint-panels world))
