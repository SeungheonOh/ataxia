# Compositor Object Graph Design

## 1. Decision

Ataxia has one Common Lisp `compositor` object that is the aggregate root of the
running compositor. It directly owns a small set of cohesive domain subsystems
and reaches live compositor objects through their owning subsystem. It also owns
the compositor lifecycle and owner-thread execution context.

The previous independent policy-kernel/service/transaction design is removed.
There is no internal actor system, service scope, component-schema registry,
generic event bus, immutable entity-component store, or mailbox between
compositor components.

Components communicate synchronously through ordinary functions and CLOS generic
functions on the compositor owner thread. The compositor mediates operations
that cross several component boundaries. Hooks remain available for optional
extensions, but required compositor behavior never depends on a hook broadcast.

The direct wlroots Common Lisp packages remain below the compositor object graph.
They expose exact typed callbacks and functions; they do not contain compositor
policy.

## 2. Core Rules

1. Exactly one owner thread mutates compositor state.
2. The `compositor` object directly owns only stable domain boundaries, not every
   manager, registry, policy, or execution detail.
3. Subsystems and their nested components call each other directly; they do not
   exchange internal messages.
4. Cross-domain invariants are coordinated by methods specialized on
   `compositor`.
5. State is ordinary owner-thread CLOS state, not an immutable component store.
6. Native and protocol atomicity is modeled only where the real API requires it.
7. Replaceability comes from explicit operations on declared strategies, not
   public slot writers or runtime service discovery.
8. Hooks are synchronous extension points with declared semantics and budgets.
9. A mailbox exists only for commands crossing into the owner thread from an
   agent, worker, process supervisor, or external control connection.
10. wlroots pointers remain inside typed native wrapper objects.

## 3. Object Graph

```mermaid
flowchart TD
    WLR[Direct wlroots Lisp packages] --> C[compositor]
    EXT[External agents and workers] --> CONTROL[control]
    CONTROL --> INBOX[Owned external inbox]
    INBOX --> C

    C --> RUNTIME[runtime]
    C --> OUT[outputs]
    C --> SURF[surfaces]
    C --> DESKTOP[desktop]
    C --> INTERACTION[interaction]
    C --> WORLD[world]
    C --> PRESENT[presentation]
    C --> GRAPHICS[graphics]
    C --> EXTENSIONS[extensions]
    C --> CONTROL

    RUNTIME --> SAFE[callback barrier and safe points]
    DESKTOP --> DV[applications, views, shell roles]
    INTERACTION --> IS[devices, seats, focus, cursors, grabs]
    PRESENT --> ANIM[animation engine]
    EXTENSIONS --> HOOKS[hook registry]

    INTERACTION --> WORLD
    DESKTOP --> WORLD
    DESKTOP --> INTERACTION
    PRESENT --> WORLD
    PRESENT --> ANIM
    PRESENT --> GRAPHICS
    OUT --> PRESENT
```

The arrows between components are direct method calls. They are not queues,
serialized events, or dynamically resolved service keys.

The compositor does not promote every manager or registry into a root service.
The interaction subsystem owns logical seats, per-seat focus/cursor/grab state,
device assignment, and routing. The desktop subsystem owns shell policy,
applications, and views. The runtime owns callback/safe-point bookkeeping, the
presentation subsystem owns animation, and control owns the external inbox.

## 4. Core CLOS Structure

### 4.1 Compositor aggregate

The initial shape is explicit:

```lisp
(defclass compositor ()
  ((runtime      :initarg :runtime      :reader compositor-runtime)
   (outputs      :initarg :outputs      :reader compositor-outputs)
   (surfaces     :initarg :surfaces     :reader compositor-surfaces)
   (desktop      :initarg :desktop      :reader compositor-desktop)
   (interaction  :initarg :interaction  :reader compositor-interaction)
   (world        :initarg :world        :reader compositor-world)
   (presentation :initarg :presentation :reader compositor-presentation)
   (graphics     :initarg :graphics     :reader compositor-graphics)
   (extensions   :initarg :extensions   :reader compositor-extensions)
   (control      :initarg :control      :reader compositor-control)
   (state        :initform :constructing :reader compositor-state)))
```

Public component access is read-only. Construction code installs the initial
subsystems, lifecycle methods change `state`, and explicit safe-point operations
such as `replace-world` or `replace-presentation-policy` perform supported live
replacement. The design does not expose general `(setf compositor-...)` writers.
Because subsystems retain the aggregate reference, bootstrap allocates the root
first and uses a private construction-only installer before validation; public
code never observes unbound subsystem slots.

There is no keyword service lookup on input or rendering hot paths.

### 4.2 Domain ownership and boundary rationale

| Root slot | Owned state | Why it remains a root boundary |
|---|---|---|
| `runtime` | Native runtime wrapper, event-loop integration, callback barrier, callback depth, typed safe-point actions | Native lifetime and reentrancy rules must remain below desktop policy |
| `outputs` | Physical/virtual outputs, modes, viewports, damage history, frame scheduling, native output commits | Output protocol/hardware lifetime is independent of drawing implementation |
| `surfaces` | Raw surfaces, subsurfaces, commits, retained buffers, surface destruction | Surfaces exist without applications or desktop views |
| `desktop` | Shell-role policy, applications, views, popup/layer/lock relationships | This is the Wayland desktop/application interpretation boundary |
| `interaction` | Devices, logical seats, routing, per-seat focus, cursors, grabs, interactive operations | These states share serials and termination invariants and must change together |
| `world` | Placements, projection, unprojection, spatial index, hit testing | It is the replaceable spatial-model boundary shared by input and presentation |
| `presentation` | Frame snapshots, visibility, composition order, animation engine, presentation damage | It converts compositor meaning into renderable state without issuing GPU calls |
| `graphics` | Direct EGL/GLES context, resources, shaders, render graphs, submission | GPU lifetime, recovery, and execution are separate from scene meaning and outputs |
| `extensions` | Typed hooks, ordering, budgets, local plugin registrations | Optional in-process extension dispatch must not become core communication |
| `control` | Principals, capabilities, observations, trusted shell/RPC, bounded external inbox | This is the only trust/thread crossing into owner-thread policy |
| `state` | Constructing/running/quiescing/stopped/failed lifecycle | The aggregate itself, rather than any one subsystem, owns global lifecycle |

Nested objects remain ordinary CLOS objects and may expose their own strategies.
Nesting changes ownership, not call performance: peer subsystems still use direct
typed calls, fetched once before hot loops.

### 4.3 Component base

```lisp
(defclass compositor-component ()
  ((compositor :initarg :compositor
               :reader component-compositor)
   (state      :initform :detached
               :accessor component-state)))

(defgeneric attach-component (component))
(defgeneric detach-component (component reason))
(defgeneric validate-component (component compositor))
```

Every component can reach the aggregate root. Components expose domain-specific
generic functions; `compositor-component` does not define a generic event or
message method.

### 4.4 Live compositor objects

Core live objects are normal CLOS instances with direct slots and relationships:

- `application`: process/client identity, security context, and owned views;
- `view`: shell role, application, placement, animation policy, decoration, and
  current model/presentation state;
- `surface-binding`: typed native surface wrapper and its role-specific owner;
- `output`: typed native output wrapper, viewport, render state, and damage;
- `seat`: typed native seat wrapper, assigned devices, focus, grabs, and cursor;
- `world-placement`: implementation-defined placement owned by the selected
  world object;
- `interactive-operation`: move/resize/gesture state with initiating seat and
  serial provenance;
- `animation-definition` and `animation-instance`;
- `frame-context`: one output frame's short-lived presentation and native state.

Frequently accessed state uses explicit slots. An optional property table may
exist for low-frequency extension metadata, but core placement, focus, rendering,
animation, and native lifetime state cannot be hidden in an untyped property map.

### 4.5 Identity and native provenance

Compositor objects have Lisp identity independent of native wrapper identity.
A view can outlive one role-specific wrapper transition, and one application can
own several views and native surfaces.

Native wrappers are stored directly in the owning compositor object. The
authoritative native destroy callback clears or invalidates the wrapper and then
invokes the owning component's exact destruction method.

## 5. Component Communication

### 5.1 Direct calls

Normal communication is a synchronous call with direct arguments and return
values:

```lisp
(defmethod handle-pointer-motion ((interaction interaction-system) event)
  (let* ((compositor (component-compositor interaction))
         (world (compositor-world compositor))
         (seat (event-logical-seat interaction event)))
    (multiple-value-bind (target surface-x surface-y)
        (world-hit-test world event)
      (update-seat-pointer-target
       interaction seat target surface-x surface-y))))
```

The called component owns its slots. A caller uses its public generic functions
instead of mutating peer slots directly.

### 5.2 Compositor-mediated operations

An operation that changes several components is a method on `compositor`:

```lisp
(defgeneric begin-interactive-move
    (compositor seat view serial pointer-position))
```

Its implementation validates the view through desktop and the seat/serial
through interaction, establishes the grab and per-seat focus/cursor state,
creates the interactive operation, asks presentation to resolve its animation,
and requests a frame. The ordering is visible in one method rather than
distributed across messages.

Use compositor-mediated methods when:

- more than one component invariant changes;
- failure requires coordinated cleanup;
- security authorization precedes several effects;
- a public shell or agent action must behave identically to local input;
- component replacement must not expose an intermediate state.

### 5.3 Direct peer references

Subsystems resolve root peers through compositor readers. Nested components
resolve peers through their owning subsystem. A hot method fetches the peer once
into a lexical variable before its loop.

A component may store a direct peer reference when the peer is guaranteed stable
for the component's entire attached lifetime. The compositor wiring code owns
that reference and must update it before either component becomes callable.

Arbitrary components must not cache replaceable peers. This prevents a hot swap
from leaving stale references without introducing service generations.

### 5.4 Hooks

Hooks are for optional policy, instrumentation, and plugins:

```lisp
(run-hook (extension-hooks (compositor-extensions compositor))
          hook-context)
```

A required focus update never asks a hook to notify another component. The
interaction or compositor method updates the seat's focus and cursor state
directly, then optionally emits an observation hook.

### 5.5 No internal mailbox

The following are forbidden between compositor components:

- mailbox sends;
- generic command envelopes;
- serialized event records used only to cross an internal boundary;
- promise/future completion for an operation that is already on the owner
  thread;
- publish/subscribe as the only way to maintain a core invariant.

## 6. Owner Thread and Runtime Turns

### 6.1 Callback entry

Each direct wlroots package installs a protocol-specific sink object. The sink
is the compositor, exact owning subsystem, or exact owning nested component. A
callback invokes a typed generic function synchronously:

```mermaid
sequenceDiagram
    participant W as wlroots
    participant B as Typed Lisp binding
    participant C as compositor
    participant D as desktop
    participant I as interaction
    participant P as presentation

    W->>B: request_move(toplevel, seat, serial)
    B->>D: xdg-request-move(desktop, request)
    D->>C: begin-interactive-move(view, seat, serial)
    C->>I: validate serial; focus; establish grab/cursor
    C->>P: begin-transition(view, descriptor)
    C-->>D: handled/rejected
    D-->>B: handled/rejected
    B-->>W: return from listener
```

No intermediate queue or framework transaction is created.

### 6.2 Callback depth

The runtime's callback barrier tracks callback depth because some native
destruction or listener mutation is unsafe from inside the active callback.
Outermost callback exit is a safe point for the small set of explicitly deferred
actions.

The deferred-action list is not a mailbox or event bus. It is owner-thread-only,
contains typed closures or typed cleanup objects, and is limited to operations
whose exact lifetime contract requires deferral.

### 6.3 External ingress

Threads outside the owner thread submit typed control requests to the control
subsystem's one bounded external inbox. The runtime owns the corresponding
Wayland event-loop wake source. The owner thread drains requests between native
dispatch turns and invokes the same compositor methods used by local input.

After ingress, no further mailbox hop occurs.

Long-running agent inference, image processing, or blocking I/O must run outside
the owner thread. Its result re-enters through the external inbox as a bounded,
validated typed request.

### 6.4 Reentrancy

Component code must not re-enter the Wayland event loop. Public compositor
operations declare whether they are callback-safe, safe-point-only, or startup/
shutdown-only. A method that could synchronously trigger another wlroots callback
must leave its owning objects in a valid intermediate state first.

## 7. State Changes Without a General Transaction System

### 7.1 Direct owner-thread mutation

Ordinary state changes mutate their owning objects directly. The orchestrating
method validates first, applies changes in declared order, performs exact native
calls, and then runs observation hooks.

There is no universal mutation descriptor, write set, revision conflict check,
effect queue, or rollback engine.

### 7.2 Specialized pending state

Real asynchronous protocols still require explicit state objects:

- XDG configure serial and acknowledgement state;
- output test/commit and page-flip state;
- presentation feedback waiting for a committed frame;
- clipboard/DND transfer and owned FD state;
- session-lock acquisition and per-output presentation state;
- capture request and buffer completion state;
- interactive move/resize state;
- animation instances sampled across frames.

These objects are owned by the relevant component and model the actual protocol.
They are not instances of a general compositor transaction class.

### 7.3 Operation ordering

Cross-component methods follow this pattern where applicable:

1. validate arguments, object liveness, serials, permissions, and capabilities;
2. prepare any native or protocol-specific temporary state;
3. update the smallest set of owning Lisp objects;
4. call exact native functions in their required order;
5. repair or retire local state if an honest native failure occurs;
6. schedule presentation;
7. invoke non-veto observation hooks.

Veto hooks, when a hook point permits them, run before step 3 and cannot perform
untracked native mutations.

### 7.4 No false rollback

Wayland messages already sent, accepted FDs, DRM commits, and client-visible
globals cannot be rolled back by Lisp. Every operation documents its real failure
boundary. Cleanup restores internal consistency without pretending external
effects were atomic.

## 8. Construction and Lifecycle

### 8.1 Bootstrap order

1. create the native runtime and event loop;
2. allocate the compositor aggregate in `:constructing` state;
3. construct the ten domain subsystems with a reference to the compositor;
4. construct their nested managers, policies, registries, and strategies;
5. wire stable peer dependencies and validate every required subsystem;
6. create native globals/managers with their initial exact sinks;
7. attach components in dependency order;
8. start the backend;
9. mark the compositor `:running`.

Failure unwinds in reverse order through exact detach and native destroy/finish
operations.

### 8.2 Native object creation

The owning component directly calls the exact native package constructor. For a
new logical seat:

1. the interaction subsystem validates the requested identity and policy;
2. it calls `seat-create` with the active exact seat sink;
3. the native package returns a live typed wrapper after listeners are installed;
4. interaction constructs the Lisp seat, including per-seat focus/cursor/grab
   state, and assigns devices;
5. the compositor makes it visible to desktop, outputs, and control operations.

If Lisp object publication fails after native construction, the owner schedules
the exact destructor at the outermost safe point.

### 8.3 Component replacement

Replacement is explicit and uncommon:

1. enter an owner-thread safe point with no active callback;
2. construct and validate the candidate component;
3. ask dependent components whether live-state migration is supported;
4. reject replacement if native resources or in-flight frames cannot migrate;
5. detach the old component from new calls;
6. replace the declared strategy through its explicit root/subsystem operation
   and rewire declared direct references;
7. attach the candidate;
8. migrate or rebuild owned state;
9. destroy the old component after no retained frame/native callback uses it.

Root-subsystem replacement is not implied merely because it has a slot. A GLES
graphics subsystem may require controlled renderer recovery rather than live
replacement. A world may require every placement to implement an explicit
conversion. There is no service scope, generation lookup, or automatic
migration; refusal is preferable to corrupt state.

### 8.4 Shutdown

Shutdown stops new external requests, cancels interactive operations and
transfers, completes or discards frames, clears focus/grabs, detaches components
in reverse dependency order, destroys protocol managers and native objects, stops
the backend, and finally destroys the display/runtime.

## 9. Hook System

Hooks dispatch on typed hook context objects rather than arbitrary event names:

```lisp
(defclass hook-context ()
  ((compositor :initarg :compositor :reader hook-compositor)
   (subject    :initarg :subject :reader hook-subject)
   (operation  :initarg :operation :reader hook-operation)
   (phase      :initarg :phase :reader hook-phase)
   (provenance :initarg :provenance :reader hook-provenance)))
```

Hook handlers may specialize on context, subject, operation descriptor, and
phase. This keeps the system general without hard-coding animation-specific
keywords such as map, pickup, or drop into the core.

Each hook point declares one of:

- `observe`: cannot alter the operation;
- `veto`: may reject before mutation;
- `transform`: may return a validated replacement descriptor;
- `around`: reserved for explicitly reentrant-safe control operations.

Hook order is deterministic. Hot-path hooks are bounded and synchronous. Slow
observers receive copied observations through the external control boundary
rather than blocking the compositor thread.

## 10. World, Coordinates, and Presentation

The compositor holds one active `world` strategy object. Views hold placement
objects understood by that world. Required generics include:

```lisp
(world-place-view world view placement-request)
(world-update-placement world view placement operation-context)
(world-project world output viewport view timestamp)
(world-unproject world output viewport output-x output-y)
(world-hit-test world output viewport output-x output-y timestamp)
```

A planar fixed workspace, infinite canvas, or spherical world replaces the world
object and placement classes. Input and rendering both call the same world
object, ensuring projected geometry and inverse hit testing agree.

The presentation subsystem asks the world for projected items, samples its
nested animation engine, adds output-local overlays, builds a short-lived
presentation snapshot, and calls graphics directly.

## 11. Rendering

The graphics subsystem owns the active direct GLES renderer, whose execution
strategy has explicit methods:

```lisp
(renderer-begin-frame renderer output frame-context)
(renderer-draw-item renderer frame-context presentation-item)
(renderer-end-frame renderer frame-context)
(renderer-abort-frame renderer frame-context reason)
```

The target renderer uses direct EGL/GLES from Common Lisp with wlroots
allocator, buffer, output, and presentation interoperability. A wlroots
render-pass or software renderer may exist only as a diagnostic/fallback
profile and does not define the common graphics contract. The compositor core
does not depend on `wlr_scene`.

Shader programs, effect graphs, hot replacement, damage, hit mapping, and
trusted local agent control are specified in
[Direct GLES and Shader Animation Design](GLES-SHADER-ANIMATION-DESIGN.md).

Frame execution is direct:

1. the exact output frame callback enters the outputs subsystem;
2. it calls presentation;
3. presentation freezes output/world/animation state for that frame;
4. graphics builds and submits exact native render/output state;
5. outputs records the real commit result;
6. later presentation/page-flip callbacks complete the frame context.

The snapshot exists to keep one frame internally coherent, not to implement a
global immutable state model.

## 12. Input, Focus, Cursor, and Interactive Operations

The interaction subsystem performs device normalization and routing, then
directly calls:

1. active grab/interactive operation;
2. world inverse mapping and hit testing;
3. per-seat focus transition;
4. per-seat cursor transition;
5. shared shortcut/accessibility policy;
6. exact seat delivery functions.

Focus, cursor, grabs, and active operations are owned together by interaction
because their serial and termination rules are coupled. Each logical seat owns
its own focus and cursor state. Cursor appearance derives from that seat's
current operation and pointer target; it is not independently latched by a
global cursor manager or scattered event handlers.

An `interactive-operation` directly stores its seat, target view, initiating
serial, starting pointer/placement, mode, constraints, and cancellation rule.
Button release, view destruction, device removal, seat removal, focus loss, or
explicit cancellation terminates it through one compositor method.

## 13. Animation

Animation is direct object state, fully selectable per subject and per operation.

```lisp
(defclass view ()
  ((animation-policy :accessor view-animation-policy)
   (animations       :reader view-active-animations)))
```

The animation engine is owned by presentation rather than exposed as another
root service. Resolution receives a general transition descriptor:

```lisp
(resolve-animation animation-engine subject transition-descriptor context)
```

Resolution order is:

1. explicit operation override;
2. subject-specific animation policy;
3. application/profile policy;
4. world or shell policy;
5. compositor default.

Two windows can therefore use different definitions for the same transition.
Definitions may use different timelines, curves, springs, properties, blending,
interruption rules, and completion behavior.

Definitions may also attach different GLES programs, effect stacks, multipass
graphs, meshes, texture inputs, and typed uniform bindings per view. Trusted
local agents and the Lisp shell may prepare and replace those definitions using
candidate-before-activation semantics without restarting the compositor.

Animation sampling is an internal direct call within presentation. It does not
publish animation messages. Starting, retargeting, cancelling, and completing an
animation may invoke typed hooks, but the engine owns the active instances.

## 14. Output and Frame Coordination

The outputs subsystem owns physical and virtual output objects. Each output owns its
viewport, current native state, damage history, frame scheduling state, cursor/
layer resources, and outstanding frame contexts.

Output arrangement is policy in the outputs/world relationship. Rendering uses
output-local top-left logical coordinates. Buffer transforms, output transforms,
scale, and backend projection are applied exactly once according to the renderer
contract.

Direct scanout is proposed by presentation/graphics and tested through the exact
native output API. Capture, software cursor, animation, effects, color conversion,
or world projection may veto it.

## 15. Agentic Control

Control exposes typed compositor operations, not unrestricted slot mutation. It
owns principal/capability policy, observations, and the only external inbox. A
request contains principal, provenance, authority, target, expected state where
needed, and an action-specific payload.

External requests cross the owner-thread inbox once:

```mermaid
sequenceDiagram
    participant A as Agent thread
    participant CTRL as control and owned inbox
    participant C as compositor
    participant S as owning domain subsystem
    participant H as extensions/hooks

    A->>CTRL: typed request with principal
    CTRL->>C: drain on owner thread
    C->>C: authorize and validate
    C->>S: direct domain operation
    S-->>C: direct result
    C->>H: observation hook
    C-->>CTRL: typed result
    CTRL-->>A: completion
```

Local Lisp shell code already running on the owner thread may call the same
methods directly. Off-thread REPL/control code must use the inbox.

Observations are bounded snapshots created explicitly by owning components.
Secrets, clipboard contents, keystrokes, and client buffers require separate
capabilities and redaction policy.

## 16. Package Structure

Suggested Common Lisp systems:

- `ataxia.wlr.*`: direct typed wlroots/libwayland packages;
- `ataxia.compositor`: aggregate and direct orchestration;
- `ataxia.runtime`: callback barrier, safe points, runtime turns, shutdown;
- `ataxia.output`;
- `ataxia.surface`;
- `ataxia.desktop`, with shell/application/view policy packages;
- `ataxia.interaction`, with input/seat/focus/cursor/grab packages;
- `ataxia.world`;
- `ataxia.presentation`;
- `ataxia.animation`, owned at runtime by presentation;
- `ataxia.graphics.gles`;
- `ataxia.extensions`, including typed hooks;
- `ataxia.control`, including observations and the external inbox;
- profile packages that construct and wire concrete component objects.

Domain packages may depend on shared value/object packages and public typed
native packages. They must not form accidental circular ASDF dependencies merely
because runtime objects call each other. Shared generic protocols belong in the
package that owns the operation or in a narrow protocol package.

## 17. Performance Rules

1. No internal mailbox, serialization, promise, or generic event allocation.
2. No service-key hash lookup on input, animation, hit-test, or render paths.
3. Fetch root subsystems and replaceable nested strategies once before tight
   loops.
4. Use specialized arrays/structs for presentation items and draw commands.
5. Reuse frame, damage, input-route, and animation scratch storage.
6. Keep CLOS dispatch outside per-pixel and other extremely fine-grained loops.
7. Type-declare numeric coordinate, matrix, timestamp, and buffer-index paths.
8. Bound every registry, hook list, external inbox, frame list, and observation.
9. Do not block, perform agent inference, or wait on I/O on the owner thread.
10. Measure callback latency, input-to-presentation latency, frame allocation,
    GC pauses, animation cost, and native-call overhead.

SBCL can optimize stable generic-function call sites effectively. The dominant
cost should remain scene preparation, GPU work, buffer synchronization, and
client/backend behavior—not component communication.

## 18. Invariants

1. One compositor object is the root of all compositor-owned state.
2. Only the owner thread mutates that state.
3. Components communicate through direct typed calls.
4. Required behavior never depends on internal publish/subscribe delivery.
5. The control-owned external inbox is the only mailbox in the compositor
   architecture.
6. Subsystems/components mutate only their own slots unless an explicit compositor method
   coordinates a cross-component operation.
7. Every native callback targets the compositor or an exact owning component.
8. Every native object has one typed owner and exact lifetime operation.
9. Client/backend-originated objects are never misclassified as compositor-
   originated objects.
10. Render projection and input inverse mapping use the same world object.
11. Focus, cursor, grab, and operation state are owned per seat inside
    interaction.
12. Presentation owns animation, whose policy can vary per object and per
    transition descriptor.
13. Direct Common Lisp EGL/GLES is the target renderer.
14. Trusted local agents may replace shader and effect definitions only through
    candidate-before-activation and owner-thread safe-point adoption.
15. Hooks are typed, ordered, bounded, and never the core communication path.
16. Strategy or supported subsystem replacement uses an explicit operation,
    happens only at a safe point, and may be rejected.
17. No general transaction, entity-component, or service-generation framework is
    reintroduced under another name.

## 19. Decisions Before Implementation

1. Choose the initial concrete subsystem classes, nested strategies, and
   constructor wiring order.
2. Choose the exact pinned wlroots release and SBCL support baseline.
3. Define the callback-safe/safe-point/startup-only native function table.
4. Select the first world and presentation implementations and the exact
   GLES/EGL capability baseline for the direct renderer.
5. Choose the control inbox/runtime wake primitive pair.
6. Define which component replacements the first implementation supports live.
7. Define the first typed hook contexts and budgets.
8. Define the first control principals, capabilities, and observation redactions.

No compositor implementation begins until this aggregate-root design and the
direct component boundaries are approved.
