;;;; Infinite World implementation of the shared UI host protocol.
(in-package #:ataxia.infinite-world)

(defmethod ataxia.world:world-outputs ((world infinite-world))
  (mapcar #'%canvas-output-output (%output-states world)))

(defmethod ataxia.world:damage-overlay ((world infinite-world) overlay)
  (%damage-overlay world overlay))

(defmethod ataxia.world:request-overlay-update ((world infinite-world) widget)
  (let ((state (gethash (overlay-output widget) (%world-outputs world))))
    (unless (%world-quiescing-p world)
      (when (and state
                 (or (%updatable-overlay-p world widget)
                     (ataxia.world:damage-pending-p (%world-damage world) (overlay-output widget))))
        (%request-output-state-frame world state))
      (%schedule-component-timer world)))
  widget)
