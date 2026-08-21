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

The proposal is practical, with one necessary correction:

> Layer 1 cannot stop at creating an EGL context and cannot be entirely free of
> protocol-specific mechanics. It must own native object lifetime, protocol
> validity, buffer ownership, synchronization, and output transactions. Layer 2
> must own all desktop policy, scene construction, rendering algorithms, input
> decisions, animation definitions, and agent behavior.

This correction does not recreate a monolith. It gives Layer 1 a narrow,
testable responsibility: faithfully translate and safely execute native
mechanisms. It prevents raw wlroots pointers, short-lived callback data, file
descriptors, GPU fences, and KMS state from leaking into the framework.

The practical split is:

- **Layer 1: Native substrate and Common Lisp bridge**
  - owns libwayland, wlroots, DRM/KMS backend objects, EGL/GBM platform objects,
    native input devices, protocol resources, and their exact lifetimes;
  - captures incoming protocol/backend activity into immutable typed events;
  - executes validated outgoing commands from Layer 2;
  - exposes opaque handles, buffer leases, frame targets, capabilities, and
    completion results;
  - contains no window-management, focus, layout, animation, or desktop policy.
- **Layer 2: Compositor framework**
  - owns semantic objects and component composition;
  - consumes every Layer 1 event and decides every optional response;
  - owns world models, placement, scene construction, hit testing, rendering
    algorithms, input routing, focus, shell behavior, animations, plugins,
    hooks, and agent control;
  - uses Layer 1 only through a versioned command/event contract.

## 3. Critical Corrections to the Initial Boundary

### 3.1 Wayland traffic is not a symmetric event stream

Wayland is an asynchronous object protocol. Client-to-compositor messages are
requests; compositor-to-client messages are events. They have ordering,
object-lifetime, serial, role, and double-buffering rules. Treating both
directions as undifferentiated events would lose required semantics.

The bridge therefore exposes three categories:

1. **Notifications**: facts that already happened in native state.
2. **Requests for policy**: client/backend requests that Layer 2 may accept,
   reject, or answer.
3. **Commands and completions**: Layer 2 decisions executed by Layer 1, followed
   by a success, rejection, stale-object, or retry result.

Layer 2 still handles all policy. Layer 1 preserves the protocol distinction.

### 3.2 “No parsing” is too strict

libwayland and wlroots already parse the wire protocol and maintain protocol
state machines. The bridge must additionally copy callback-only data into stable
values, translate native pointers into handles, duplicate or consume file
descriptors correctly, and validate command arguments before calling wlroots.

That is translation and lifetime enforcement, not compositor policy.

Layer 1 must not decide:

- where a window belongs;
- whether a window should be focused;
- what a move or resize gesture means;
- how a popup is constrained beyond mandatory protocol validity;
- which animation applies;
- what should be drawn;
- which agent action is authorized.

Layer 1 must decide or enforce:

- whether a handle is live and of the correct native type;
- whether an operation is legal in the current protocol state;
- whether a serial, buffer, fence, or file descriptor is still valid;
- whether a native resource must be retained before a callback returns;
- whether a mandatory protocol error must be posted;
- whether a security invariant requires an immediate fail-closed action.

### 3.3 Some callback data cannot wait for Lisp

wlroots surface state and native event payloads may be valid only during the
signal callback. When wlroots is used without its renderer, a committed client
buffer may need to be locked during the commit callback or it can be released
immediately afterward. File descriptors supplied by selection and drag-and-drop
requests also have exact ownership rules.

Layer 1 must synchronously acquire a native lease or copy the value before
queuing the event. Layer 2 receives the lease and decides how to use it. Delaying
the acquisition itself until Layer 2 runs is not safe.

### 3.4 Layer 1 must do more than create EGL

A renderable frame requires all of the following:

- selecting a DRM format and modifier supported by both the output and GPU;
- allocating and recycling scanout-capable buffers;
- importing client buffers and retaining them for the frame lifetime;
- binding an EGL render target on the correct thread;
- respecting acquire fences and producing release/presentation fences;
- testing and committing KMS/output state;
- releasing buffers only after the backend is finished with them.

These operations cross wlroots, EGL, GBM, DRM, and kernel lifetime domains. A raw
EGL context alone is insufficient.

The corrected rule is:

> Layer 1 owns the graphics substrate and frame transaction. A Layer 2 renderer
> owns shaders, render passes, draw ordering, damage policy, effects, color
> decisions, and every pixel-producing algorithm.

### 3.5 Security protocols need native fail-closed behavior

Session locking is the clearest example. The protocol requires normal content
to be hidden before the compositor reports that the session is locked. If Lisp
is stalled or fails during a lock transition, Layer 1 must be able to blank the
outputs and suppress ordinary input immediately. Layer 2 owns authorization and
lock-surface policy, but Layer 1 owns the emergency invariant.

This is the only class of deliberate native fallback: protocol correctness,
resource safety, and fail-closed security. It must never become desktop policy.

### 3.6 Responsibility matrix

| Concern | Layer 1 responsibility | Layer 2 responsibility |
|---|---|---|
| `wl_surface.commit` | preserve applied state, lock the exact buffer, copy damage/regions/viewport, report sequence | update semantic content, invalidate scenes, decide presentation |
| XDG configure | validate role state, send configured values, return serial, report ack/commit | decide geometry and states, match serial to policy transaction |
| Move/resize request | copy seat/serial/edges and revalidate native serial on delivery | authorize and run the interactive operation |
| Input | report raw device events and execute seat notification commands | mapping, grabs, hit testing, focus, cursor, shortcuts, accessibility |
| Clipboard/DND | retain source/request handles, transfer FD ownership safely | authorization, MIME/action selection, transport/session policy |
| Output | report capabilities, test/commit requested native state | arrangement, mode/scale choice, viewports, color and power policy |
| Rendering | acquire target, preserve buffer/fence lifetime, submit output state | scene, projection, damage, shaders, draw/effect algorithm |
| Frame callbacks | expose pending callbacks and send requested completion | decide which sampled surfaces receive frame done/presentation feedback |
| Session lock | enforce blanking/input suppression and native lock lifecycle | authorize locker, arrange lock surfaces, recovery policy |
| Animation | provide monotonic/presentation timestamps | definitions, matching, timelines, interpolation, bindings, invalidation |
| Agent control | no direct agent entry point | authentication, capabilities, actions, observations, audit |

Native events must distinguish **requested**, **applied**, **committed**, and
**presented** phases where the protocol makes those phases distinct. Collapsing
them into a generic “changed” event would make configure/ack, synchronized
subsurface commits, frame callbacks, and rollback behavior ambiguous.

## 4. Layer 1: Native Substrate and Lisp Bridge

Layer 1 is one conceptual layer with two implementation halves:

- a C library that owns native resources and callbacks;
- a thin Common Lisp binding that copies ABI values into Lisp objects and sends
  commands back to the C library.

Neither half contains desktop behavior.

### 4.1 Native runtime

Responsibilities:

- create and destroy `wl_display`, the event loop, wlroots backends, and seats;
- add and report the Wayland socket;
- start, dispatch, stop, and tear down the backend on one owner thread;
- discover DRM, libinput, nested Wayland, and headless backend capabilities;
- expose monotonic opaque handles instead of pointers;
- keep separate live registries for native object kinds;
- retire handles deterministically and bound tombstone history;
- expose structured errors without relying on global `errno` alone.

The bridge must never invoke arbitrary Lisp from a wlroots signal. Signals append
bounded native events. Lisp drains them at explicit safe points.

### 4.2 Protocol adapters

Each protocol family is a separate native module with the same shape:

- constructor/destructor for its global or manager;
- listeners that snapshot requests and lifecycle changes;
- typed information queries for live objects;
- commands that emit compositor-to-client protocol events;
- no dependency on desktop, world, scene, or animation modules.

Protocol modules must be independently enabled. The core bridge must not become
one file containing every protocol.

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

Layer 1 is horizontally extensible. The native runtime is a host substrate and
each Wayland protocol family is a peer module attached to that host:

```text
                         +-- core surface module
                         +-- XDG shell module
                         +-- layer shell module
Wayland/wlroots host ----+-- seat/input module
                         +-- data-transfer module
                         +-- session-lock module
                         +-- DMA-BUF/sync module
                         +-- capture module
                         +-- future protocol module
```

No protocol module sits “above” another protocol module as a framework layer.
Dependencies are declared, but every module speaks to the same host interfaces.

Adding an ordinary protocol must not require editing the event-loop core, object
registry, queue implementation, or server lifecycle. It adds:

1. one native module implementing wire/native mechanics;
2. one Common Lisp Layer 1 decoder/command wrapper;
3. one Layer 2 policy adapter if the protocol has compositor policy;
4. one or more Layer 2 service extensions where its semantics belong.

#### 4.3.1 Native module descriptor

Each native protocol module declares a descriptor containing:

- stable module name and numeric namespace;
- module schema version;
- required native-host ABI range;
- protocol interface names and maximum advertised versions;
- required host capabilities;
- dependencies on other protocol modules;
- initialization, start, quiesce, and finish functions;
- event schema table;
- command schema and executor table;
- native object-kind table;
- default global-exposure classification;
- resource and queue quotas.

The host discovers all linked descriptors, validates dependency closure, and
starts modules in topological order. It stops them in reverse order.

The first implementation should compile modules as separate translation units
linked into one native library. This provides source and ownership separation
without prematurely freezing a `dlopen` plugin ABI. Runtime enable/disable and
per-client global filtering are still supported. Dynamically loaded native
modules can be added after the host ABI and failure model are proven.

Common Lisp protocol and policy modules remain dynamically replaceable from the
beginning.

#### 4.3.2 Native host interface

Protocol modules receive a narrow internal host interface instead of the whole
server structure. It provides only mechanisms:

- allocate, look up, and retire typed handles;
- attach wrappers to client and parent lifetimes;
- publish a bounded typed event;
- register a command executor;
- acquire and release buffer, FD, timeline, and frame-target leases;
- read server/backend capability snapshots;
- request mandatory protocol disconnect/error reporting;
- write structured diagnostics;
- query owner-thread and shutdown state.

The host interface does not expose world, view, focus, shell, animation, scene,
or agent objects because those exist only in Layer 2.

A module must not reach into another module’s private wrapper. Cross-protocol
relationships use typed handles and declared host queries. For example, an XDG
toplevel refers to its core surface handle rather than a foreign
`struct atx_surface *` field owned by another translation unit.

#### 4.3.3 Extensible event envelope

The public event ABI must not be one ever-growing C union. That design makes each
new protocol change the size and layout of all events and eventually recreates a
monolithic bridge.

Use a fixed event envelope:

- native-host ABI version;
- module namespace;
- module schema version;
- module-local event opcode;
- event flags and loss class;
- sequence and timestamp;
- subject, related, and parent handles;
- payload size and payload identity.

The payload is a bounded, size-prefixed, pointer-free module record. Variable
strings and arrays live in a bounded event-owned blob and are copied before the
event is acknowledged. The Lisp decoder for that module knows the record schema.
Unknown optional fields are ignored by size; unknown required schema versions are
rejected during module negotiation.

This preserves static type checking inside each protocol module without making
the host event structure grow for every extension. It is preferable to a
string-keyed property list at the native boundary because native payloads need
precise bounds, ownership, and ABI layouts.

#### 4.3.4 Extensible command envelope

Outgoing operations use the corresponding fixed command envelope:

- module namespace and schema version;
- module-local command opcode;
- command/correlation identity;
- target handle and expected object kind;
- bounded pointer-free command payload;
- optional lease identities;
- required state/generation preconditions.

The host routes the command directly to the owning protocol module. The module
revalidates native state at execution time, performs the wlroots/libwayland call,
and returns a typed completion payload.

Layer 2 can therefore “emit all events” in the policy sense: it chooses every
optional compositor-to-client message by submitting a command. Layer 1 remains
the component that serializes that choice into the correct native protocol event
and enforces ordering and lifetime.

Protocol-mandated housekeeping may remain automatic in Layer 1. Examples include
destroying inert resources, replying to mandatory display mechanics, and posting
a protocol error for an invalid request. These are not policy choices.

#### 4.3.5 Capability and schema negotiation

At startup, the Lisp bridge queries the native module catalog. A Layer 1 Lisp
module activates only if:

- the native module is present;
- its schema version is supported;
- required host capabilities are available;
- its dependency modules are active.

Layer 2 sees protocol capabilities through immutable service metadata. A policy
plugin can require `xdg-shell >= 7`, `linux-dmabuf >= 5`, or an explicit-sync
capability without importing native constants.

Protocol XML version, native module schema version, Layer 1 host ABI version, and
Layer 2 service version are separate values. Conflating them would make upgrades
unnecessarily coupled.

#### 4.3.6 Per-client global filtering

Privileged and optional globals cannot simply be advertised to every client.
Because a Wayland global-filter callback is synchronous, Layer 2 publishes an
immutable access-policy snapshot to Layer 1 at safe points. Protocol modules
label globals with access classes, and the native host evaluates the frozen
snapshot during registry advertisement/bind.

Layer 1 defaults security-sensitive globals to hidden until a policy snapshot
explicitly permits them. The access-policy snapshot contains only native-matchable
client labels and decisions; arbitrary Lisp is never called from the filter.

#### 4.3.7 Module failure containment

Each module has separate accounting for:

- live native wrappers;
- tombstones;
- pending critical events;
- coalescible events;
- payload/blob bytes;
- retained buffers and file descriptors;
- pending commands.

One module exhausting diagnostic or motion capacity must not block lifecycle
events from another module. A module that cannot preserve a protocol-critical
event must disconnect the responsible client or fail the operation explicitly;
it must not silently desynchronize Layer 2 from native state.

Linked native modules share an address space, so this design contains logical
and resource failures, not arbitrary memory corruption. Native memory safety
still depends on review, sanitizers, and eventually a stable narrow ABI if
out-of-process protocol helpers are desired.

#### 4.3.8 When a protocol requires a host extension

Most protocol additions are pure horizontal modules. A protocol requires a host
extension only when it introduces a new cross-cutting native lifetime primitive.

Examples:

- a metadata/hint protocol needs only a protocol module;
- XDG decoration needs the core-surface and XDG-shell modules, not a host change;
- layer shell needs output and core-surface handles, not a host change;
- DMA-BUF required the host’s buffer/FD lease primitives;
- explicit synchronization required timeline/fence leases;
- DRM lease requires ownership of a new DRM lease primitive;
- capture requires a renderer/capture completion bridge.

When this happens, extend the generic host mechanism first and version it. Do not
smuggle a raw native pointer through a protocol-specific payload.

#### 4.3.9 Example: XDG toplevel

1. The XDG native module creates the global and registers wlroots listeners.
2. A client creates a toplevel. The module allocates XDG-role handles related to
   the core surface and emits `toplevel-created`.
3. The Layer 2 XDG adapter creates or updates a view and asks shell/placement
   services for initial policy.
4. Layer 2 submits `configure-toplevel` with size and state suggestions.
5. The native module validates the handle, sends the configure, and completes
   with its serial.
6. The client acknowledges and commits. Layer 1 emits distinct ack and applied
   commit events.
7. Layer 2 correlates the serial, publishes the view mutation, and schedules
   presentation.
8. A client move or resize request arrives as a policy request containing the
   seat, serial, and edge—not as an automatically executed native operation.
9. The Layer 2 shell service owns the interactive operation and sends only seat
   delivery/configure commands back through Layer 1.

#### 4.3.10 Example: fractional scale

1. The native module associates a fractional-scale object with a surface and
   emits lifecycle changes.
2. Layer 2 computes preferred scale from the surface’s current presentation
   across output viewports.
3. Layer 2 submits a preferred-scale command.
4. Layer 1 emits the protocol event and reports completion.

No world coordinate or output arrangement policy exists in the native module.

#### 4.3.11 Example: session lock

1. The native module receives a lock request and immediately enters a protected
   pending state that cannot show another unlocked frame.
2. It emits a lock policy request.
3. Layer 2 security policy accepts or rejects it.
4. Layer 1 completes the native handshake and enforces blanking/input isolation.
5. Lock-surface lifecycle is translated like other surfaces; Layer 2 decides
   output assignment and presentation.
6. If Layer 2 fails, the native module remains fail-closed.

This is horizontally modular even though it uses the host’s security-emergency
mechanism.

#### 4.3.12 Example: capture

1. The capture native module validates the client request and target buffer
   mechanics, then emits a capture policy request.
2. Layer 2 authorizes it and asks the current capture service for a frame tied to
   a presentation revision.
3. The current renderer performs readback or copy into a capture lease.
4. Layer 2 submits success/damage/timestamp metadata to the native module.
5. Layer 1 copies or releases native buffers and emits the protocol completion.

The capture module never reaches into renderer internals, and the renderer never
marshals Wayland protocol events.

### 4.4 Object identity and lifetime

Every native object exposed to Lisp has:

- a 64-bit monotonic handle;
- a native kind;
- a generation or terminal retirement state;
- immutable creation metadata;
- explicit parent and related handles where applicable.

No public API exposes a wlroots pointer. Handles are never reused within a
server lifetime. Destruction is idempotent. A command on a retired handle returns
`stale`, not undefined behavior.

Buffer, frame-target, and file-descriptor objects use explicit leases. A lease
documents who owns the native reference and which operation releases it.

### 4.5 Incoming event contract

Every event contains a common prefix:

- ABI size and version;
- monotonically increasing sequence;
- monotonic timestamp;
- event kind;
- subject handle and subject kind;
- related and parent handles;
- flags describing coalescing, urgency, and required response;
- bounded typed payload.

Event classes have different loss rules:

| Class | Examples | Queue rule |
|---|---|---|
| Lifecycle | create, map, unmap, destroy | never coalesce or drop |
| Protocol transaction | commit, configure ack, selection, lock | never drop |
| Discrete input | key, button, touch down/up | never coalesce or drop |
| Continuous input | pointer motion, axis, tablet motion | may coalesce only within a protocol frame and device |
| Frame scheduling | output frame deadline | retain latest pending event per output |
| Diagnostics | trace and performance samples | bounded and droppable |

A single full diagnostic queue must never poison the compositor. Critical and
coalescible traffic need separate capacity or reserved capacity.

### 4.6 Outgoing command contract

Commands are typed, bounded, and versioned. Every command contains:

- command identity and optional correlation identity;
- target handle and expected kind;
- required protocol state or generation;
- typed payload;
- ownership rules for arrays, buffers, strings, and file descriptors.

Commands return a completion value:

- `ok` with result data;
- `stale`;
- `wrong-kind`;
- `invalid-state`;
- `unsupported`;
- `retry` for a legal operation that is not ready yet;
- `protocol-rejected`;
- `native-failure` with structured context.

Layer 2 must never infer success from enqueueing a command.

### 4.7 Required synchronous mechanisms

The following remain native because deferring them is unsafe:

- locking a surface buffer during a commit callback;
- copying transient configure, input, and presentation payloads;
- duplicating or closing transferred file descriptors;
- maintaining wlroots listeners and removing them before freeing wrappers;
- validating role and serial state at command execution;
- retaining buffers until output release;
- importing/exporting synchronization primitives;
- blanking outputs during an unresolved secure lock transition;
- posting mandatory protocol errors.

These mechanisms produce events and completions so Layer 2 remains authoritative
over policy.

## 5. Rendering and DRM Boundary

### 5.1 Renderer ownership decision

Three approaches are technically possible:

| Approach | Boundary quality | Practicality | Decision |
|---|---|---|---|
| Use the wlroots renderer and scene APIs | Couples rendering vocabulary to wlroots and integer 2D assumptions | Easiest | Reject as the framework renderer |
| Call raw EGL/GLES functions individually from Lisp | Keeps algorithms in Lisp but creates excessive FFI/lifetime risk in inner loops | Viable for experiments | Do not use as the primary executor |
| Layer 2 renderer compiles batched commands; a small graphics device module executes them against Layer 1 frame targets | Preserves replaceable algorithms and native lifetime safety | Practical and performant | Recommended |

The recommended renderer is a Layer 2 plugin even if its low-level GPU executor
is implemented in C. Conceptual ownership follows responsibility, not language:
the renderer plugin owns shader programs and draw semantics; the wlroots bridge
does not know what a window, shadow, sphere, cursor, or animation is.

### 5.2 No wlroots scene dependency

The core architecture must not depend on `wlr_scene`. A conventional planar
plugin may later use it as an optional optimized executor, but the common render
and hit-test contracts cannot use its geometry as their source of truth.

### 5.3 Renderer-null wlroots compositor

To keep wlroots out of rendering policy, the preferred native configuration is:

- create the wlroots compositor with no `wlr_renderer`;
- explicitly advertise supported SHM formats;
- advertise Linux DMA-BUF only after import capability is known;
- capture committed buffers during surface commit callbacks;
- give Layer 2 immutable surface-buffer snapshots through leases.

This is more work than `wlr_renderer_autocreate`, but it creates the intended
boundary. It also means the bridge must not call `wlr_surface_get_texture`.

### 5.4 Graphics device service

The Layer 2 graphics device protocol owns:

- selection policy among the render devices and capabilities reported by Layer 1;
- shader compilation and program caches;
- DMA-BUF and SHM texture import;
- source color interpretation;
- offscreen targets;
- mesh/quad/rect execution;
- blending, clipping, effects, and readback;
- GPU completion fences.

The native platform side owns:

- the borrowed DRM file descriptor and backend lifetime;
- GBM/EGL display and context creation, current-thread binding, and lifetime;
- scanout-compatible allocation contract;
- output swapchain ownership;
- frame-target acquisition and release;
- KMS/output test and commit;
- presentation completion.

Layer 2 may choose a device but may not create a second unsynchronized platform
context behind Layer 1. The exact EGL context may be made current only inside an
owner-thread context lease. It is not stored in arbitrary plugin objects or used
from control threads.

### 5.5 Frame transaction

A frame is a transaction with explicit phases:

1. Layer 2 requests a target for an output and desired output state.
2. Layer 1 negotiates a compatible scanout format/modifier and returns an opaque
   frame target plus buffer age and capabilities.
3. Layer 2 freezes one presentation snapshot.
4. The renderer compiles and validates a render plan.
5. The GPU executor records and executes the plan into the target.
6. Layer 2 supplies damage and sampled surface leases.
7. Layer 1 waits on or imports acquire fences, tests output state, and commits.
8. Layer 1 emits commit and later presentation/release completions.
9. Layer 2 sends frame-done and presentation feedback only for surfaces actually
   sampled by the successfully presented frame.
10. All leases are released on submit, cancellation, output loss, or shutdown.

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
- Render commands and mesh data cross FFI in bounded batches.
- A frame owns one foreign arena; cancellation frees the arena in one operation.
- Shader/program state is cached by immutable descriptor.
- Damage history is per output buffer, not just per output.
- Direct scanout is an optional proposal checked by Layer 1, never assumed.
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
- event ingestion and safe points;
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

1. dispatch Layer 1 for a bounded interval;
2. drain and copy native events;
3. update native-resource mirrors;
4. translate protocol facts into framework events;
5. invoke policy services and hooks;
6. drain agent/control commands;
7. advance active clocks and animation graphs;
8. freeze requested presentation snapshots;
9. build, render, and submit frames;
10. publish observations and retire dead objects.

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

One Layer 2 adapter per protocol family converts Layer 1 protocol events into
semantic framework operations. Adapters contain policy-facing translation, not
native storage.

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
- sampled surface-buffer leases;
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

Protocol delivery is a seat-sink service. The router does not call wlroots
directly.

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

Layer 2 builds a desired multi-output transaction. Layer 1 tests and commits it.
Layer 2 must handle failure and select a fallback; Layer 1 must not silently pick
a desktop arrangement.

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
- bounded object registries, queues, payloads, and per-client resources;
- privileged protocol filtering by client principal.

Support for a protocol does not mean merely advertising its global. Each family
needs lifecycle, request, command, failure, teardown, and real-client evidence.

## 10. Package and Module Plan

The repository should enforce boundaries through separate ASDF systems.

### 10.1 Layer 1 systems

- `ataxia.native.abi`: CFFI declarations for the public native ABI only;
- `ataxia.native.runtime`: library loading, server lifecycle, event copies;
- `ataxia.native.protocol.*`: typed convenience wrappers grouped by protocol;
- native `libataxia-platform`: event loop, registries, protocol modules, buffers,
  EGL/GBM platform, and output transactions;
- native headers contain no wlroots types.

Layer 2 systems must not import private native packages or CFFI symbols.

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

- `ataxia.protocol-adapters.*`;
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
- direct-EGL graphics executor;
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
3. stop protocol policy adapters;
4. release presentation snapshots and buffer leases;
5. cancel frame transactions;
6. retire framework resources;
7. destroy protocol globals and native wrappers;
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
- command encoding and GPU submission;
- observation diffs for active agents.

### 12.2 Required techniques

- bounded native queues with class-aware coalescing;
- reusable event and foreign-memory arenas;
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

- event enqueue-to-policy latency under high-rate pointer motion;
- frame build, render, and commit time separately;
- allocation volume per idle and animated frame;
- dropped/coalesced event counts;
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
- freeze Layer 1 event/command ownership rules;
- freeze coordinate, buffer, and frame transaction contracts;
- define dependency rules enforced by ASDF/package boundaries.

Evidence:

- written architecture decisions;
- no implementation begins before approval.

### Milestone 1: Native lifecycle

Deliverables:

- headless Wayland display and backend;
- socket creation;
- output/input discovery events;
- opaque handles and bounded queue;
- clean stop and stale-handle behavior.

Evidence:

- headless process starts, reports devices, dispatches, and stops cleanly;
- public header contains no wlroots types.

### Milestone 2: Surface-to-pixel vertical slice

Deliverables:

- core surface/subsurface and XDG toplevel events;
- surface-buffer snapshots;
- direct-EGL frame target;
- one Layer 2 planar renderer;
- frame done and presentation completion.

Evidence:

- a real SHM XDG client maps and presents correctly;
- orientation, channels, scale, and transform are verified;
- no wlroots renderer/scene dependency in the generic path.

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

- One C/Lisp module that binds arbitrary wlroots structs and lets framework code
  access their slots.
- Lisp callbacks directly invoked from wlroots signals.
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

1. **Graphics execution**: approve the recommended batched direct-EGL renderer
   plugin, rather than raw per-call Lisp GL or the wlroots renderer.
2. **Native ABI policy**: choose whether ABI compatibility is maintained across
   every development milestone or begins after the first usable vertical slice.
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

No implementation should begin until these decisions and the corrected Layer 1
graphics/lifetime responsibility are approved.

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
