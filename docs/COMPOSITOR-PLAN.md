# Ataxia Compositor Architecture Plan

Status: planning only. This document does not authorize implementation.

## 1. Objective

Build a Common Lisp Wayland compositor whose native boundary is small, whose
desktop behavior is assembled from independently replaceable CLOS services, and
whose rendering, spatial model, input routing, animation, and agent control can
be changed without rewriting the Wayland bridge.

The design must support both ordinary desktop use and nontraditional worlds.
The conventional desktop is a plugin configuration, not a kernel assumption.

The two previous attempts exposed two distinct failure modes:

1. A compositor-specific design made the unusual world model possible but made
   ordinary Wayland behavior difficult to reuse and extend.
2. A broad second design accumulated responsibilities in one runtime and bound
   its supposedly generic protocols to wlroots object layouts, rendering
   choices, and feature-specific event handling.

This plan keeps the proposed two-layer model, but tightens the boundary around
**mechanism versus policy**, not around the misleading distinction of “logic
versus no logic.”

## 2. Executive Assessment

The proposal is practical when Layer 1 is treated as a **direct Common Lisp
binding to wlroots**, not as a generic native compositor host.

The corrected split is:

- **wlroots/libwayland** own their native objects, protocol state machines,
  backends, renderer primitives, allocator primitives, and DRM/KMS mechanics.
- **Ataxia-authored C** contains only listener trampolines, version probes, and
  wrappers for macros or inline ABI details that CFFI cannot express directly.
- **Layer 1 Common Lisp** owns server construction, event-loop control, typed
  wlroots wrappers, exact signal subscriptions, callback-lifetime copying,
  specialized buffer/FD cleanup, and direct typed native calls.
- **Layer 2 Common Lisp** owns every compositor policy: semantic objects, shell,
  worlds, placement, input routing, focus, cursor, animation, presentation,
  rendering strategy, output policy, hooks, plugins, and agents.

Layer 1 and Layer 2 communicate through protocol-specific Common Lisp generic
functions. An XDG resize request remains an XDG resize request; pointer motion
remains a concrete wlroots pointer event; an output frame remains a concrete
wlroots output signal. Layer 2 calls typed functions such as XDG configure,
seat notification, buffer, render-pass, and output-state operations directly.

There is no invented native event protocol between the layers. In particular,
there is no generic module catalog, event/command envelope, numeric object
handle, completion protocol, or universal lease registry.

The exact boundary is specified in
[wlroots–Common Lisp Boundary and Layer 1–Layer 2 Interface](LAYER-1-2-INTERFACE.md).

## 3. Critical Corrections to the Initial Boundary

### 3.1 Wayland traffic is not a symmetric event stream

Wayland is an asynchronous object protocol. Client-to-compositor messages are
requests; compositor-to-client messages are events. They have ordering,
object-lifetime, serial, role, and double-buffering rules. Treating both
directions as undifferentiated events would lose required semantics.

The design preserves three concrete semantic categories:

1. **Notifications**: facts that already happened in native state.
2. **Requests for policy**: client/backend requests that Layer 2 may accept,
   reject, or answer.
3. **Typed compositor actions**: Layer 2 decisions executed through the exact
   Layer 1 wrapper for the relevant wlroots/libwayland operation.

Layer 2 still handles all policy. Layer 1 preserves these distinctions through
protocol-specific callback and function names rather than a common event class.

### 3.2 “No parsing” is too strict

libwayland and wlroots already parse the wire protocol and maintain protocol
state machines. Layer 1 must additionally copy callback-only data into stable
Lisp values, wrap native objects with typed Lisp objects, duplicate or consume
file descriptors correctly, and validate typed arguments before calling wlroots.

That is translation and lifetime enforcement, not compositor policy.

Layer 1 must not decide:

- where a window belongs;
- whether a window should be focused;
- what a move or resize gesture means;
- how a popup is constrained beyond mandatory protocol validity;
- which animation applies;
- what should be drawn;
- which agent action is authorized.

Layer 1 must enforce:

- whether a typed wrapper is live and of the correct native type;
- whether an operation is legal in the current protocol state;
- whether a serial, buffer, fence, or file descriptor is still valid;
- whether a native resource must be retained before a callback returns;
- whether a mandatory protocol error must be posted;
- whether an operation is permitted at the current callback/safe-point depth.

### 3.3 Some callback data cannot outlive its callback

wlroots surface state and native event payloads may be valid only during the
signal callback. When wlroots is used without its renderer, a committed client
buffer may need to be locked during the commit callback or it can be released
immediately afterward. File descriptors supplied by selection and drag-and-drop
requests also have exact ownership rules.

The wlroots listener enters Common Lisp synchronously. Layer 1 must copy the
exact transient fields or call the concrete retention primitive while that
callback is active. It then invokes the protocol-specific Layer 2 sink. There is
no native queue and no generic lease. A retained surface buffer, owned FD, output
state, or render pass has its own concrete Lisp lifetime type.

### 3.4 Rendering needs wlroots mechanisms, not a custom native host

A renderable frame requires all of the following:

- selecting a DRM format and modifier supported by both the output and GPU;
- allocating and recycling scanout-capable buffers;
- importing client buffers and retaining them for the frame lifetime;
- binding an EGL render target on the correct thread;
- respecting acquire fences and producing release/presentation fences;
- testing and committing KMS/output state;
- releasing buffers only after the backend is finished with them.

These operations cross wlroots, EGL, GBM, DRM, and kernel lifetime domains. A raw
EGL context alone is insufficient, but that does not justify an Ataxia-specific
C graphics protocol.

wlroots owns the native mechanisms. Layer 1 exposes their exact typed APIs in
Common Lisp. A Layer 2 renderer owns frame orchestration, shaders, draw ordering,
damage, effects, color decisions, direct-scanout policy, and every
pixel-producing algorithm.

### 3.5 Security protocols need fail-closed sequencing

Session locking is the clearest example. Normal content must be hidden before
the compositor reports that the session is locked. Layer 2 therefore stops
ordinary presentation, commits blank or valid lock frames, isolates input, and
only then calls the exact wlroots acknowledgement function. If Lisp fails
before acknowledgement, the lock was not established; if it fails afterward,
the last committed frame remains blank or locked.

This ordering keeps the security state machine in Common Lisp without a second
native policy runtime.

### 3.6 Responsibility matrix

| Concern | Layer 1 responsibility | Layer 2 responsibility |
|---|---|---|
| `wl_surface.commit` | copy applied state and retain the exact buffer through typed Lisp wrappers | update semantic content, invalidate scenes, decide presentation |
| XDG configure | expose exact setters/scheduler and ack/commit callbacks | decide geometry/states and match serials to policy transactions |
| Move/resize request | deliver typed seat/serial/edges callback | authorize and run the interactive operation |
| Input | deliver exact device callbacks and expose typed seat notification functions | mapping, grabs, hit testing, focus, cursor, shortcuts, accessibility |
| Clipboard/DND | express exact source/request/FD ownership in typed wrappers | authorization, MIME/action selection, transport/session policy |
| Output | wrap capabilities and exact test/commit calls | arrangement, mode/scale choice, viewports, color and power policy |
| Rendering | wrap wlroots renderer/allocator/buffer/output primitives | frame orchestration, scene, projection, damage, shaders, effects |
| Frame callbacks | expose exact pending callback and presentation functions | decide which sampled surfaces receive feedback |
| Session lock | expose concrete protocol calls | authorize, blank/lock presentation, isolate input, acknowledge in order |
| Animation | provide monotonic/presentation timestamps | definitions, matching, timelines, interpolation, bindings, invalidation |
| Agent control | no direct agent entry point | authentication, capabilities, actions, observations, audit |

Native events must distinguish **requested**, **applied**, **committed**, and
**presented** phases where the protocol makes those phases distinct. Collapsing
them into a generic “changed” event would make configure/ack, synchronized
subsurface commits, frame callbacks, and rollback behavior ambiguous.

## 4. Layer 1: Direct wlroots Bindings in Common Lisp

Layer 1 has three implementation pieces:

- wlroots/libwayland as external native libraries;
- a tiny Ataxia C shim only for listeners, macros, inline ABI details, and
  compile-time version checks;
- Common Lisp CFFI declarations, typed wrappers, exact signal bindings, and
  protocol-specific functions.

Neither Ataxia-authored C nor Layer 1 Lisp contains desktop behavior.

### 4.1 Lisp-owned runtime

Common Lisp directly:

- creates and destroys `wl_display`, the event loop, wlroots backend, renderer,
  allocator, compositor globals, protocol managers, outputs, and seats;
- creates the Wayland socket and starts/stops the backend;
- calls `wl_event_loop_dispatch` and `wl_display_flush_clients`;
- discovers DRM, libinput, nested Wayland, and headless capabilities;
- wraps live wlroots objects with typed Lisp objects;
- invalidates wrappers from the authoritative destroy signals;
- contains callback failures so no Lisp condition unwinds through C;
- exposes structured Lisp conditions around exact native failures.

wlroots signals enter Lisp synchronously on the compositor owner thread. The
callback copies transient fields or retains the exact concrete resource, then
calls a protocol-specific Layer 2 generic function. There is no native event
queue.

### 4.2 Protocol-specific Lisp packages

Each protocol family is a separate Common Lisp package with:

- raw CFFI declarations for the pinned wlroots headers;
- typed wrapper classes for its real wlroots objects;
- listeners for its exact wlroots signals;
- concrete structs for callback data that must be copied;
- protocol-specific Layer 2 sink generic functions;
- typed functions that directly call the relevant `wlr_*` or `wl_*` API;
- no dependency on world, scene, animation, focus, shell, or agent packages.

Protocol packages are independently loadable. The event-loop core does not
contain a switch over protocol names.

Examples:

- core surfaces and subsurfaces;
- XDG toplevels and popups;
- layer surfaces;
- seats and input devices;
- data device, primary selection, and data control;
- text input and input method;
- output management and power;
- session lock;
- presentation, tearing, explicit synchronization, and DMA-BUF;
- capture and screencopy;
- tablet, relative pointer, constraints, and gestures;
- Xwayland association.

### 4.3 Horizontal protocol expansion

Layer 1 is horizontally extensible through peer Common Lisp packages around
actual wlroots protocol implementations:

```text
                         +-- core surface module
                         +-- XDG shell module
                         +-- layer shell module
Common Lisp wlroots -----+-- seat/input package
                         +-- data-transfer module
                         +-- session-lock module
                         +-- DMA-BUF/sync module
                         +-- capture module
                         +-- future protocol module
```

No protocol package sits above another as a framework layer. ASDF dependencies
express real native relationships, such as XDG decoration depending on XDG
shell, but each family defines its own callbacks and functions.

Adding a protocol already implemented by wlroots requires:

1. raw CFFI declarations for the pinned wlroots header;
2. typed Lisp wrapper classes and exact signal listeners;
3. concrete copied callback structs where necessary;
4. protocol-specific Layer 2 sink generic functions;
5. direct typed outbound functions;
6. a Layer 2 policy service if behavior is optional.

It does not require changes to the event-loop core, a module registry, a schema,
an opcode router, a native queue, or a public C ABI.

#### 4.3.1 Exact callback contracts

The Layer 1–Layer 2 interface is Common Lisp. Each package exports exact names,
for example:

```lisp
(defgeneric xdg-toplevel-request-move (sink request))
(defgeneric xdg-toplevel-request-resize (sink request))
(defgeneric pointer-motion (sink event))
(defgeneric keyboard-key (sink event))
(defgeneric output-frame (sink output))
(defgeneric output-present (sink presentation))
```

The copied event value contains only the fields of that concrete wlroots signal.
There is no shared subject/related/payload prefix.

#### 4.3.2 Exact outbound contracts

Layer 2 calls direct typed wrappers, for example:

```lisp
(xdg-toplevel-set-size toplevel width height)
(xdg-surface-schedule-configure xdg-surface)
(seat-pointer-notify-enter seat surface sx sy)
(seat-keyboard-notify-key seat time-msec keycode state)
(output-test-state output state)
(output-commit-state output state)
```

Return values are the real synchronous wlroots results. Asynchronous facts such
as configure acknowledgement, presentation, and destruction return later
through their real typed signals.

#### 4.3.3 Versioning and capability discovery

Ataxia pins one wlroots release line and checks that its raw bindings and tiny C
shim were built against matching headers. A wlroots upgrade is an explicit
binding migration, not a negotiated Layer 1 schema upgrade.

Wayland advertised protocol versions remain separate. Lisp protocol packages
record the globals and versions they actually created, and Layer 2 service
metadata may require those concrete features.

#### 4.3.4 Per-client global filtering

The global filter is a synchronous libwayland callback into a bounded Lisp
predicate. It consults an immutable client-access snapshot and defaults
security-sensitive globals to hidden on error. It must not invoke blocking code
or arbitrary agent work.

#### 4.3.5 Protocols not implemented by wlroots

When only Wayland XML exists, `wayland-scanner` may supply inert generated
interface descriptors while Common Lisp binds `wl_global`, `wl_resource`, and
dispatcher APIs directly. That Lisp package must implement the concrete Wayland
state machine because wlroots no longer supplies it.

A new reusable native primitive should normally be contributed to or exposed by
wlroots instead of expanding an Ataxia-specific host abstraction.

#### 4.3.6 Runtime replacement limits

Protocol policy sinks can be replaced at a Lisp safe point without rebuilding
native code. Advertised globals and already-bound resources cannot always be
unloaded; old resource handlers must remain until their clients destroy them.
This is a Wayland lifetime constraint, not a reason for a native plugin ABI.

#### 4.3.7 Example: XDG toplevel

1. The XDG Layer 1 package creates `wlr_xdg_shell` and installs listeners.
2. A client creates a toplevel. The listener wraps the exact
   `wlr_xdg_toplevel` and calls `xdg-new-toplevel`.
3. The Layer 2 XDG sink creates or updates a view and asks shell/placement
   services for initial policy.
4. Layer 2 calls the typed size/state setters and schedules a configure.
5. The direct wrapper returns the concrete configure serial.
6. The client acknowledges and commits. Exact ack and surface-commit callbacks
   enter their respective Layer 2 sinks.
7. Layer 2 correlates the serial, publishes the view mutation, and schedules
   presentation.
8. A client move or resize request arrives as a policy request containing the
   seat, serial, and edge—not as an automatically executed native operation.
9. The Layer 2 shell service owns the interactive operation and calls typed seat
   delivery/configure functions as needed.

#### 4.3.8 Example: fractional scale

1. The fractional-scale Layer 1 package wraps the real protocol object and calls
   its exact lifecycle sink methods.
2. Layer 2 computes preferred scale from the surface’s current presentation
   across output viewports.
3. Layer 2 calls the concrete preferred-scale wrapper.
4. wlroots/libwayland emit the correct protocol event.

No world coordinate or output arrangement policy exists in Layer 1.

#### 4.3.9 Example: session lock

1. The exact wlroots lock request callback enters the Layer 2 security service.
2. Layer 2 accepts or rejects it through concrete protocol calls.
3. On acceptance, Layer 2 stops ordinary presentation and input routing.
4. It commits blank or valid lock frames for every affected output.
5. It acknowledges the locked state only after those commits are established.
6. Lock-surface callbacks remain exact protocol callbacks; Layer 2 decides output
   assignment and presentation.

#### 4.3.10 Example: capture

1. The capture Layer 1 package delivers the exact request and target-buffer
   wrappers to the Layer 2 capture policy.
2. Layer 2 authorizes it and asks the current capture service for a frame tied to
   a presentation revision.
3. The current renderer performs readback or copy into the concrete capture
   buffer.
4. Layer 2 calls the protocol-specific success/damage/timestamp functions.
5. Concrete buffer and FD wrappers enforce their documented ownership.

The capture package never reaches into renderer internals, and the renderer never
marshals Wayland protocol events.

### 4.4 Object identity and lifetime

Every native object used above raw bindings has a typed Lisp wrapper containing:

- a private CFFI pointer;
- the concrete wrapper class;
- a liveness bit and wrapper generation;
- its authoritative destroy listener;
- optional immutable creation metadata.

Layer 2 receives typed wrappers, never raw pointers. The destroy signal marks a
wrapper dead and clears its pointer. A later typed call signals
`dead-wlr-object` before entering C. A weak pointer-to-wrapper table preserves
identity without duplicating the wlroots object graph.

Buffers, output states, render passes, and file descriptors use specialized
Lisp lifetime objects and matching direct native operations.

### 4.5 Incoming callback contract

Every callback is defined by its protocol package and contains only exact fields
from the pinned wlroots signal. Lifecycle, discrete input, protocol transaction,
and output-frame callbacks are delivered synchronously in wlroots order. Layer 1
does not coalesce or drop them.

The callback barrier copies transient fields, pins the active sink generation,
contains Lisp conditions, tracks nested callback depth, and runs deferred
destruction/effects when the outermost callback exits.

### 4.6 Outgoing typed-function contract

Each public Layer 1 function documents:

- accepted concrete wrapper classes;
- liveness and owner-thread requirements;
- callback-safe, outermost-safe-point, or event-loop-only call mode;
- exact buffer, array, string, and FD ownership;
- concrete native return value and Lisp conditions.

Layer 2 must never infer success: it observes the direct return value or the
later real protocol callback.

### 4.7 Required synchronous mechanisms

The following occur in the synchronous Lisp callback because delaying them is
unsafe:

- locking the exact surface buffer when it must survive commit callback extent;
- copying transient configure, input, and presentation payloads;
- duplicating or transferring file descriptors under concrete protocol rules;
- invalidating typed wrappers from destroy signals;
- retaining buffers until their exact release point;
- performing bounded fail-closed global-filter decisions.

The Ataxia C shim does none of this policy or bookkeeping. It only delivers the
native callback to Lisp while the data is valid.

## 5. Rendering and DRM Boundary

### 5.1 Renderer ownership decision

Three approaches are technically possible:

| Approach | Boundary quality | Practicality | Decision |
|---|---|---|---|
| Use `wlr_scene` as the framework model | Couples world, scene, and hit testing to wlroots 2D policy | Easiest conventional desktop | Reject as the common model |
| Layer 2 renderer uses typed Lisp wrappers around wlroots render passes | Keeps policy/math in Lisp while wlroots owns GPU/backend mechanics | Practical first implementation | Recommended default |
| Layer 2 renderer uses direct Lisp EGL/GLES bindings plus wlroots interop | Maximum shader/control flexibility with stricter lifetime work | Practical specialized backend | Supported plugin |

The renderer is always a Layer 2 service. Its concrete implementation may call
wlroots renderer, allocator, buffer, render-pass, and output APIs through Layer 1
or may use direct Lisp EGL/GLES bindings where wlroots exposes the required
interop. No Ataxia-authored C renderer protocol is introduced.

### 5.2 No wlroots scene dependency

The core architecture must not depend on `wlr_scene`. A conventional planar
plugin may later use it as an optional optimized executor, but the common render
and hit-test contracts cannot use its geometry as their source of truth.

### 5.3 wlroots renderer is a mechanism, not the world model

Using `wlr_renderer` does not require using `wlr_scene`. The initial compositor
may create `wlr_renderer` and `wlr_allocator`, use their exact public buffer and
render-pass APIs, and still keep all scene construction, projection, animation,
damage policy, and hit testing in Layer 2.

If a renderer needs direct client-buffer access, Layer 1 creates a concrete
`surface-buffer-snapshot` during the surface commit callback using the exact
wlroots retention primitive. It is released explicitly when superseded and is
not represented by a generic lease ID.

### 5.4 Graphics service boundary

The selected Layer 2 graphics service owns:

- renderer/device selection policy;
- shader compilation and program caches;
- source color interpretation;
- offscreen targets and texture-import policy;
- mesh/quad/rect execution;
- blending, clipping, effects, and readback;
- synchronization strategy;
- direct-scanout eligibility and fallback.

Layer 1 exposes typed Lisp wrappers for the concrete wlroots renderer, allocator,
buffer, texture, render-pass, output-state, and presentation APIs. wlroots and
its backend own DRM/KMS, GBM/EGL internals, scanout allocation, and native buffer
release. Layer 1 does not wrap those mechanisms in a second C graphics runtime.

All native graphics calls remain owner-thread-bound. A direct GLES plugin uses
an explicit Lisp dynamic extent for the current context and never exposes it to
agent/control threads.

### 5.5 Frame transaction

A frame is a Layer 2 transaction over concrete wlroots wrappers:

1. The exact `wlr_output.events.frame` callback enters the output service.
2. Layer 2 freezes one presentation snapshot and its hit-test index.
3. The selected renderer acquires or configures a concrete wlroots render buffer
   through typed Layer 1 calls.
4. It compiles and executes the render plan using wlroots render passes or the
   selected direct graphics binding.
5. Layer 2 builds a concrete `wlr_output_state`, including damage and buffer.
6. It calls the direct output test function and selects fallback on failure.
7. It calls the direct output commit function.
8. Exact presentation/release callbacks reconcile the frame.
9. Layer 2 sends frame-done and presentation feedback only for surfaces actually
   sampled by a successfully submitted frame.
10. Specialized buffer/render-pass/output-state objects are finished or released
    on success, cancellation, output loss, and shutdown.

No half-rendered frame may be committed after a render failure. Cancellation is
always valid before commit.

### 5.6 Coordinate and orientation contract

The prior upside-down output failure is prevented by one explicit contract:

- render IR uses output-local logical coordinates with origin at top-left and
  positive Y downward;
- texture coordinates use a declared origin per imported buffer;
- the graphics device performs the sole logical-to-clip-space conversion;
- output transform and scale are applied exactly once;
- readback declares row order and channel order;
- render and hit mapping come from the same frozen projection snapshot.

No renderer plugin may guess whether a buffer is inverted.

### 5.7 Performance constraints

- CLOS dispatch is allowed at service, event, plan, and pass boundaries, not per
  pixel or per vertex.
- Render-pass descriptors and GPU data cross FFI at coarse operations.
- A renderer may own one Lisp-managed foreign arena per frame where its concrete
  API benefits from it.
- Shader/program state is cached by immutable descriptor.
- Damage history is per output buffer, not just per output.
- Direct scanout is a Layer 2 proposal tested by the concrete wlroots output API,
  never assumed.
- Capture, software cursor, effects, and color conversion can veto direct scanout.
- Synchronization starts correctness-first; fence-based pipelining is enabled
  only when the backend and GPU executor advertise compatible capabilities.

## 6. Layer 2: Compositor Framework

Layer 2 is not one “compositor” class. It is a small single-writer kernel plus
independent domain protocols.

The concrete CLOS class, service, transaction, and package design is specified in
[Layer 2 CLOS System Design](LAYER-2-CLOS-DESIGN.md).

### 6.1 Runtime kernel

The runtime kernel owns only:

- owner-thread identity;
- native callback depth and safe points;
- stable framework object identities;
- resource lifecycle;
- service registry and atomic replacement;
- hook registry and dispatch;
- command mailbox;
- clocks and frame scheduling coordination;
- observation publication;
- orderly shutdown.

It does not own window location, focus rules, renderer behavior, cursor behavior,
or animation definitions.

A runtime turn is:

1. drain agent/control commands and due Lisp timers;
2. call `wl_event_loop_dispatch` for a bounded interval;
3. let exact wlroots callbacks invoke protocol-specific Layer 2 sinks;
4. commit their framework transactions and outermost-safe-point native effects;
5. advance active clocks and animation graphs;
6. freeze requested presentation snapshots;
7. build, render, and submit frames through typed Layer 1 calls;
8. publish observations and retire dead semantic/native wrappers;
9. flush Wayland clients.

### 6.2 Framework object model

Do not make one large `application` object with fixed location, animation, and
render slots. Separate identity from composition.

Recommended semantic objects:

- **client**: one Wayland connection and security identity;
- **surface**: one protocol surface and committed content state;
- **role**: XDG toplevel, popup, layer surface, cursor, drag icon, lock surface,
  input popup, or another protocol role;
- **view**: a user-manageable presentation of one role/surface tree;
- **application session**: a best-effort grouping of clients/views, never derived
  solely from `app_id` and never used as a native identity;
- **placement**: an opaque value supplied by a world service;
- **presentation entity**: a semantic scene item that can produce render and hit
  content;
- **seat**: logical input/focus state independent of a physical device;
- **output viewport**: one output’s view into one world or output-local overlay;
- **agent principal**: provenance and capabilities for automated actions.

Objects have a bounded component map keyed by service-owned component types.
For example, a view may have a planar placement component under one world plugin
or a spherical placement component under another. The base view never exposes
`x`, `y`, latitude, or quaternion slots.

Components are replaced through their owning service protocol, not mutated by
unrelated plugins.

Wayland does not define a canonical “application” object. One process may create
many clients, one client may create many independently managed toplevels, and an
`app_id` is metadata rather than a secure or unique identity. Placement therefore
belongs to a **view**, not an application session. A grouping policy may move all
views in an application, but it does so through view-placement operations.

### 6.3 Service registry

Every interchangeable component is accessed through a named service:

- services have identity, version, capabilities, dependencies, and generation;
- acquisition returns a generation-pinned service reference for the duration of
  one event or frame transaction;
- replacement constructs and validates a candidate scope before publication;
- failure leaves the prior scope active;
- teardown occurs after no transaction retains the old generation;
- service replacement and plugin activation run only on the owner thread.

Hot lookup is not performed inside inner rendering or hit-test loops. A frame
pins the relevant service generations once.

### 6.4 Hooks

Hooks observe or modify framework transitions. They are not substitutes for
domain protocols.

Each hook declares:

- name and version;
- argument schema;
- reduction rule;
- ordering rule;
- whether veto is allowed;
- failure policy;
- whether it is security critical;
- observation classification.

Handlers have stable identities and real-valued priorities. Mutation during
dispatch applies to the next dispatch, never the current snapshot.

Critical hooks cannot silently ignore failures. Veto results must be honored by
the transaction that dispatched them.

### 6.5 General mutation events

Do not hard-code animation and policy around a short list such as `map`,
`pickup`, and `drop`.

All meaningful framework changes use a common mutation descriptor:

- subject;
- component or semantic property path;
- operation;
- old and proposed values;
- cause;
- provenance;
- timestamp;
- transaction identity;
- arbitrary bounded metadata.

Domain services publish more specific event types when needed, but animation,
observation, and agent policies can match the general descriptor. A plugin may
introduce a new property and transition without changing the animation core.

## 7. Domain Component Structure

### 7.1 Protocol policy adapters

One Layer 2 sink service per protocol family handles the exact Layer 1 callback
generics and proposes semantic framework operations. Sinks contain policy-facing
translation, not raw native storage.

Examples:

- XDG move request -> shell operation request with seat and serial provenance;
- XDG resize request -> interactive resize session;
- layer surface commit -> output-space reservation update;
- surface commit -> content snapshot replacement and damage notification;
- selection request -> transfer-policy decision;
- session lock request -> security-policy transaction.

### 7.2 World and placement

The world service owns all spatial meaning:

- placement construction and replacement;
- relative placement composition;
- camera/view definition;
- projection into output-local presentation geometry;
- inverse query from output-local input to surface-local coordinates;
- visibility, ordering, and spatial navigation;
- serialization for agents and persistence.

The compositor kernel never performs arithmetic on placements.

A conventional desktop world may expose Euclidean helpers, but those helpers are
part of that plugin, not a shared kernel requirement.

### 7.3 Scene and presentation

Scene sources enumerate semantic entities. A presentation builder freezes:

- output and viewport state;
- projected render geometry;
- hit-test mapping;
- sampled surface-buffer snapshots;
- cursor and overlay state;
- animation samples;
- semantic metadata for observations.

The snapshot is immutable. Rendering and input hit testing must use the same
snapshot revision. This prevents animated or transformed windows from being
drawn in one location but receiving input in another.

Output-local overlays, including panels, lock surfaces, notifications, and
layer-shell surfaces, are represented separately from world placement. They must
not be forced into a spherical or infinite world merely because they share an
output.

### 7.4 Shell and interactive operations

Shell behavior is decomposed into:

- role policy;
- placement policy;
- activation/focus policy;
- interactive move operation;
- interactive resize operation;
- maximize/fullscreen/minimize state policy;
- popup constraint policy;
- decoration policy;
- stacking policy;
- workspace/application grouping policy.

Interactive operations are state machines with an initiating serial, seat,
target, starting placement, and cancellation rule. A stuck resize cursor cannot
occur because cursor appearance derives from the live operation state and the
operation must terminate on button release, focus loss, target destruction,
seat removal, or cancellation.

### 7.5 Input pipeline

Input flows through replaceable stages:

1. native device event normalization;
2. device-to-logical-seat assignment;
3. keymap, accessibility, and gesture transforms;
4. active grab or interactive-operation routing;
5. cursor/navigation update;
6. hit query against the current presentation snapshot;
7. focus policy;
8. protocol delivery;
9. observation publication.

Pointer, keyboard, touch, tablet, switches, and synthetic agent input remain
distinct typed events. Synthetic events carry provenance and cannot impersonate
physical input.

Protocol delivery is a seat-sink service. It calls public typed Layer 1 seat
functions and never imports raw CFFI bindings.

### 7.6 Cursor

Cursor responsibilities are separate services:

- motion interpretation;
- constraints;
- hit query;
- focus policy;
- client cursor-surface requests and serial checks;
- theme/shape resolution;
- animation/timeline;
- rendering or hardware-plane choice.

Cursor surfaces are input-transparent presentation content. They are never
eligible as hit-test targets. This is an explicit invariant because violating it
causes the “cursor cannot interact with the window below” failure.

### 7.7 Animation

Animation consists of independent protocols:

- clock;
- event/transition matcher;
- animation-definition resolver;
- timeline scheduler;
- interpolator;
- easing function;
- property binding;
- sample application;
- presentation invalidation.

An animation definition is resolved using the full context:

- subject and its components;
- mutation descriptor;
- cause and provenance;
- current world/profile;
- output and presentation context;
- user/plugin policy.

Therefore two windows can use different animation definitions for the same
semantic transition, and one window can change definitions at runtime. New
transition kinds require no animation-core edit.

Animations may target either:

- authoritative model properties, through a domain service mutation; or
- presentation-only properties, through an immutable presentation overlay.

Presentation animation must update render and hit geometry together. Resize
animation must respect XDG configure/ack/commit boundaries rather than issuing
client configure events on every visual frame.

Performance rules:

- keep an explicit active-animation set;
- resolve definitions once when a transition starts;
- compile bindings and interpolators before sampling;
- sample all active timelines in one frame pass;
- allocate no unbounded per-frame lists;
- damage only affected outputs/regions;
- schedule frames only while timelines or content require them.

### 7.8 Output management

Separate services own:

- output discovery and identity;
- mode/scale/transform policy;
- output arrangement metadata;
- viewport creation;
- color/HDR policy;
- gamma and power policy;
- frame scheduling;
- variable refresh and tearing policy;
- direct-scanout policy.

Layer 2 builds concrete output states and invokes typed Layer 1 test/commit
functions. Layer 2 handles failure and selects fallback; Layer 1 never silently
picks a desktop arrangement.

### 7.9 Transfer, text, and auxiliary protocols

Clipboard, primary selection, drag-and-drop, text input, and input methods use
dedicated brokers because they own file descriptors and multi-step sessions.
Their policy, transport, and protocol delivery remain separate.

No data-transfer path is considered successful merely because a source or offer
was announced. Completion requires explicit terminal state and cleanup.

## 8. Agentic Control Plane

Agent control is not a parallel compositor. It enters the same transactions and
service boundaries as human input and shell policy.

### 8.1 Principals and provenance

Every control connection has an authenticated principal. Every request has fresh
provenance containing:

- connection/session identity;
- request identity;
- declared and granted capabilities;
- timestamp and deadline;
- optional parent transaction;
- audit classification.

### 8.2 Typed actions

Agents submit typed actions, not arbitrary wlroots calls. Action providers
declare schemas, capabilities, preflight, preparation, and commit behavior.

Examples:

- discover semantic objects;
- focus or activate a view;
- request a placement mutation;
- invoke shell operations;
- inject bounded input through a selected logical seat;
- configure outputs;
- request a capture;
- install or replace an approved service/plugin;
- step a virtual clock or frame scheduler.

Authorization, validation, and service generation are pinned across prepare and
commit to prevent time-of-check/time-of-use changes.

### 8.3 Observations

Agents consume versioned semantic snapshots and diffs:

- clients, applications, views, roles, surfaces, and placements;
- focus and active operations;
- outputs and presentation revisions;
- animation and frame state;
- plugin/service generations;
- structured failures and traces.

Observations are bounded and classified. Secure or sensitive content is filtered
before serialization. Screen capture and clipboard access require separate
capabilities.

### 8.4 Trusted Lisp shell

A full Lisp REPL may exist only on an owner-only local socket. Read, evaluation,
and result serialization execute on the compositor owner thread at a safe point.
The REPL is explicitly trusted and is not the agent RPC interface.

## 9. Typical Wayland Protocol Coverage

“Typical compositor stuff” is tracked as explicit capability families rather
than one vague completeness claim.

### 9.1 Bootable core

- core compositor and regions;
- SHM buffers;
- outputs;
- seats with pointer, keyboard, and touch;
- subsurfaces;
- data-device manager;
- XDG shell toplevels and popups;
- presentation frame callbacks;
- viewporter and fractional scale.

### 9.2 Desktop usability

- interactive move and resize;
- activation, maximize, fullscreen, minimize policy;
- XDG decoration negotiation;
- XDG activation;
- XDG dialog, icon, tag, and toplevel-drag metadata when supported by the pinned
  protocol set;
- layer shell for panels and launchers;
- relative pointer and pointer constraints;
- pointer gestures;
- cursor shape and client cursor surfaces;
- idle inhibit and idle notification;
- keyboard shortcuts inhibit;
- primary selection and data control;
- text input and input method;
- tablet tool/pad input;
- foreign toplevel list and workspace metadata;
- XDG foreign relationships;
- system bell and transient-seat support where supported by the pinned protocol
  set;
- Xwayland shell and Xwayland lifecycle.

### 9.3 Rendering and display integration

- Linux DMA-BUF import and feedback;
- explicit synchronization with DRM syncobj timelines;
- presentation timing;
- tearing control and FIFO/commit timing where supported;
- content-type, single-pixel-buffer, alpha-modifier, and color-representation
  metadata where supported;
- output management, power management, gamma, color management, and HDR policy;
- direct scanout and hardware cursor proposals;
- multi-GPU import fallback;
- renderer-owned readback;
- image-copy capture/screencopy;
- DRM lease for non-desktop outputs where desired.

### 9.4 Security and automation

- secure session lock;
- security-context tagging where available;
- virtual input exposed only through capability policy;
- capture/clipboard/input authorization;
- bounded semantic registries, observations, agent mailboxes, and per-client
  resources;
- privileged protocol filtering by client principal.

Support for a protocol does not mean merely advertising its global. Each family
needs exact callback coverage, typed outbound calls, failure handling, teardown,
and real-client evidence.

## 10. Package and Module Plan

The repository should enforce boundaries through separate ASDF systems.

### 10.1 Layer 1 systems

- `ataxia.wlr.raw.*`: private CFFI declarations pinned to wlroots/libwayland;
- `ataxia.wlr.glue`: loading and the minimal listener/inline shim;
- `ataxia.wlr.core`: display, event loop, client, surface, and wrapper lifetime;
- `ataxia.wlr.backend`: backend, output, and input-device discovery;
- `ataxia.wlr.render`: renderer, allocator, buffer, texture, and render pass;
- `ataxia.wlr.seat`: seat objects and exact input delivery functions;
- `ataxia.wlr.protocol.*`: one typed package per protocol family;
- native `libataxia-wlr-glue`: only direct wlroots/libwayland ABI helpers.

Layer 2 systems may import public typed Layer 1 packages but never raw CFFI
packages or foreign pointers.

### 10.2 Layer 2 kernel systems

- `ataxia.kernel.identity`;
- `ataxia.kernel.resources`;
- `ataxia.kernel.events`;
- `ataxia.kernel.services`;
- `ataxia.kernel.hooks`;
- `ataxia.kernel.plugins`;
- `ataxia.kernel.mailbox`;
- `ataxia.kernel.runtime`;
- `ataxia.kernel.observation`.

### 10.3 Layer 2 domain systems

- `ataxia.protocol-policy.*`;
- `ataxia.world`;
- `ataxia.scene`;
- `ataxia.presentation`;
- `ataxia.render`;
- `ataxia.output`;
- `ataxia.input`;
- `ataxia.cursor`;
- `ataxia.focus`;
- `ataxia.shell`;
- `ataxia.animation`;
- `ataxia.transfer`;
- `ataxia.text`;
- `ataxia.capture`;
- `ataxia.security`;
- `ataxia.agent`;
- `ataxia.control`.

### 10.4 Profile/plugin systems

- conventional finite desktop;
- infinite planar world;
- spherical/non-Euclidean reference world;
- wlroots render-pass executor;
- direct Lisp EGL/GLES executor;
- optional wlroots-scene planar executor;
- default shell/focus/input/cursor/animation policy;
- headless deterministic profile.

No default plugin may be required by the kernel to start.

## 11. Failure Containment and Replacement

### 11.1 Transaction boundaries

The following are atomic from Layer 2’s perspective:

- plugin/service replacement;
- one protocol policy response;
- one framework mutation;
- one input protocol frame;
- one animation sample publication;
- one presentation snapshot;
- one output frame submission;
- one multi-output configuration;
- one agent action batch when its provider declares atomic support.

Native operations that cannot be rolled back must return honest partial or
terminal state. The framework must not claim rollback it cannot perform.

### 11.2 Cleanup ordering

Cleanup proceeds from policy toward native mechanism:

1. stop accepting new control work;
2. cancel interactive operations and animation bindings;
3. quiesce protocol policy sinks;
4. release presentation and surface-buffer snapshots;
5. cancel frame transactions;
6. retire framework resources;
7. detach listeners, destroy protocol globals, and invalidate typed wrappers;
8. stop backends and destroy EGL/GBM/Wayland objects.

Every cleanup operation is idempotent.

### 11.3 Owner-thread rule

All native calls, framework mutations, plugin replacement, and REPL evaluation
occur on the compositor owner thread. Worker threads may compile shaders, encode
captures, or perform agent computation only against detached immutable data and
must return results through the mailbox.

## 12. Performance Feasibility

The architecture is performant if it avoids fine-grained boundary crossings.

### 12.1 Expected hot paths

- pointer/tablet motion and axis streams;
- surface commits and damage;
- active animation sampling;
- projection and hit testing;
- render-plan construction;
- render-pass construction and GPU submission;
- observation diffs for active agents.

### 12.2 Required techniques

- direct listener-token lookup on the callback path;
- specialized callback structs and foreign-memory arenas where measured;
- immutable snapshots with structural sharing;
- cached service-generation lookup per transaction;
- compiled render and animation descriptors;
- bulk FFI arrays rather than one call per vertex;
- spatial acceleration owned by the active world implementation;
- dirty propagation and per-output damage;
- no full-scene semantic serialization on every observation;
- frame scheduling driven by output deadlines and active work;
- profiling counters at every layer boundary.

### 12.3 Performance gates

Before adding visual complexity, the implementation must measure:

- native-callback-to-policy latency under high-rate pointer motion;
- frame build, render, and commit time separately;
- allocation volume per idle and animated frame;
- callback depth, duration, and any Layer 2 coalescing counts;
- buffer age and damaged area;
- animation count and sample time;
- hit-test query time;
- agent observation queue pressure;
- missed presentation deadlines.

The target is not “zero CLOS dispatch.” The target is no unbounded allocation or
fine-grained FFI in the frame and input inner loops.

## 13. Development Milestones and Evidence

Implementation must proceed as vertical slices, not by building every abstract
protocol before a real client works.

### Milestone 0: Boundary freeze

Deliverables:

- approve this architecture and unresolved decisions;
- freeze typed Layer 1 callback/function ownership rules;
- freeze coordinate, buffer, and frame transaction contracts;
- define dependency rules enforced by ASDF/package boundaries.

Evidence:

- written architecture decisions;
- no implementation begins before approval.

### Milestone 1: Native lifecycle

Deliverables:

- headless Wayland display and backend;
- socket creation;
- exact typed output/input discovery callbacks;
- typed wrapper creation and destroy-signal invalidation;
- clean stop and dead-wrapper behavior.

Evidence:

- headless process starts, reports devices, dispatches, and stops cleanly;
- Ataxia-authored C contains only audited wlroots/libwayland ABI glue.

### Milestone 2: Surface-to-pixel vertical slice

Deliverables:

- core surface/subsurface and XDG toplevel callbacks;
- surface-buffer snapshots;
- wlroots render-pass or direct-GLES output path;
- one Layer 2 planar renderer and presentation snapshot;
- exact frame-done and presentation calls/callbacks.

Evidence:

- a real SHM XDG client maps and presents correctly;
- orientation, channels, scale, and transform are verified;
- no `wlr_scene` dependency in the world/presentation model.

### Milestone 3: Usable desktop interaction

Deliverables:

- keyboard, pointer, touch, focus, and client cursor;
- move and resize state machines;
- popup placement;
- layer-shell output overlays;
- clipboard and drag-and-drop basics.

Evidence:

- terminal typing works;
- Firefox spawns, maps popups, accepts keyboard input, and moves/resizes;
- pointer resize mode always terminates correctly;
- cursor never intercepts hit testing;
- a top bar renders in correct output-local geometry.

### Milestone 4: Extensible worlds and rendering

Deliverables:

- opaque world/placement protocols;
- shared presentation snapshot for render and hit;
- finite, infinite, and curved reference projections;
- quad and textured-mesh render commands.

Evidence:

- the same live client can be presented and interacted with in all reference
  worlds without modifying protocol or input adapters.

### Milestone 5: General animation

Deliverables:

- mutation matcher, definition resolver, clocks, timelines, bindings, and
  presentation integration;
- per-object and per-context animation policy;
- bounded active-set scheduler.

Evidence:

- two windows use different animation definitions for the same transition;
- animations can be replaced from the Lisp shell;
- render and hit geometry remain identical throughout animation;
- frame pacing and allocation measurements remain within agreed limits.

### Milestone 6: Agentic control

Deliverables:

- typed RPC, observation diffs, provenance, capabilities, action providers;
- input injection through the live input pipeline;
- semantic discovery, focus, placement, output, capture, and plugin actions;
- trusted local Lisp REPL.

Evidence:

- unauthorized requests have zero compositor effects;
- service replacement is visible immediately and remains rollback-safe;
- agents can operate terminal and Firefox through semantic and input actions.

### Milestone 7: Production protocol and DRM coverage

Deliverables:

- DMA-BUF feedback/import, explicit sync, multi-output atomic state;
- capture, session lock, text input/input method, tablet, output management,
  Xwayland, presentation, tearing, color, and power features;
- resource and queue quotas.

Evidence:

- DRM, nested, and headless runs;
- real protocol clients for each privileged or lifecycle-heavy family;
- Firefox and terminal soak run with repeated open/close, resize, clipboard,
  popup, fullscreen, suspend/resume, and output changes;
- no growth in live native wrappers after object churn;
- secure lock never reveals an unlocked frame.

## 14. Rejected Designs

- A generic native host above wlroots with module catalogs, object handles,
  event/command envelopes, schemas, queues, and universal leases.
- Ataxia-authored C that owns the server lifecycle, event routing, graphics
  abstraction, or protocol policy.
- One unrestricted package that exposes raw wlroots structs and foreign pointers
  to all framework code.
- Raw native pointers as framework identities.
- A bridge that owns window movement, focus, scene layout, or animation policy.
- A framework that pretends buffer/fence/KMS lifetime can be handled after the
  native callback has returned.
- `wlr_scene` as the universal world and hit-test model.
- A fixed Euclidean position slot on applications or views.
- Feature-specific animation triggers hard-coded into the animation core.
- Separate render and input geometry calculations.
- One global cursor service that combines motion, focus, surface requests,
  appearance, and rendering.
- Agents mutating compositor objects from control threads.
- Advertising protocol globals before their lifecycle and security semantics are
  implemented.
- Broad “all typical protocols supported” claims based only on globals appearing
  in a registry dump.

## 15. Decisions Required Before Implementation

The following choices remain explicit approval points:

1. **Graphics execution**: choose the initial Layer 2 renderer implementation:
   typed wlroots render passes or direct Lisp EGL/GLES.
2. **Lisp implementation**: choose SBCL-only initial bindings or immediate
   portability across multiple Common Lisp implementations.
3. **Xwayland scope**: include it in the first usable desktop milestone or defer
   it until native Wayland Firefox/terminal workflows are stable.
4. **Plugin trust**: decide whether plugins are trusted in-process Lisp only, or
   whether untrusted/out-of-process extensions are a first-class requirement.
5. **Agent trust model**: define which local principals may use the trusted REPL,
   inject input, capture content, read clipboard data, and replace services.
6. **Default desktop**: approve the conventional planar profile as the initial
   usability target while retaining world independence in every contract.
7. **Protocol target**: select the pinned wlroots and wayland-protocols versions
   for the first implementation baseline.

No implementation should begin until these decisions and the direct
wlroots/Common Lisp boundary are approved.

## 16. Primary References

- [Wayland architecture](https://wayland.freedesktop.org/architecture.html)
- [Wayland protocol and model of operation](https://wayland.freedesktop.org/docs/book/Protocol.html)
- [Wayland content updates](https://wayland.freedesktop.org/docs/book/Content_Updates.html)
- [Wayland server API](https://wayland.freedesktop.org/docs/html/apc.html)
- [wlroots output API](https://wlroots.pages.freedesktop.org/wlroots/wlr/types/wlr_output.h.html)
- [wlroots compositor/surface API](https://wlroots.pages.freedesktop.org/wlroots/wlr/types/wlr_compositor.h.html)
- [wlroots output swapchain manager](https://wlroots.pages.freedesktop.org/wlroots/wlr/types/wlr_output_swapchain_manager.h.html)
- [Linux DRM/KMS documentation](https://docs.kernel.org/gpu/drm-kms.html)
- [Linux DMA-BUF allocation and exchange](https://docs.kernel.org/userspace-api/dma-buf-alloc-exchange.html)
- [Linux DMA-BUF sharing and synchronization](https://docs.kernel.org/driver-api/dma-buf.html)
- [Khronos EGL registry](https://registry.khronos.org/EGL/)
- [EGL DMA-BUF image import](https://registry.khronos.org/EGL/extensions/EXT/EGL_EXT_image_dma_buf_import.txt)
- [EGL native fence synchronization](https://registry.khronos.org/EGL/extensions/ANDROID/EGL_ANDROID_native_fence_sync.txt)
