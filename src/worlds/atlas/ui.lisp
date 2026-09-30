;;;; HTML component construction for the packed atlas World.
;;;;
;;;; This module creates and retires native components. Once inserted, they use
;;;; the same scene, rendering, damage, focus, and input paths as Wayland apps.

(in-package #:ataxia.atlas-world)

(defun %output-component-size (state)
  (multiple-value-bind (width height) (%output-logical-size state)
    (values (max 260d0 (min 680d0 (- width 48d0)))
            (max 64d0 (min 82d0 (- height 48d0))))))

(defun %make-output-component (world state)
  (multiple-value-bind (width height) (%output-component-size state)
    (let* ((output (%atlas-output-output state))
           (component
             (ataxia.world.web.ui:make-ui-component
              :world world
              :source-path (asdf:system-relative-pathname "ataxia-atlas-world" "src/worlds/atlas/panel.html")
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
      (ataxia.world:ui-set-invalidator
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
      (ataxia.world:ui-resize
       (atlas-object-component object) width height
       :scale (ataxia.kernel:output-scale output))
      (setf (atlas-object-width object) width
            (atlas-object-height object) height)))
  object)

(defun %updatable-object-p (world object)
  (and (%object-visible-p object)
       (some (lambda (state) (%object-on-output-p world object state (%now)))
             (%output-states world))))

(defun %service-ui-engines (world)
  (let ((serviced nil))
    (dolist (object (%scene-object-sequence world))
      (when (%updatable-object-p world object)
        (let* ((component (atlas-object-component object))
               (key (ataxia.world:ui-service-key component)))
          (when (and key (not (member key serviced)))
            (push key serviced)
            (ataxia.world:ui-service component)))))
    (dolist (object (%scene-object-sequence world))
      (when (%updatable-object-p world object)
        (ataxia.world:ui-dispatch-callbacks (atlas-object-component object))))))

(defun %schedule-component-timer (world)
  (let ((timer (%world-component-timer world)) (deadline nil))
    (when timer
      (dolist (object (%scene-object-sequence world))
        (when (%updatable-object-p world object)
          (let* ((component (atlas-object-component object))
                 (delay (ataxia.world:ui-next-update-delay component)))
            (when (or (ataxia.kernel:drawable-active-p component)
                      (and delay (zerop delay)))
              (%request-object-frames world object))
            (when (and delay (plusp delay))
              (setf deadline (if deadline (min deadline delay) delay))))))
      (ataxia.runtime:update-event-loop-timer
       timer (if deadline (max 1 (min (ceiling deadline) 86400000)) 0))))
  world)

(defun %component-timer-fired (world source)
  (declare (ignore source))
  (unless (%world-quiescing-p world)
    (%service-ui-engines world)
    (%schedule-component-timer world))
  0)

(defun %install-component-timer (world)
  (unless (%world-component-timer world)
    (setf (%world-component-timer world)
          (ataxia.runtime:add-event-loop-timer
           (ataxia.kernel:kernel-runtime (ataxia.kernel:world-kernel world))
           (lambda (source)
             (unless (%world-quiescing-p world)
               (ataxia.kernel:call-with-current-world
                (ataxia.kernel:world-kernel world)
                (lambda (current)
                  (when (eq current world) (%component-timer-fired world source)))
                :operation :ui-timer))
             0)))
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
      (ataxia.world:ui-set-invalidator
       (atlas-object-component object) nil)
      (%remove-scene-object world object)
      (remhash output (%world-output-components world))
      (push object (%world-retired-components world))))
  world)

(defun %reap-retired-components (world)
  (dolist (object (%world-retired-components world))
    (let ((component (atlas-object-component object)))
      (ataxia.kernel:drawable-detach-graphics component)
      (ataxia.world:ui-destroy component)))
  (setf (%world-retired-components world) nil)
  world)

(defun %destroy-output-components (world)
  (maphash
   (lambda (output object)
     (declare (ignore output))
     (let ((component (atlas-object-component object)))
       (ataxia.world:ui-set-invalidator component nil)
       (ataxia.kernel:drawable-detach-graphics component)
       (ataxia.world:ui-destroy component)))
   (%world-output-components world))
  (clrhash (%world-output-components world))
  (%reap-retired-components world))
