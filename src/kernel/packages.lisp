;;;; Kernel package boundary.
;;;;
;;;; ATAXIA.KERNEL exports stable compositor objects, the contracts a World
;;;; implements, and the narrow mechanisms a World may invoke. wlroots objects
;;;; remain owned by ATAXIA.RUNTIME.

(defpackage #:ataxia.kernel
  (:use #:cl)
  (:export
   ;; Shared object protocols.
   #:drawable
   #:interactable
   #:render-source
   #:drawable-surface
   #:drawable-surface-id
   #:drawable-surface-local-x
   #:drawable-surface-local-y
   #:drawable-surface-width
   #:drawable-surface-height
   #:drawable-surface-order
   #:drawable-surface-source-box
   #:drawable-surface-buffer-transform
   #:drawable-surface-render-source
   #:drawable-surface-protocol-token
   #:drawable-surface-damage
   #:drawable-surface-generation
   #:drawable-surfaces
   #:drawable-local-bounds
   #:retain-render-source
   #:release-render-source
   #:interaction-result
   #:make-interaction-result
   #:interaction-result-status
   #:interaction-result-object
   #:interaction-result-focus-changed-p
   #:interaction-result-capture-changed-p
   #:interactable-pointer-motion
   #:interactable-pointer-button
   #:interactable-pointer-axis
   #:interactable-key-event
   #:interactable-focus
   #:request-object-configuration
   #:request-object-state

   ;; Kernel-owned stable objects.
   #:kernel-object
   #:object-kernel
   #:object-id
   #:object-generation
   #:object-state
   #:kernel-output
   #:output-runtime-object
   #:output-name
   #:output-description
   #:output-width
   #:output-height
   #:output-scale
   #:output-enabled-p
   #:kernel-input-device
   #:input-runtime-object
   #:input-name
   #:input-type
   #:input-seat
   #:logical-seat
   #:seat-runtime-object
   #:seat-name
   #:seat-capabilities
   #:seat-input-devices
   #:surface-node
   #:surface-runtime-object
   #:surface-parent
   #:surface-children
   #:surface-local-x
   #:surface-local-y
   #:surface-width
   #:surface-height
   #:surface-mapped-p
   #:surface-commit-sequence
   #:wayland-application
   #:application-toplevel
   #:application-root-surface
   #:application-title
   #:application-app-id
   #:application-mapped-p

   ;; Kernel/World contract.
   #:world
   #:world-attached
   #:world-kernel
   #:world-quiescing
   #:world-register-object
   #:world-unregister-object
   #:world-object-changed
   #:world-object-invalidated
   #:world-output-added
   #:world-output-changed
   #:world-output-removing
   #:world-seat-added
   #:world-seat-removing
   #:world-cursor-motion
   #:world-cursor-button
   #:world-cursor-axis
   #:world-key-event
   #:world-client-request
   #:world-graphics-attached
   #:world-render
   #:world-frame-committed
   #:world-frame-failed
   #:world-graphics-detaching

   ;; Frame boundary.
   #:frame-lease
   #:frame-output
   #:frame-target-token
   #:frame-framebuffer
   #:frame-width
   #:frame-height
   #:frame-scale
   #:frame-transform
   #:frame-timestamp
   #:frame-generation
   #:frame-lease-valid-p
   #:world-frame-result
   #:frame-result-target-token
   #:frame-result-damage
   #:frame-result-protocol-tokens
   #:frame-result-complete-p
   #:frame-result-world-cookie

   ;; Kernel aggregate and mechanisms.
   #:kernel
   #:make-kernel
   #:kernel-runtime
   #:kernel-world
   #:kernel-state
   #:kernel-objects
   #:kernel-outputs
   #:kernel-input-devices
   #:kernel-seats
   #:find-kernel-object
   #:attach-runtime
   #:detach-runtime
   #:install-world
   #:create-logical-seat
   #:destroy-logical-seat
   #:request-output-frame
   #:set-wayland-surface-output-membership))
