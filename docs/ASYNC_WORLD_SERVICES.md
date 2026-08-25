# Asynchronous World Services

## Goal

Ataxia should support independently running simulation, planning, networking,
and agent services without making World, Kernel, wlroots, damage, or rendering
state concurrently mutable.

Examples include:

- a pet walking around the screen;
- autonomous movement of native or Wayland objects;
- pathfinding and physics;
- network-backed widgets;
- an agent that observes copied state and issues visual intentions.

The synchronous compositor architecture is not an obstacle. It should remain
the authority that applies state and performs rendering.

## Core Rule

> Asynchronous services produce intent. Only the compositor owner thread may
> validate and apply that intent to the World.

```text
Independent service
        |
        | immutable update or target
        v
Bounded mailbox / latest-value slot
        |
        | pipe or eventfd wakeup
        v
Wayland owner thread
        |
        | validate and apply
        v
World state, damage, and frame request
        |
        v
Frame-sampled animation and synchronous rendering
```

The service must not directly mutate CLOS objects belonging to the live World.
It must never use wlroots objects, frame leases, GLES handles, Slint native
objects, or mutable World tables from its own thread.

## Existing Foundations

The current system already provides most required mechanisms:

- Runtime can attach file descriptors to the Wayland event loop.
- SLY control demonstrates a mutex-protected queue and pipe wakeup.
- Kernel deduplicates frame requests and latches requests made during a frame.
- The animation engine accepts arbitrary subjects and update closures.
- Infinite World samples animations from frame timestamps, damages previous and
  current coverage, and requests another frame while work remains.

The missing facility is a nonblocking, World-owned producer queue. SLY's current
request path is synchronous and waits for a returned result, whereas an
asynchronous service should normally publish work and continue immediately.

## Minimal Service Host

This should be a small reusable helper rather than a general actor framework.
One service host needs only:

- a worker thread or external-process handle;
- a bounded queue for discrete commands;
- latest-value slots for coalescible state;
- a pipe or eventfd used to wake the Runtime owner loop;
- a World-generation token;
- a stopped/running/failed state;
- a recorded failure condition;
- a World-owned function that applies updates on the owner thread.

The reusable host should not define compositor policy. Each World decides what
an update means, which objects it addresses, what damage it creates, and whether
a frame must be requested.

## Message Boundary

Values crossing the asynchronous boundary should be copied and immutable. A
service update may contain:

- a World-generation number;
- a World-private stable entity identifier;
- a command kind;
- a monotonic timestamp or sequence number;
- numeric positions, velocities, targets, or dimensions;
- an immutable payload owned by the service protocol.

The owner thread validates that:

- the World generation is still current;
- the target entity still exists;
- numeric values are finite and within policy limits;
- the update sequence is not stale;
- the requested operation is valid for the target;
- the World is not quiescing.

Arbitrary owner-thread closures may remain available as an escape hatch, but
typed World-private updates are preferable for ordinary service traffic because
they can be validated, coalesced, logged, and discarded safely.

## Queue Semantics

Two delivery modes are required.

### Discrete FIFO

Events that must not be lost remain ordered:

- spawn or remove an entity;
- begin an action;
- emit dialogue;
- respond to a click;
- complete a pathfinding request;
- report a service failure.

### Latest Wins

Intermediate values that become obsolete should be overwritten rather than
queued:

- desired position;
- desired velocity;
- cursor snapshot;
- pose or facing direction;
- progress indication;
- camera-follow target.

This prevents a fast producer from creating seconds of stale visual work. One
wakeup should remain pending while unpublished work exists, matching the
coalescing strategy already used by SLY control.

The owner callback should drain only a fixed number of messages or a short time
budget per dispatch. Remaining work should schedule another wakeup so an active
service cannot starve Wayland input, client commits, or frame callbacks.

## Moving Pet Example

A pet should be divided into independently paced behavior and presentation.

1. The service waits rather than busy-looping.
2. At a low decision rate, such as 5–20 Hz, it chooses a destination, action,
   or response.
3. It publishes the newest target position, desired velocity, and movement
   state.
4. The owner thread validates the update and applies it to the World-private pet
   object.
5. World starts or retargets a normal animation toward the service's target.
6. The animation engine interpolates at output presentation cadence.
7. Each frame damages both the previous and new pet coverage.
8. World requests another frame only while the pet remains visually active.
9. Picking uses the owner-thread-authoritative current position.
10. Clicks receive immediate synchronous feedback and may also be copied to the
    service for a later behavioral response.

The service should not publish one position per display frame. High-level
intent keeps the queue quiet, provides smooth movement, and allows output frame
pacing to remain authoritative.

## Fixed-Step Simulation

More involved physics can run at a fixed rate in the service. The service should
publish timestamped immutable snapshots, while World retains the newest two and
interpolates between them during rendering.

For this mode, a latest-value or double-buffered snapshot slot is preferable to
a FIFO of every simulation step. The renderer still reads only World-owned state
that the owner thread has adopted.

## Native Object Representation

A screen-local pet can be represented by an output-local drawable and
interactable overlay. It participates in overlay picking and renders below the
cursor.

A pet that lives inside an infinite canvas should instead be a World-space
native scene object. It needs the same World-private facilities as a window:

- placement and coverage;
- stacking or scene membership;
- drawable and interactable component;
- damage projection per output;
- picking and focus behavior;
- animation channels.

Kernel does not need to know that this object exists. It remains entirely
World-owned. Atlas World's unified scene-object model already demonstrates how
Wayland applications and native components can share rendering, damage,
picking, and input paths.

Infinite World's animation advancement currently handles window and output
subjects explicitly. A native World-space entity would require another
World-specific coverage and damage case; the generic animation engine itself
does not require modification.

## Input and Service Feedback

Wayland input remains synchronous:

1. Runtime delivers copied input to Kernel.
2. Kernel invokes World on the owner thread.
3. World performs picking against its authoritative applied state.
4. World immediately handles focus, capture, and visible feedback.
5. World optionally publishes a copied observation to the service.

The owner thread must never wait for the service before completing input
dispatch. A pet may react immediately with a local animation, then replace that
animation later when the service returns a more involved response.

Cursor motion sent to a service should normally use a latest-value slot rather
than a FIFO, since old cursor positions have no value to a delayed decision
loop.

## Rendering and Frame Pacing

The asynchronous service must not render directly. GLES execution remains
inside the bounded frame lease where Kernel has acquired the output buffer and
made EGL current.

The service also should not issue continuous redraw requests. Applying a new
visual intent may damage affected coverage and request one frame. While a World
animation remains active, the normal frame loop requests subsequent frames.
When nothing changes, both the service and compositor can remain idle.

This preserves damage-driven rendering and low idle CPU usage.

## Lifecycle

The World owns its services.

### Attach

- Allocate the mailbox and wakeup descriptor.
- Register the descriptor with Runtime on the owner thread.
- Start the worker or external process.
- Assign the current World-generation token.

### Quiesce

- Reject new service updates.
- Remove the Runtime event source.
- signal the worker to stop;
- discard queued updates;
- invalidate the World-generation token.

Quiescing the owner thread should not wait indefinitely for a stuck worker. An
in-process worker may be joined elsewhere with a deadline; an external process
can be terminated independently. Any late message is harmless because its
generation no longer matches.

### Failure

A service failure should not stop the compositor. World may freeze the entity,
hide it, display a minimal failure state, or restart the service. The failure
condition should be inspectable through SLY and the external recovery plane.

## Implementation Options

| Model | Best use | Tradeoff |
| --- | --- | --- |
| Wayland event-loop timer | Simple deterministic motion | Not independently asynchronous |
| In-process Lisp worker | Physics, pathfinding, lightweight agents | Shares process failure boundary |
| External local service | LLMs, networking, crash isolation | Requires serialized messages |
| Direct concurrent World mutation | None | Races World and wlroots state |
| Independent rendering thread | None in this architecture | Violates EGL and frame-lease ownership |

For a simple pet, the existing animator plus an event-loop timer is sufficient.
An independent service becomes useful when behavior may block, perform expensive
computation, use networking, or require separate failure isolation.

## Recommended Initial Design

Start with one in-process service host containing:

1. a worker thread;
2. one bounded discrete queue;
3. one keyed latest-value table;
4. one pipe or eventfd wakeup;
5. one World-generation token;
6. a fixed owner-thread drain budget;
7. World-specific update application;
8. clean quiescing and stale-message rejection.

Use it first for a native pet whose service publishes occasional movement
targets and whose World presentation uses the existing animator. The same
handoff can later support an external service without changing the synchronous
World mutation boundary.

The architecture therefore remains synchronous where correctness requires it,
while behavior and computation can proceed independently wherever concurrency
is useful.
