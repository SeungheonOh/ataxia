;;;; Slint component construction for the packed atlas World.
;;;;
;;;; This module creates and retires native components. Once inserted, they use
;;;; the same scene, rendering, damage, focus, and input paths as Wayland apps.

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

(defun %output-component-size (state)
  (multiple-value-bind (width height) (%output-logical-size state)
    (values (max 260d0 (min 680d0 (- width 48d0)))
            (max 64d0 (min 82d0 (- height 48d0))))))

(defun %make-output-component (world state)
  (multiple-value-bind (width height) (%output-component-size state)
    (let* ((output (%atlas-output-output state))
           (component
             (ataxia.world.slint:make-slint-component
              :source +atlas-panel-source+
              :source-path "atlas-panel.slint"
              :component-name "AtaxiaPanel"
              :width width :height height
              :scale (ataxia.kernel:output-scale output)))
           (object
             (make-instance
              'atlas-object :component component
              :mapping (make-instance
                        'atlas-output-mapping
                        :output-state state :x 24d0 :y 24d0)
              :layer 100 :width width :height height)))
      (ataxia.world.slint:set-slint-component-invalidator
       component
       (lambda (ignored)
         (declare (ignore ignored))
         (unless (%world-quiescing-p world)
           (%request-output-state-frame world state)
           (%schedule-component-timer world))))
      object)))

(defun %resize-output-component (object)
  (let* ((state (%mapping-output-state (%atlas-object-mapping object)))
         (output (%atlas-output-output state)))
    (multiple-value-bind (width height) (%output-component-size state)
      (ataxia.world.slint:resize-slint-component
       (atlas-object-component object) width height
       :scale (ataxia.kernel:output-scale output))
      (setf (atlas-object-width object) width
            (atlas-object-height object) height)))
  object)

(defun %component-animation-active-p (world)
  (some (lambda (object)
          (ataxia.kernel:drawable-active-p
           (atlas-object-component object)))
        (%scene-object-sequence world)))

(defun %schedule-component-timer (world)
  (let ((timer (%world-component-timer world)))
    (when timer
      (let* ((deadline (ataxia.world.slint:slint-next-timer-milliseconds))
             (delay
               (cond
                 ((%component-animation-active-p world)
                  (if (zerop deadline) 16 (max 1 (min 16 deadline))))
                 ((= deadline #xffffffffffffffff) 86400000)
                 (t (max 1 (min deadline 86400000))))))
        (ataxia.runtime:update-event-loop-timer timer delay))))
  world)

(defun %component-timer-fired (world source)
  (declare (ignore source))
  (unless (%world-quiescing-p world)
    (ataxia.world.slint:update-slint-timers)
    (%request-all-frames world)
    (%schedule-component-timer world))
  0)

(defun %install-component-timer (world)
  (unless (%world-component-timer world)
    (setf (%world-component-timer world)
          (ataxia.runtime:add-event-loop-timer
           (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))
           (lambda (source) (%component-timer-fired world source))))
    (%schedule-component-timer world))
  world)

(defun %remove-component-timer (world)
  (when (%world-component-timer world)
    (ataxia.runtime:remove-event-loop-source (%world-component-timer world))
    (setf (%world-component-timer world) nil))
  world)

(defun %retire-output-component (world output)
  (let ((object (gethash output (%world-output-components world))))
    (when object
      (ataxia.world.slint:set-slint-component-invalidator
       (atlas-object-component object) nil)
      (%remove-scene-object world object)
      (remhash output (%world-output-components world))
      (push object (%world-retired-components world))))
  world)

(defun %reap-retired-components (world)
  (dolist (object (%world-retired-components world))
    (let ((component (atlas-object-component object)))
      (when (ataxia.world.slint:slint-component-graphics-attached-p component)
        (ataxia.kernel:drawable-detach-graphics component))
      (ataxia.world.slint:destroy-slint-component component)))
  (setf (%world-retired-components world) nil)
  world)

(defun %destroy-output-components (world)
  (maphash
   (lambda (output object)
     (declare (ignore output))
     (let ((component (atlas-object-component object)))
       (ataxia.world.slint:set-slint-component-invalidator component nil)
       (when (ataxia.world.slint:slint-component-graphics-attached-p component)
         (ataxia.kernel:drawable-detach-graphics component))
       (ataxia.world.slint:destroy-slint-component component)))
   (%world-output-components world))
  (clrhash (%world-output-components world))
  (%reap-retired-components world))
