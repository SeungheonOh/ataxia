# Ataxia Compositor Framework

This document describes the implemented Common Lisp compositor framework that
sits above `ataxia.runtime`. Runtime remains the wlroots bridge; this layer owns
policy, world geometry, presentation, input routing, animation, extensions, and
agent control.

## Execution model

- `compositor` is the aggregate and the Runtime event sink.
- Runtime callbacks enter the aggregate on the Wayland event-loop thread.
- The aggregate calls the responsible component synchronously; internal
  components do not communicate through mailboxes.
- Only external control submissions cross a bounded queue. An `eventfd` wakes
  the Wayland loop and the typed action then executes on the owner thread.
- Foreign wlroots objects remain Runtime objects. Layer 2 stores those objects
  only where identity or a protocol operation is required.

## Components

| Role | Default class | Responsibility |
| --- | --- | --- |
| `:world` | `planar-world` | Placement, projection, inverse projection, hit geometry, and interactive movement math |
| `:graphics` | `direct-gles-renderer` | Direct GLES frame execution and replaceable shader programs |
| `:outputs` | `output-system` | Output wrappers, viewports, swapchains, and refresh-paced frame state |
| `:surfaces` | `surface-system` | Retained client buffers, textures, and subsurface relationships |
| `:desktop` | `desktop-system` | Applications, XDG views, nested popups, and stacking |
| `:presentation` | `presentation-system` | Immutable frame snapshots shared by rendering and hit testing |
| `:interaction` | `interaction-system` | Logical seats, device assignment, focus, cursor state, move, and resize grabs |
| `:extensions` | `extension-system` | Typed synchronous hook registry |
| `:control` | `control-system` | Capability-checked typed actions from Lisp or agent callers |
| `:animation` | `animation-engine` | Per-subject transition resolution and sampling |

`make-compositor-component` is specialized by role. A compositor profile can
replace a role without modifying the aggregate:

```common-lisp
(defclass spherical-compositor (ataxia.compositor:compositor) ())
(defclass spherical-world (ataxia.compositor:world) ())

(defmethod ataxia.compositor:make-compositor-component
    ((compositor spherical-compositor) (role (eql :world))
     &rest initialization-arguments)
  (apply #'make-instance 'spherical-world
         :compositor compositor initialization-arguments))
```

A world implementation supplies `world-place-view`, `world-update-placement`,
`world-project`, `world-unproject`, `world-hit-test`, `copy-world-placement`, and
`world-update-interactive-operation`. Consequently, surface coordinates,
cursor-to-surface coordinates, rendering geometry, and interactive transforms
all follow the same replaceable world contract.

## Runtime connection

`compositor` implements Runtime's event generics directly. Examples include:

- output discovery, frame, damage, present, state request, and destruction;
- input discovery, pointer, keyboard, seat cursor, and device destruction;
- surface commit, map, unmap, subsurface, and destruction;
- XDG toplevel and popup lifecycle and client requests.

Outgoing operations remain Wayland-specific Runtime calls: configure an XDG
toplevel, notify seat focus, send pointer events, create a logical seat, submit
an output state, or send surface frame completion. Layer 2 does not construct an
arbitrary event envelope around these calls.

Protocol objects created by policy use Runtime constructors. The current
framework creates XDG shell, data-device manager, logical seats, and output
globals. New protocol families should add exact Runtime constructors/events and
then a focused Layer 2 component or aggregate methods for their policy.

## Presentation and damage

One `presentation-snapshot` is authoritative for both draw order and hit
testing. It contains projected decorations, client surfaces, subsurfaces,
nested XDG popups, panel content, and every logical-seat cursor.

Damage and state changes mark an output for redraw. The output system coalesces
requests, tracks wlroots `frame_pending`, and schedules one render at the next
refresh deadline. Rendering is deferred out of backend callbacks before it
acquires a swapchain buffer, preventing a second atomic commit in the same DRM
turn. Active animations keep the redraw flag set until sampling completes.

The renderer is intentionally direct GLES. It uses Runtime's wlroots-owned EGL
context, imports the client's wlroots texture as GLES texture attributes, draws
into a scanout-compatible buffer, and commits that buffer through an exact
output state. Core provides solid, surface-texture, and generic shader-material
execution only. Behavior code owns visible background selection, shadows, and
other effect shader definitions.

## Per-window animation and shaders

Animation selection is typed rather than based on event-name keywords.
`visibility-transition`, `placement-transition`, `interaction-transition`, and
`content-transition` are ordinary CLOS descriptors. Additional descriptor
classes can be introduced without changing the engine.

Each view has its own `animation-policy`. A policy maps a descriptor class to an
`animation-definition`, so two windows can use different duration, easing,
presentation properties, or shader-uniform tracks for the same transition.
Resolution order is:

1. an override carried by the transition descriptor;
2. the subject view's policy;
3. the engine's default resolver.

Tracks can animate `opacity`, `scale`, `offset-x`, `offset-y`, a
`shader-uniform-binding`, or a behavior-owned `effect-parameter-binding`.
Effect parameters are stored per view and may drive any behavior material.
The default move interaction animates `elevation`; the shadow behavior maps it
to cast offset and blur while retaining a close ambient shadow on every edge.
Shader programs are compiled in the live EGL context, registered by name, and
selected per view. Agents with local shader capability can replace source and
update uniforms through typed control actions.

Animation lifecycle hooks are `animation-resolving`,
`before-animation-start`, `after-animation-start`, `animation-cancelled`, and
`animation-completed`. Interaction and component replacement have their own
typed hooks. Required correctness never depends on an observer hook.

## Seats and agent control

The interaction system supports multiple logical seats in one compositor.
Input devices can be assigned or reassigned to a seat, focus is tracked per
seat, and every seat has independent pointer coordinates, client cursor state,
and a rendered cursor item. XDG activation stays active while any seat focuses
the view.

The control system currently provides typed actions for observation, focus,
movement and placement, seat creation/destruction, device assignment, live
world replacement, viewport pan/zoom, application launch, per-view animation,
shader installation, and per-view shader configuration. Capabilities are
checked before an action reaches compositor state.

Live world replacement runs at an owner-thread safe point, rejects active
interactive grabs, invokes typed replacement hooks, migrates every view
placement, swaps the component, and rolls back on failure.

## Running

The compositor entrypoint is `scripts/run-compositor`:

```sh
./scripts/run-compositor --backend headless --launch foot
./scripts/run-compositor --backend auto --launch firefox
```

On the Fedora UTM guest, direct DRM/GLES execution uses the seat backend and
render node selected by the environment:

```sh
LIBSEAT_BACKEND=seatd \
WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128 \
./scripts/run-compositor --backend auto --launch firefox
```

No `wlr_scene` renderer is used.
