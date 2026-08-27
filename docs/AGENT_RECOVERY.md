# Agent Recovery

## Goal

Ataxia should retain unrestricted SLY access while remaining easy to restore
after an agent accidentally damages the World, owner loop, Runtime, loaded code,
or source tree.

Recovery is protection against accidental failure, not a security boundary. An
agent with operating-system access could also stop an external supervisor.

## Current Containment

Control requests are queued from SLY worker threads and executed synchronously
on the compositor owner thread. Ordinary Lisp conditions raised by a request are
captured and returned to the caller without escaping into the Wayland event
loop.

All Kernel-to-World protocol calls are contained by the Kernel. A guardian
thread times only that bounded Lisp extent. A condition or timeout revokes the
World and schedules rescue installation on the Runtime owner thread at a
libwayland idle safe point. Frame buffers are still released by the existing
frame transaction cleanup.

Runtime callback conditions are deliberately fail-stop. Runtime records the
first callback fault, requests loop termination, and raises the fault at the
next safe point instead of continuing with potentially corrupted wlroots state.

These mechanisms cannot reliably handle:

- an infinite loop outside a Kernel-to-World call;
- a blocking or invalid foreign call;
- destruction or corruption of wlroots, EGL, or Kernel objects;
- arbitrary redefinition of trusted methods;
- a native crash or process exit;
- destructive edits that make the working tree unbootable.

The SLY control timeout still only cancels a request that has not started.
Arbitrary owner-thread code is not interrupted. The guardian may interrupt only
the dynamic extent explicitly published by the Kernel before invoking World.

## Recovery Boundary

Final recovery authority must still live outside the compositor process.
Anything in the same Lisp image can be redefined, corrupted, or terminated by
the same unrestricted access it is intended to recover.

The preferred design has two complementary recovery levels:

1. A soft World reset preserves the Runtime, Kernel, Wayland clients, and stable
   protocol objects.
2. An external supervisor restores the entire process when the owner loop or
   native state is no longer trustworthy.

## Soft World Reset

When Runtime and Kernel remain healthy, recovery should install a fresh rescue
World and replay the Kernel's existing outputs, seats, cursor requests, and
applications. This retains connected Wayland clients.

The rescue operation must not depend on the damaged World's internal tables.
For predictable cleanup, World-owned external resources should eventually be
associated with a revocable World epoch or resource scope. This includes event
loop timers, idle sources, native components, frame requests, and registered
graphics cleanup actions.

A World checkpoint should contain only declarative policy state, such as:

- the World type and constructor options;
- camera position and zoom per output;
- window placement and presentation preferences;
- overlay configuration;
- named hooks or source definitions that can be reloaded.

It should not serialize live CLOS graphs, closures, wlroots pointers, EGL
objects, buffers, or GLES handles. Recovery should construct a new World, replay
stable Kernel objects, and then apply the declarative state.

## External Supervisor

The supervisor should be a small process independent of SLY and the compositor
event loop. A system service is sufficient for accidental-failure recovery; a
host-side supervisor provides a stronger boundary when operating inside a VM.

It should own:

- compositor process start, termination, and restart;
- the boot command and required environment;
- immutable `last-good`, `candidate`, and `rescue` boot slots;
- owner-loop health monitoring;
- logs and the most recent failure reason;
- optional application-session relaunch information.

The compositor should emit an owner-loop heartbeat through an independent Unix
socket or similarly minimal channel. The heartbeat must advance only after an
event-loop safe point completes. SLY responsiveness is not a sufficient health
check because SLY worker threads may remain alive while the owner thread is
deadlocked.

When the heartbeat expires, the supervisor should:

1. request graceful termination;
2. wait for a short fixed deadline;
3. force termination if necessary;
4. start the immutable `last-good` slot;
5. verify owner-loop heartbeat, control connectivity, output commits, and
   successful frames;
6. optionally relaunch the recorded application session.

Restarting from the active working tree is not recovery: an agent may have
broken that tree. The last-good slot must identify a validated commit or build
artifact outside the mutable candidate checkout.

## Candidate Promotion

Agent changes should be treated as candidates until they pass a health gate:

1. Record the current last-good revision and recovery configuration.
2. Apply the code or live-state change.
3. Confirm the owner-loop heartbeat continues advancing.
4. Confirm the control plane completes a round trip.
5. Confirm every active output commits several frames successfully.
6. Promote the candidate to last-good only after those checks pass.

Failure before promotion should first attempt a soft World reset. If the owner
loop does not respond or core invariants fail, the supervisor should restart the
last-good process.

## Recovery Ladder

| Failure | Recovery |
| --- | --- |
| Agent request raises a condition | Return the condition; keep running |
| Rendering fails for one frame | Fail the frame and retry |
| World policy or presentation call hangs | Watchdog installs rescue World |
| Owner thread hangs outside World | Supervisor terminates and restarts |
| Runtime, EGL, wlroots, or Kernel state is corrupted | Restart last-good |
| Native crash or process exit | Restart last-good |
| Candidate source no longer boots | Boot immutable last-good |
| Wayland clients are lost after restart | Relaunch from a session manifest |

## Wayland Limitation

A process restart destroys the compositor's `wl_display`, object IDs, protocol
serials, seats, buffers, and client transport connections. Standard Wayland
does not provide transparent client reconnection. Preserving clients therefore
requires the in-process soft World reset while Runtime and Kernel are still
healthy.

A generic reconnecting Wayland proxy would need to preserve protocol state,
file-descriptor passing, buffers, serials, and extension-specific semantics. It
would be a substantially more complex architecture and is not recommended as
the primary recovery mechanism.

Applications should instead be launched through a declarative session manifest
when practical. Firefox session restoration and terminals backed by persistent
tools such as tmux can reduce the cost of a hard restart.

## Rejected Primary Mechanisms

- `restart-case` handles signaled conditions but not hangs or native crashes.
- A guardian Lisp thread cannot safely interrupt arbitrary owner-thread work;
  this experiment restricts it to a Kernel-published World call extent.
- Saved Lisp images cannot restore live wlroots, Wayland, DRM, EGL, or GLES
  resources.
- `fork` duplicates unsafe threaded and GPU state while competing for the same
  sockets and device handles.
- CRIU-style process restoration is not a dependable boundary for active DRM,
  EGL, wlroots, and Wayland resources.
- Moving the entire World into another process would provide stronger isolation
  but would introduce IPC into input, rendering, and presentation paths and
  conflict with direct World-owned GLES rendering.

## Recommended Initial Scope

The smallest useful recovery system is:

1. guarded Kernel-to-World calls with a bounded watchdog;
2. one minimal rescue World factory;
3. an external supervisor with restart and heartbeat monitoring;
4. an immutable last-good boot slot;
5. a declarative session and World-state journal;
6. a single external recovery command that does not depend on SLY.

This preserves unrestricted agent access while ensuring the mechanism used to
recover from accidental destruction is not part of the state being destroyed.
