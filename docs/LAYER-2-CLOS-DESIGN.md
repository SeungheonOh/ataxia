# Layer 2 CLOS System Design

Status: architecture planning only. Class names and generic-function names are
contract sketches, not implementation authorization.

## 1. Purpose

Layer 2 is the policy and composition framework of Ataxia. Protocol-specific
Layer 1 callbacks invoke its typed sink methods. It constructs semantic
compositor state, invokes replaceable policies, builds presentation snapshots,
routes input, schedules animations, calls typed Layer 1 functions, and exposes
controlled agent operations.

Its native-facing dependency is the direct Common Lisp API defined in
[wlroots–Common Lisp Boundary and Layer 1–Layer 2 Interface](LAYER-1-2-INTERFACE.md).

The design has four goals:

1. no raw wlroots pointer, C struct layout, or CFFI call appears in Layer 2;
2. no central class accumulates every compositor feature;
3. every desktop policy is replaceable through a CLOS protocol or explicit hook;
4. replacement remains performant because services are pinned per transaction,
   not looked up for every vertex, pixel, or list element.

## 2. Core Design Rules

### 2.1 The kernel owns ordering, not meaning

The Layer 2 kernel owns:

- owner-thread enforcement;
- object identity and lifecycle;
- transactions and revisions;
- framework transaction and domain-event ordering;
- service lookup and replacement;
- hook registration and dispatch;
- command mailbox processing;
- observation delivery;
- safe-point and shutdown coordination.

It does not know what a window position, focus target, resize edge, cursor image,
animation property, or renderable surface means.

### 2.2 Services own semantics

Every semantic operation dispatches first on an active service object. This is
important for hot replacement:

```text
(project-world active-world-service world camera entities viewport)
(route-input active-input-router context event)
(resolve-animation active-animation-resolver context transition)
(build-render-graph active-render-planner presentation output)
```

The first dispatch argument pins the implementation. Globally defining methods
only on `view` or `surface` would leave old and new plugin methods simultaneously
applicable and would not define which implementation is active.

### 2.3 Entities compose immutable components

Semantic objects have identity, lifecycle, revision, and a bounded component
collection. Component values are externally immutable and are owned by a service
identified in their schema.

There is no public `(setf component-value)`. Changes go through mutation
transactions so hooks, animation, observations, and agents see one coherent
transition.

### 2.4 Hooks are not the domain model

CLOS generic functions define durable domain contracts. Hooks provide ordered,
dynamic extension points around those contracts. A render backend is a CLOS
service, not a render hook. A hook can observe or amend a render plan at a named
boundary but does not replace the render protocol itself.

### 2.5 Standard CLOS first

The kernel should use portable CLOS generic functions and explicit descriptors.
It should not require a particular Metaobject Protocol implementation. Class
redefinition may remain useful during development, but supported hot replacement
uses service generations and explicit component migration rather than depending
on implementation-specific instance updating.

## 3. System Overview

```mermaid
flowchart LR
    L1IN[Protocol-specific Layer 1 callbacks]
    L1OUT[Typed Layer 1 wlroots functions]

    subgraph KERNEL[Layer 2 runtime kernel]
        RUNTIME[Compositor runtime]
        OBJECTS[Object registry]
        SCOPE[Service scope]
        HOOKS[Hook registry]
        TX[Transaction manager]
        MAILBOX[Command mailbox]
        OBS[Observation bus]
    end

    subgraph DOMAINS[Layer 2 domain services]
        SINKS[Protocol policy sinks]
        SHELL[Shell and focus]
        WORLD[World and placement]
        INPUT[Input and cursor]
        ANIM[Animation]
        PRESENT[Scene and presentation]
        RENDER[Render planner and executor]
        OUTPUT[Output and frame scheduling]
        AGENT[Agent actions and control]
    end

    L1IN --> SINKS
    SINKS --> TX
    RUNTIME --> TX
    TX --> SCOPE
    TX --> HOOKS
    TX --> OBJECTS
    TX --> SHELL
    TX --> WORLD
    TX --> INPUT
    TX --> ANIM
    TX --> PRESENT
    TX --> OUTPUT
    MAILBOX --> TX
    AGENT --> MAILBOX
    PRESENT --> RENDER
    OUTPUT --> RENDER
    RENDER --> L1OUT
    TX --> L1OUT
    TX --> OBS
    OBS --> AGENT
```

The arrows show permitted collaboration, not inheritance. Domain services do
not reach into runtime slots; they use kernel protocols supplied in a transaction
context.

## 4. Kernel Object Model

### 4.1 Class relationships

```mermaid
classDiagram
    class CompositorRuntime {
        state
        ownerThread
        revision
        step()
        stop()
    }

    class ObjectRegistry {
        capacity
        lookup()
        announce()
        retire()
    }

    class KernelObject {
        objectId
        objectKind
        lifecycle
        revision
        components
    }

    class NativeResource {
        layer1Wrapper
        wrapperClass
        wrapperGeneration
    }

    class SemanticEntity {
        semanticKind
    }

    class ComponentMap {
        count
        lookup()
        snapshot()
    }

    class ComponentSchema {
        key
        ownerService
        version
        classification
        validate()
        copy()
        migrate()
    }

    class ServiceScope {
        generation
        resolve()
        pin()
    }

    class HookRegistry {
        generation
        dispatch()
    }

    class TransactionManager {
        begin()
        prepare()
        commit()
        abort()
    }

    CompositorRuntime *-- ObjectRegistry
    CompositorRuntime *-- ServiceScope
    CompositorRuntime *-- HookRegistry
    CompositorRuntime *-- TransactionManager
    ObjectRegistry o-- KernelObject
    KernelObject <|-- NativeResource
    KernelObject <|-- SemanticEntity
    KernelObject *-- ComponentMap
    ComponentMap o-- ComponentSchema
```

### 4.2 `compositor-runtime`

The runtime is deliberately small. Its conceptual slots are:

| Slot | Responsibility |
|---|---|
| state | `created`, `starting`, `running`, `stopping`, `stopped`, `failed` |
| owner thread | only thread allowed to mutate compositor/native state |
| Layer 1 runtime | typed wrapper provenance, callback depth, and public protocol APIs |
| object registry | all live Layer 2 identities |
| service scope | immutable active service generation |
| hook registry | immutable hook/handler generation |
| transaction manager | revisions, write sets, effects, publication |
| mailbox | cross-thread and agent command ingress |
| observation bus | bounded committed observations |
| frame coordinator | requested outputs, deadlines, active frames |
| clocks | registered monotonic, presentation, and virtual clocks |
| diagnostics | bounded faults, counters, and trace sinks |

The runtime does not store windows, cursors, or animations in dedicated slots.
Those are entities and services in the registry/scope.

### 4.3 `kernel-object`

Every observable Layer 2 object shares:

- stable object identity;
- keyword or descriptor kind;
- lifecycle state;
- monotonically increasing object revision;
- bounded immutable component snapshot;
- creation provenance and timestamp;
- optional semantic classification.

Two subclasses distinguish ownership:

- `native-resource`: relates semantic state to a typed, live Layer 1 wrapper;
- `semantic-entity`: exists only in Layer 2 and may relate multiple resources.

Native retirement and semantic retirement are related but not identical. A view
can outlive one surface commit, while a typed surface wrapper becomes unusable
as soon as its wlroots destroy callback invalidates it.

### 4.4 Semantic entity kinds

Initial semantic entity classes should remain shallow:

```mermaid
classDiagram
    class SemanticEntity
    class Client
    class Surface
    class SurfaceRole
    class View
    class ApplicationSession
    class Seat
    class Output
    class Viewport
    class InteractiveOperation
    class AnimationInstance
    class AgentPrincipal

    SemanticEntity <|-- Client
    SemanticEntity <|-- Surface
    SemanticEntity <|-- SurfaceRole
    SemanticEntity <|-- View
    SemanticEntity <|-- ApplicationSession
    SemanticEntity <|-- Seat
    SemanticEntity <|-- Output
    SemanticEntity <|-- Viewport
    SemanticEntity <|-- InteractiveOperation
    SemanticEntity <|-- AnimationInstance
    SemanticEntity <|-- AgentPrincipal
```

Subclasses express stable identity categories, not behavior matrices. A spherical
view and planar view are both `view`; their placement components and active world
service differ.

### 4.5 Component schema

A component schema is a CLOS object owned by one service family. It defines:

- stable component key and schema version;
- acceptable entity kinds;
- value validation and defensive-copy behavior;
- equality and revision behavior;
- serialization and security classification;
- optional migration between schema versions;
- whether changes require frame, hit-index, focus, or observation invalidation.

The component collection API promises immutable snapshots. The concrete storage
structure remains an implementation choice to benchmark: persistent map,
copy-on-write hash table, or compact sorted vector. That decision must not leak
into domain methods.

### 4.6 Example composition

```mermaid
flowchart TB
    APP[Application session]
    VIEW1[View A]
    VIEW2[View B]
    SURFACE1[Surface tree A]
    SURFACE2[Surface tree B]

    APP -->|groups| VIEW1
    APP -->|groups| VIEW2
    VIEW1 -->|presents| SURFACE1
    VIEW2 -->|presents| SURFACE2

    VIEW1 --> P1[Placement component: planar placement]
    VIEW1 --> A1[Animation policy component: spring profile]
    VIEW1 --> D1[Decoration component: server frame]

    VIEW2 --> P2[Placement component: spherical placement]
    VIEW2 --> A2[Animation policy component: immediate profile]
    VIEW2 --> D2[Decoration component: client side]
```

The application session does not own one location. Moving an application as a
group is a grouping-policy operation over its current views.

## 5. CLOS Protocol Conventions

### 5.1 Dispatch convention

Domain generics dispatch on the service first and typed values afterward:

| Generic contract | Primary dispatch |
|---|---|
| handle XDG resize request | XDG policy sink, concrete request |
| validate component | component schema, entity, value |
| project world | world service, world state, camera, entities, viewport |
| place relative entity | world service, parent placement, relation |
| hit test | hit-test service, presentation snapshot, output point |
| route input | input router, route context, input event |
| choose focus | focus policy, focus context, candidates |
| begin interactive operation | shell service, operation request |
| resolve cursor | cursor policy, cursor context |
| resolve animation | animation resolver, animation context, transition |
| sample animation | interpolator, definition, time |
| build scene | scene source, scene context |
| build render graph | render planner, presentation snapshot |
| execute render graph | render executor, concrete render context, render graph |
| authorize action | action provider, principal, action |

This convention makes the active service generation explicit and prevents
accidental dispatch to a method belonging to an inactive plugin.

### 5.2 Protocol objects versus function slots

Replaceable behavior is represented by CLOS objects with generic functions.
Function values remain appropriate for small pure callbacks such as an easing
curve, but a service is not a property list of closures. CLOS objects provide:

- introspection;
- typed specialization;
- lifecycle methods;
- stable identity and version metadata;
- method combination where it is semantically appropriate;
- coherent replacement as one service instance.

### 5.3 No uncontrolled method combination

Numeric priority, veto, fault containment, and dynamic registration belong to
the hook system. Standard CLOS method combination does not replace hooks because
method order is based on specificity, not arbitrary runtime priority.

Domain generics should normally have one active primary provider. Cooperative
methods are used only where the protocol explicitly defines composition.

## 6. Services and Plugins

### 6.1 Service classes

```mermaid
classDiagram
    class ServiceKey {
        name
        protocolVersion
    }

    class ServiceDescriptor {
        key
        providerVersion
        capabilities
        dependencies
        componentSchemas
    }

    class ServiceProvider {
        state
        validate()
        start()
        stop()
    }

    class ServiceScope {
        generation
        providers
        resolve()
    }

    class ServiceReference {
        scopeGeneration
        provider
    }

    class PluginDefinition {
        identity
        version
        serviceDescriptors
        dependencies
    }

    class PluginInstance {
        state
        providers
        resources
    }

    ServiceDescriptor --> ServiceKey
    ServiceProvider --> ServiceDescriptor
    ServiceScope o-- ServiceProvider
    ServiceReference --> ServiceScope
    ServiceReference --> ServiceProvider
    PluginDefinition o-- ServiceDescriptor
    PluginInstance --> PluginDefinition
    PluginInstance o-- ServiceProvider
```

### 6.2 Service scope

A service scope is immutable after publication. It maps service keys to provider
instances and carries a generation. A transaction pins exactly one scope.

Service lookup returns a `service-reference`, not an untracked provider pointer.
The reference keeps the scope generation alive until the transaction/frame ends.

### 6.3 Plugin lifecycle

Plugin activation stages:

1. validate manifest, versions, and dependency graph;
2. construct candidate providers without publishing them;
3. validate component schemas and service collisions;
4. start providers against a private candidate scope;
5. run compatibility/migration preparation;
6. atomically publish the new service scope;
7. let existing pinned transactions finish on the old scope;
8. stop old providers in reverse dependency order.

### 6.4 Atomic replacement diagram

```mermaid
sequenceDiagram
    participant C as Control or Lisp shell
    participant R as Runtime owner thread
    participant P as Plugin manager
    participant N as New provider
    participant S as Active service scope
    participant O as Old provider

    C->>R: request replacement
    R->>P: prepare candidate
    P->>N: construct and validate
    N-->>P: candidate ready
    P->>N: start in private scope
    N-->>P: started
    P->>S: publish new generation atomically
    S-->>R: new pinned lookups use new provider
    R-->>C: replacement committed
    P->>O: stop after old pins drain

    Note over P,S: Any failure before publication leaves the old scope active
```

### 6.5 Component migration

Replacing a service does not implicitly reinterpret its old opaque component
values. A provider declares one of:

- values remain compatible;
- migrate values transactionally;
- detach old values and install defaults;
- reject replacement while dependent entities exist.

Migration is bounded and prepared before scope publication. A world-service
replacement may require converting every affected placement; it cannot publish a
half-migrated world.

## 7. Protocol Callbacks, Domain Events, Hooks, and Commands

### 7.1 Event classes

```mermaid
classDiagram
    class FrameworkEvent {
        eventId
        sequence
        timestamp
        phase
        subject
        cause
        provenance
    }

    class DomainEvent
    class MutationEvent
    class InputEvent
    class FrameEvent
    class AgentCommandEvent

    FrameworkEvent <|-- DomainEvent
    DomainEvent <|-- MutationEvent
    DomainEvent <|-- InputEvent
    DomainEvent <|-- FrameEvent
    FrameworkEvent <|-- AgentCommandEvent
```

Framework events are immutable domain facts or requests. Exact Layer 1 callback
values do not inherit from this hierarchy; `xdg-request-resize`,
`pointer-motion-event`, and `output-present-event` retain their protocol package
types until a policy sink deliberately creates a domain event.

### 7.2 Protocol policy sinks

An active protocol policy sink specializes the exact generic functions exported
by one Layer 1 protocol package. Its callback may produce:

- typed-wrapper/semantic-resource relationship changes;
- a semantic entity mutation;
- a policy request;
- a domain event.

Sinks do not directly mutate registries. They propose work through the current
transaction.

### 7.3 Direct callback entry

There is no native event router. The concrete Layer 1 package already knows the
callback and invokes its corresponding generic function, for example:

```lisp
(xdg-toplevel-request-resize active-xdg-policy request)
(pointer-motion active-input-service event)
(output-frame active-output-service output)
```

Each protocol manager holds a typed sink installed at a safe point. Callback
entry pins that sink generation for its dynamic extent. Replacing the service
changes the next callback without changing native listeners or kernel cases.

An unhandled required callback is a configuration error for that protocol
package. Optional protocol packages are simply not created or advertised.

### 7.4 Hooks

A hook point is an explicitly registered object:

| Property | Meaning |
|---|---|
| identity/version | stable extension contract |
| argument schema | bounded typed arguments |
| reducer | notify, veto, collect, first value, pipeline, or custom reducer |
| failure policy | propagate, disable handler, quarantine plugin, or report |
| criticality | whether failures may be ignored |
| mutation permission | observe only or may propose through transaction writer |
| classification | public, sensitive, secure |

Hook handlers run against a frozen handler list. Adding/removing a handler during
dispatch affects the next invocation.

### 7.5 Callbacks versus events versus hooks versus commands

- **protocol callback**: exact wlroots/Wayland fact or request entering its typed
  Layer 2 sink;
- **domain event**: semantic fact/request intentionally created inside Layer 2;
- **generic function**: the primary domain contract used to decide behavior;
- **hook**: ordered extension around a named point in that contract;
- **mutation**: proposed framework state transition;
- **effect**: staged external or native side effect;
- **command**: mailbox/RPC request asking the owner thread to run a transaction;
- **typed Layer 1 call**: concrete `wlr_*`/`wl_*` wrapper invoked at its declared
  callback or safe-point mode.

Conflating these concepts is how a generic framework becomes an untraceable
collection of callbacks.

## 8. Transactions and Mutations

### 8.1 Transaction class

```mermaid
classDiagram
    class Transaction {
        transactionId
        state
        baseRuntimeRevision
        pinnedServiceScope
        writeSet
        effects
        events
        observations
        prepare()
        commit()
        abort()
    }

    class MutationProposal {
        subject
        componentPath
        operation
        oldValue
        proposedValue
        cause
        provenance
    }

    class Effect {
        phase
        fallibility
        target
        execute()
    }

    class Layer1CallEffect
    class Observation

    Transaction o-- MutationProposal
    Transaction o-- Effect
    Effect <|-- Layer1CallEffect
    Transaction o-- Observation
```

### 8.2 Mutation descriptor

A general mutation proposal contains:

- subject entity;
- component key and optional semantic property path;
- operation descriptor;
- old value/revision;
- proposed value;
- initiating event/cause;
- provenance;
- transaction identity;
- bounded domain metadata.

There is no central enumeration of operations such as `map`, `pickup`, or
`drop`. Domain services define operation descriptors. General animation and
observation services match descriptors without requiring kernel edits.

### 8.3 Transaction stages

1. pin the active service and hook generations;
2. validate the initiating callback, domain event, or mailbox command;
3. construct bounded mutation proposals;
4. validate component schemas and expected revisions;
5. dispatch authorization/veto hooks;
6. resolve animation and invalidation consequences;
7. prepare fallible typed Layer 1 call effects and all publication storage;
8. execute required prepublication effects;
9. atomically publish the local write set and runtime revision;
10. execute postpublication notifications/effects;
11. publish domain events and observations;
12. release service pins and temporary values.

### 8.4 Honest native atomicity

Layer 2 transactions are atomic for Layer 2 state. Wayland clients, DRM, and
direct wlroots calls affect external systems and cannot always be rolled back.

Effects declare one of:

- `precondition-only`: no externally visible mutation;
- `required-before-publish`: must succeed before local state publication;
- `post-publish`: failure is reconciled by an exact later callback or fault;
- `irreversible`: transaction records honest terminal/partial semantics.

The core does not fabricate undo. If a plugin wants history, it observes
committed mutation descriptors and stores inverse domain operations itself.

### 8.5 Protocol-callback transaction sequence

```mermaid
sequenceDiagram
    participant L1 as Typed Layer 1 callback
    participant PS as Protocol policy sink
    participant TX as Transaction
    participant DS as Domain service
    participant HK as Hooks
    participant API as Typed Layer 1 functions
    participant OB as Observation bus

    L1->>PS: xdg-toplevel-request-resize(request)
    PS->>TX: begin/join and propose transition
    TX->>DS: validate and decide policy
    DS-->>TX: mutations and effects
    TX->>HK: authorization and extension hooks
    HK-->>TX: reduced result
    TX->>API: required concrete wlroots calls
    API-->>TX: direct typed result
    TX->>TX: publish local write set
    TX->>OB: publish committed observations
    TX-->>PS: committed revision
```

### 8.6 Later protocol facts

When a client acknowledgement, surface commit, page flip, presentation report,
or buffer release arrives later, its exact protocol callback opens a new
transaction. Protocol-specific state—such as an XDG configure serial or output
commit sequence—relates it to a pending entity/component. The original
transaction never stays open while waiting for a client or page flip.

### 8.7 Layer 2-requested native objects

Some native objects exist because of Layer 2 policy rather than a client or
backend event. Logical seats are the reference case; protocol globals, headless
outputs, server-published toplevel/workspace handles, hardware cursors/layers,
Xwayland instances, and compositor-owned transfer sources follow the same
transaction ordering.

The same boundary also covers service-owned event-loop sources, explicitly
provisioned clients from owned FDs, compositor-owned synthetic input providers,
server-originated activation tokens, and native objects produced by an accepted
DRM-lease, drag, output-management, or presentation operation. Root/bootstrap
factories and operation-scoped render objects use the same exact Layer 1 calls,
but their legal phases and publication rules are different.

The kernel does not provide a generic factory service. The responsible domain
provider calls the exact constructor exported by the relevant Layer 1 package:

```lisp
(seat-create layer-1-runtime seat-name active-seat-sink)
(headless-output-create headless-backend width height active-output-sink)
(foreign-toplevel-handle-create toplevel-manager state)
```

Creation rules:

1. the domain service proposes the semantic entity and exact native constructor;
2. the transaction validates names, quotas, service dependencies, and runtime
   phase before entering Layer 1;
3. the constructor is a `required-before-publish` effect;
4. Layer 1 returns a live typed wrapper only after required listeners/sinks are
   installed;
5. the transaction then publishes the semantic entity and a native-resource
   relation containing that wrapper;
6. the semantic object ID remains authoritative; the wrapper is provenance and
   native capability, not semantic identity;
7. constructor failure publishes nothing;
8. unexpected failure after construction schedules the exact destructor at the
   outermost safe point.

Destruction first retires the semantic relationships, then executes the exact
Layer 1 destructor. The native destroy callback invalidates the wrapper. A
protocol global with live client resources is quiesced and retains its provider
generation when immediate destruction would invalidate callbacks still required
by Wayland clients.

Backend-created physical outputs/devices, ordinary connected clients, and
client-created surfaces, roles, offers, constraints, inhibitors, and requests
never use this path. Their exact callbacks create Layer 2 relationships around
already-existing wrappers. An explicitly provisioned client, server-originated
activation token, custom DRM mode, or granted lease has a separate exact typed
operation so provenance cannot be confused.

## 9. Runtime Turn and Safe Points

```mermaid
flowchart TD
    START[Begin runtime turn]
    MAIL[Drain bounded owner mailbox]
    TIMER[Run due Lisp timers]
    DISPATCH[Call wl_event_loop_dispatch; typed callbacks transact synchronously]
    SAFE[Run outermost callback-safe-point effects]
    CLOCK[Sample clocks and due animations]
    CURSOR[Freeze cursor and interaction state]
    FRAME[Build requested presentation snapshots]
    RENDER[Render and submit output frames]
    OBS[Flush bounded observations]
    RETIRE[Retire unreferenced objects and scopes]
    STOP{Stopping?}

    START --> MAIL --> TIMER --> DISPATCH --> SAFE --> CLOCK --> CURSOR
    CURSOR --> FRAME --> RENDER --> OBS --> RETIRE --> STOP
    STOP -- no --> START
    STOP -- yes --> SHUTDOWN[Ordered shutdown]
```

Each stage has a work budget so sustained native callbacks or agent traffic
cannot starve frame deadlines. Native callback ordering is the wlroots signal
order; Layer 2 adds no bridge queue.

## 10. Domain Service Graph

```mermaid
flowchart LR
    PROTO[Protocol policy sinks]
    MODEL[Entity and component model]
    SHELL[Shell operations]
    FOCUS[Focus policy]
    WORLD[World and placement]
    SCENE[Scene sources]
    PROJ[Projection and hit mapping]
    ANIM[Animation resolver and scheduler]
    PRES[Presentation builder]
    PLAN[Render planner]
    EXEC[Render executor]
    OUT[Output and frame scheduler]
    INPUT[Input router]
    CURSOR[Cursor services]
    AGENT[Agent action providers]

    PROTO --> MODEL
    PROTO --> SHELL
    PROTO --> INPUT
    SHELL --> WORLD
    SHELL --> FOCUS
    MODEL --> SCENE
    WORLD --> PROJ
    SCENE --> PRES
    PROJ --> PRES
    ANIM --> PRES
    CURSOR --> PRES
    PRES --> PLAN --> EXEC
    OUT --> PRES
    OUT --> EXEC
    INPUT --> CURSOR
    INPUT --> PROJ
    INPUT --> FOCUS
    AGENT --> SHELL
    AGENT --> INPUT
    AGENT --> OUT
```

This graph is a dependency graph between service protocols. Providers may be
replaced independently when their declared compatibility requirements hold.

## 11. World, Scene, Presentation, and Rendering

### 11.1 Core value objects

| Value | Owner | Meaning |
|---|---|---|
| world state | world service | opaque spatial universe |
| placement | world service | opaque entity location/orientation/relation |
| camera | world service | opaque projection viewpoint |
| viewport | output policy | output-local logical view definition |
| scene snapshot | scene source | semantic display entities |
| projection snapshot | projection service | frozen render geometry plus inverse mapping |
| animation overlay | animation service | sampled presentation-only changes |
| presentation snapshot | presentation builder | immutable complete output revision |
| hit index | projection/presentation | query structure tied to presentation revision |
| render graph | render planner | validated output-local passes and commands |
| render context | render executor | concrete typed renderer/output/buffer wrappers for one frame |

### 11.2 Presentation pipeline

```mermaid
flowchart LR
    ENT[Entity/component snapshot]
    WORLD[World service]
    SCENE[Scene source]
    ANIM[Animation samples]
    CURSOR[Cursor presentation]
    OVERLAY[Output-local overlays]
    PROJECT[Projection builder]
    SNAP[Immutable presentation snapshot]
    HIT[Hit index]
    GRAPH[Render graph]
    EXEC[Render executor]
    TARGET[Typed wlroots render context]

    ENT --> SCENE
    ENT --> WORLD
    WORLD --> PROJECT
    SCENE --> PROJECT
    ANIM --> PROJECT
    PROJECT --> SNAP
    CURSOR --> SNAP
    OVERLAY --> SNAP
    SNAP --> HIT
    SNAP --> GRAPH
    GRAPH --> EXEC
    TARGET --> EXEC
```

The hit index and render graph share one presentation snapshot. Effects that move
or distort visible content must also supply the corresponding inverse hit map or
declare the content non-interactive.

### 11.3 Service protocols

#### World service

- construct/copy/compare placements;
- compose relative placements;
- apply domain motion operations;
- project entities for a camera/viewport;
- create inverse queries for input;
- serialize bounded semantic placement descriptions;
- migrate placements when supported.

#### Scene source

- enumerate semantic entities for a presentation context;
- provide content, role, overlay, decoration, and cursor lanes;
- declare stable ordering relationships, not final GPU commands.

#### Presentation builder

- retain concrete surface-buffer snapshots;
- combine scene, projection, animation, cursor, and overlays;
- assign one revision;
- build render and hit inputs from identical geometry;
- retain all service generations required for snapshot lifetime.

#### Render planner

- translate presentation primitives into typed render passes;
- negotiate executor capabilities;
- compute damage, occlusion, batching, and effect dependencies;
- reject unsupported plans before target mutation.

#### Render executor

- acquire concrete render buffers/passes through typed Layer 1 functions;
- execute validated render graphs;
- import sampled buffers;
- build/test/commit concrete output state and report sampled surfaces;
- cancel safely on any error.

### 11.4 Render graph classes

```mermaid
classDiagram
    class RenderGraph {
        revision
        output
        passes
        requiredCapabilities
        damage
    }

    class RenderPass {
        passId
        dependencies
        target
        commands
        protectionClass
    }

    class RenderCommand
    class ClearCommand
    class SolidCommand
    class SurfaceQuadCommand
    class SurfaceMeshCommand
    class EffectCommand
    class CursorCommand

    RenderGraph o-- RenderPass
    RenderPass o-- RenderCommand
    RenderCommand <|-- ClearCommand
    RenderCommand <|-- SolidCommand
    RenderCommand <|-- SurfaceQuadCommand
    RenderCommand <|-- SurfaceMeshCommand
    RenderCommand <|-- EffectCommand
    RenderCommand <|-- CursorCommand
```

Command subclasses are extensible, but each executor advertises the command and
effect capabilities it accepts. Plugins cannot submit arbitrary foreign calls as
render commands.

## 12. Input, Focus, Cursor, and Interactive Operations

### 12.1 Input service decomposition

- device normalizer;
- seat assignment policy;
- input filter/transform chain;
- grab/interactive-operation router;
- pointer or spatial-navigation motion service;
- presentation hit tester;
- focus policy;
- cursor context and appearance policy;
- protocol seat sink;
- observation sink.

### 12.2 Input route context

One immutable route context contains:

- runtime and pinned service scope;
- seat and device entities;
- provenance;
- current presentation snapshot per relevant output;
- active grab/interactive operation;
- cursor state;
- accumulated route metadata;
- delivery result.

Each stage returns a new context or a bounded stage result. Stages do not mutate
global focus/cursor state behind the transaction.

### 12.3 Pointer interaction sequence

```mermaid
sequenceDiagram
    participant L1 as Exact Layer 1 input callback
    participant IR as Input router
    participant OP as Active operation
    participant CM as Cursor motion service
    participant HT as Presentation hit tester
    participant FP as Focus policy
    participant CP as Cursor policy
    participant SS as Seat sink
    participant TX as Transaction

    L1->>IR: pointer event
    IR->>OP: route through active grab if present
    alt active move or resize
        OP->>TX: propose placement or configure transition
        OP->>CP: resolve operation cursor
    else normal routing
        IR->>CM: update logical pointing state
        CM->>HT: query frozen presentation
        HT-->>FP: surface-local hit candidates
        FP->>TX: propose focus transition
        FP->>CP: resolve cursor context
        IR->>SS: stage typed Layer 1 seat enter/motion/button/axis/frame calls
    end
    TX->>TX: commit state and delivery effects
```

### 12.4 Interactive operation protocol

An interactive operation is an entity with components:

- operation kind descriptor;
- target view;
- initiating seat and validated serial;
- initial placement and configure state;
- input anchor;
- active buttons/touch points;
- cursor context;
- termination conditions;
- operation-specific bounded state.

The shell service supplies generics to begin, update, finish, and cancel an
operation. The runtime guarantees cancellation on target destruction, seat
removal, loss of required grab, shutdown, or explicit policy cancellation.

Move and resize are default operation providers, not hard-coded kernel states.

### 12.5 Cursor state

Cursor state is per logical seat and separates:

- logical position/navigation state;
- current hit/focus context;
- client cursor surface request;
- compositor shape/theme request;
- active operation override;
- animation sample;
- hardware/software rendering decision.

The cursor presentation entity is excluded from hit candidates by schema. A
client cursor surface is content for that entity, not a normal scene view.

## 13. Animation System

### 13.1 Animation classes

```mermaid
classDiagram
    class TransitionDescriptor {
        subject
        componentPath
        operation
        oldValue
        newValue
        cause
        provenance
        metadata
    }

    class AnimationContext {
        runtimeRevision
        subjectComponents
        world
        output
        userPolicy
    }

    class AnimationDefinition {
        durationPolicy
        clockKey
        tracks
        interruptionPolicy
    }

    class AnimationTrack {
        binding
        interpolator
        easing
        timing
    }

    class PropertyBinding {
        targetPath
        read()
        applySample()
    }

    class AnimationInstance {
        definition
        subject
        startTime
        state
    }

    class AnimationSample {
        timestamp
        values
        damageHint
    }

    TransitionDescriptor --> AnimationContext
    AnimationContext --> AnimationDefinition
    AnimationDefinition o-- AnimationTrack
    AnimationTrack --> PropertyBinding
    AnimationInstance --> AnimationDefinition
    AnimationInstance --> AnimationSample
```

### 13.2 General resolution

Animation resolution is a CLOS service plus a hook point. It receives the full
transition and context. Resolution order is policy-defined but may consult:

1. an explicit per-view animation-policy component;
2. role or application-session policy;
3. current world/profile policy;
4. user/plugin rules;
5. default fallback.

The kernel does not assign special meaning to `map`, `pickup`, or `drop`. A
transition may represent a placement change, focus emphasis, topology change,
surface replacement, opacity policy, spherical geodesic motion, or a plugin’s
new component operation.

### 13.3 Different animations per window

```mermaid
flowchart LR
    T[Same transition descriptor kind]
    R[Animation resolver]
    VA[View A components]
    VB[View B components]
    DA[Spring and overshoot definition]
    DB[Immediate opacity-only definition]
    IA[Animation instance A]
    IB[Animation instance B]

    T --> R
    VA --> R
    VB --> R
    R -->|context for View A| DA --> IA
    R -->|context for View B| DB --> IB
```

Definitions are resolved when an animation starts and pinned for that instance.
Replacing the global resolver affects new transitions. A separate interruption
policy decides whether existing instances keep, migrate, blend, or terminate.

### 13.4 Model versus presentation animation

#### Model animation

Samples invoke a domain mutation binding, such as a world-service placement
operation. This changes authoritative state and publishes mutations.

Use it when intermediate state must affect semantics, navigation, or persistence.

#### Presentation animation

Samples produce an overlay applied while freezing the presentation snapshot.
Authoritative state may already be at its target.

Use it for visual transitions, shadows, opacity, decoration, or client-buffer
cross-fades. The overlay must update hit geometry if it moves interactive
content.

### 13.5 Scheduler

The scheduler maintains only active instances. Each runtime turn:

1. group due instances by clock;
2. sample each definition into a bounded arena;
3. apply model bindings through one transaction;
4. publish presentation overlays keyed by subject and revision;
5. invalidate affected outputs/regions;
6. retire completed instances;
7. request the next deadline only while active work remains.

CLOS dispatch occurs per animation instance/track, not per mesh vertex or pixel.
Bindings and interpolators may compile optimized samplers for hot paths.

## 14. Output and Frame Coordination

### 14.1 Frame coordinator

The frame coordinator tracks:

- output frame requests and presentation deadlines;
- content/animation/cursor invalidations;
- in-flight frame transactions;
- output configuration generation;
- per-output presentation revision;
- renderer and scheduler service pins.

### 14.2 Frame sequence

```mermaid
sequenceDiagram
    participant O as Exact output-frame callback
    participant FC as Frame coordinator
    participant AS as Animation scheduler
    participant PB as Presentation builder
    participant RP as Render planner
    participant RE as Render executor
    participant L1 as Typed Layer 1 render/output API

    O->>FC: frame deadline or damage
    FC->>AS: sample due animations
    AS-->>FC: presentation overlays and next deadline
    FC->>PB: freeze presentation snapshot
    PB-->>FC: snapshot, hit index, buffer snapshots
    FC->>RP: build validated render graph
    RP-->>FC: graph and damage
    FC->>RE: execute graph with concrete render context
    RE->>L1: render-pass/buffer/output-state calls
    L1-->>RE: direct typed results
    RE-->>FC: submitted state and sampled surfaces
    FC->>L1: exact frame-done/presentation-feedback calls
```

One output frame pins all participating service generations until submission or
cancellation.

## 15. Agentic Control

### 15.1 Control classes

```mermaid
classDiagram
    class AgentPrincipal {
        principalId
        capabilities
        classifications
    }

    class ControlSession {
        sessionId
        principal
        quotas
    }

    class ActionProvider {
        actionSchemas
        authorize()
        prepare()
        commit()
    }

    class ActionProposal {
        actionId
        name
        arguments
        provenance
        pinnedProvider
    }

    class ObservationSubscription {
        filter
        classification
        cursor
        queue
    }

    ControlSession --> AgentPrincipal
    ControlSession o-- ActionProposal
    ActionProposal --> ActionProvider
    ControlSession o-- ObservationSubscription
```

### 15.2 Action flow

```mermaid
sequenceDiagram
    participant A as Agent
    participant CS as Control server
    participant MB as Owner mailbox
    participant AP as Action provider
    participant TX as Transaction manager
    participant DS as Domain services
    participant OB as Observation bus

    A->>CS: typed request and request identity
    CS->>CS: decode bounded proper data
    CS->>MB: authenticated command
    MB->>AP: authorize under pinned provider generation
    AP->>TX: prepare action proposal
    TX->>DS: invoke same domain protocols as local policy
    DS-->>TX: mutations and effects
    TX-->>MB: committed result
    TX->>OB: observations with provenance
    MB-->>CS: static bounded response
    CS-->>A: result
```

Agent actions do not bypass hooks, animation resolution, focus policy, input
routing, or service replacement rules. Synthetic input enters after native device
normalization but before logical routing, with explicit provenance.

## 16. Package Boundaries

```mermaid
flowchart TB
    L1PROTO[ataxia.wlr.protocol.* public APIs]
    L1RENDER[ataxia.wlr.render and seat public APIs]
    KID[ataxia.kernel.identity]
    KRES[ataxia.kernel.resources]
    KEVT[ataxia.kernel.events]
    KSVC[ataxia.kernel.services]
    KHOOK[ataxia.kernel.hooks]
    KTX[ataxia.kernel.transactions]
    KRUN[ataxia.kernel.runtime]

    MODEL[ataxia.model]
    ADAPT[ataxia.protocol-policy]
    WORLD[ataxia.world]
    SCENE[ataxia.scene]
    PRES[ataxia.presentation]
    RENDER[ataxia.render]
    INPUT[ataxia.input]
    SHELL[ataxia.shell]
    ANIM[ataxia.animation]
    OUTPUT[ataxia.output]
    AGENT[ataxia.agent]
    CONTROL[ataxia.control]

    KID --> KRES
    KID --> KEVT
    KRES --> KTX
    KEVT --> KTX
    KSVC --> KTX
    KHOOK --> KTX
    KTX --> KRUN

    L1PROTO --> ADAPT
    L1RENDER --> RENDER
    L1RENDER --> INPUT
    KRES --> MODEL
    KEVT --> ADAPT
    MODEL --> WORLD
    MODEL --> SCENE
    WORLD --> PRES
    SCENE --> PRES
    PRES --> RENDER
    MODEL --> INPUT
    MODEL --> SHELL
    MODEL --> ANIM
    MODEL --> OUTPUT
    KTX --> AGENT
    AGENT --> CONTROL
```

Rules:

- kernel packages never depend on domain packages;
- domain packages depend on kernel protocols, not runtime internals;
- protocol policy packages may depend on public typed Layer 1 protocol wrappers
  and domain protocols;
- concrete render executors and seat sinks may depend on public typed Layer 1
  APIs;
- world, scene, presentation, shell, animation, and agent packages never depend
  on raw wlroots/CFFI packages;
- profiles/plugins depend on domain protocols and provide services;
- the executable composition root is the only package allowed to assemble all
  domains and defaults.

## 17. Ownership and Lifecycle Summary

| Object/value | Creator | Mutator | Lifetime owner |
|---|---|---|---|
| Layer 2-requested persistent wrapper | exact Layer 1 constructor effect | exact typed Layer 1 package | owning service plus native destroy signal |
| backend/client-created wrapper relation | exact callback transaction | resource protocol | object registry plus native destroy signal |
| scoped native wrapper | concrete render/response/transfer provider | exact typed Layer 1 package | one dynamic operation |
| semantic entity | domain service transaction | owning domain service | object registry |
| component value | component-owning service | replacement transaction only | entity snapshot |
| service provider | plugin manager | provider lifecycle protocol | service scope/plugin instance |
| hook handler | plugin/control transaction | hook registry transaction | hook generation |
| transaction | transaction manager | owner thread | one runtime operation |
| presentation snapshot | presentation builder | immutable | in-flight frame/readers |
| surface-buffer snapshot | Layer 1 surface callback | release only | presentation/frame transaction |
| animation instance | animation scheduler | scheduler transaction | active set/entity registry |
| interactive operation | shell service | shell/input transactions | entity registry |
| agent proposal | action provider | transaction stages | control request |

## 18. Layer 2 Invariants

1. Only the owner thread publishes Layer 2 mutations.
2. Every transaction pins one service scope and one hook generation.
3. No domain service accesses runtime slots directly.
4. No public component value is mutated in place after publication.
5. Every component schema has one owning service identity.
6. No kernel object assumes Euclidean coordinates.
7. Placement belongs to views/entities, not application identity.
8. Render and hit geometry share one presentation revision.
9. Cursor presentation content is never a hit-test candidate.
10. Typed Layer 1 calls report honest direct results or later concrete callbacks;
    local atomicity does not imply external rollback.
11. Service replacement publishes only a fully validated candidate scope.
12. Old providers remain alive while pinned transactions or frames use them.
13. Animation resolution receives a general transition descriptor and may vary
    per subject.
14. Agent actions use the same domain protocols and hooks as local operations.
15. Every mailbox/observation queue, component collection, callback copy, render
    plan, animation set, and observation is bounded.
16. The kernel can run with no desktop-profile plugin installed.
17. No generic native-object factory exists; every constructor belongs to one
    concrete Layer 1 package and native type.
18. A semantic entity is published only after its required native constructor
    and listener installation succeed.
19. Typed Layer 1 wrappers are provenance/capability references, never semantic
    object identities.
20. Layer 2 never misclassifies an observed backend-, connection-, or
    client-created object as policy-created; explicitly server-originated
    variants have separate exact typed operations.

## 19. Decisions Still Required

1. Choose the concrete immutable component-map representation after benchmarks.
2. Decide whether semantic entity kinds are shallow subclasses, explicit kind
   descriptors, or a hybrid; behavior remains service-owned either way.
3. Define which typed Layer 1 calls qualify as `required-before-publish` for the
   initial protocols.
4. Define whether component migration is mandatory for hot world replacement or
   whether providers may reject replacement with live placements.
5. Approve whether presentation snapshots retain old service providers directly
   or retain one scope-generation reference.
6. Define initial hook catalog and which hooks may veto or propose mutations.
7. Choose observation classifications and default redaction boundaries.
8. Confirm the conventional planar profile as the first end-to-end provider set.

No Layer 2 implementation should begin until these choices and the class/service
boundaries in this document are approved.
