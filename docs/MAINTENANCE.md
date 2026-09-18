# Maintenance and idle performance

Keep changes local to the layer that owns the behavior. The ASDF files specify
load order; add a new source file there when extracting a module.
[World services and porting](WORLD-SERVICES.md) describes the UI/desktop adapters,
service lifecycle, capability boundaries, and independent-host tests.
[Computer-use design](COMPUTER-USE-DESIGN.md) records the CUA ownership boundary: no
CUA sessions, helpers, or optional-feature definitions belong in Kernel/Runtime.

| Area | Responsibility |
| --- | --- |
| `native/`, `src/runtime/` | Native ABI, object lifetime, event dispatch and callback containment. |
| `src/kernel/` | Stable application/seat/output identities, protocol delivery, frame transactions and World recovery. |
| `src/world/` | Shared geometry, damage, animation, shortcuts, UI/desktop protocols, service dispatch and command-line parsing. |
| `src/worlds/` | Placement, camera, focus and layout policy for each World. Metaworld extends Infinite World. |
| `src/world/{slint,rmlui}/` | UI engine adapters and graphics resources. Their native libraries own engine state. |
| `src/world/synthetic-input/` | Optional World-owned native devices; Runtime only adopts them and dispatches their events. |
| `src/world/computer-use/` | Optional native bridge, sessions, input, captures, batches and the local request server. `service.lisp` owns enable/disable and startup rollback. |
| `src/world/assistant/` | Assistant protocol, scheduling, audio, tools and UI. `worker.lisp` owns the protocol mailbox loop; `protocol.lisp` owns message semantics; `lifecycle.lisp` owns tasks and approvals; `service.lisp` owns World attachment and teardown. |
| `src/control/`, `scripts/` | Owner-thread inspection and process entry points. |

World and native graphics mutations stay on the compositor owner thread. Workers
use the existing control queue for World operations. A callback may request a
frame or publish work; it must not wait for network, audio, disk, or a subprocess.
See [asynchronous service design](ASYNC_WORLD_SERVICES.md) for the ownership model.

Use the World service registry as the single controller lookup. Assistant model
selection, generation settings, modal dialogs, and refresh context belong to
the controller, so inspecting it shows the state of that conversation. Store
future per-controller state in explicit slots or owned structures.

Enabling a new service rolls back its timers, UI, and newly created dependencies
if initialization fails. An existing service may have other callers; preserve
it when a later caller fails to enable a listener or the assistant. Shell
callbacks resolve the current service when invoked, allowing a controller to be
disabled and replaced without leaving callbacks tied to the old conversation.

## Idle scheduling

| Service | Wake source |
| --- | --- |
| Runtime | Wayland descriptor, timer, or control-pipe event. Flush client events before blocking in dispatch. |
| World renderer | Damage, a client frame request, or an active animation. Hidden/offscreen damage must not continuously wake outputs. |
| UI engines | Input, invalidation, animation, or the engine's next deadline. Disarm the World timer when no deadline exists. |
| Assistant protocol | One semaphore notification per mailbox batch, or the earliest RPC, voice-start, or task deadline. No periodic idle timeout. |
| Voice playback | Queued audio or explicit shutdown. Each audio generation owns its wake semaphore. |
| Launcher and state writer | Queued work. Both block while their queues are empty. |
| Watchdog | An active owner operation and its deadline. It waits without a timeout when no operation is active. |
| Shell clock/battery | One shared minute deadline when closed; at most 30 seconds apart while power details are open. Opening the panel reads fresh battery data immediately. |
| Computer-use sessions | Next input step, held-input limit, or session expiration. No timer when all sessions are closed. |

When replacing a worker, invalidate its generation and signal its **old**
semaphore. Give the replacement a fresh semaphore so the retiring worker cannot
consume its wakeup. Check the generation again after waking and before applying
events. All stop/reset paths must wake workers that otherwise wait indefinitely.

Keep RPC deadlines, task limits, and visible clock/input cadence independent of
idle optimization. Timed waits inside an active computer-use action are bounded
work, not background idle polling.

When another drawable requests a frame, unchanged Slint and RmlUi textures
bypass GLES state capture and rendering. Slint exposes its per-component redraw
flag; RmlUi also checks its next UI deadline. Service each shared engine once,
then dispatch callbacks for every visible component before selecting outputs.
A Slint timer that changes no pixels needs no frame, and a change on one output
does not repaint another output's settled UI. Atlas advances animations on
output frames without an additional 16 ms timer. Slint's active-animation query
is still global, so simultaneous-output animation pacing can be broader than
its per-component timer redraws.

## Damage and visibility

Damage uses at most 32 rectangles per output, including pending changes and
buffer-history repair. Nearby rectangles merge when extra pixels cost less than
another pass (currently 1,024 pixel equivalents); fragmentation forces the
cheapest merge. A bounding rectangle or the full output wins when its estimated
cost is lower. Damage is rounded outwards and clipped; changes arriving during
a staged frame and failed commits remain pending.

Infinite World and Metaworld subtract committed opaque surface coverage from
windows and the background beneath it. Covered client damage and fully offscreen
quads do not request painting. Popups outside their root window remain included.
Visible clients can receive frame callbacks without falsely reporting a texture
presentation; fully covered clients resume on exposure using their latest buffer.

Opacity is always conservative: alpha holes, window transparency, effects and
arbitrary camera rotations cannot become opaque bounding boxes. Alpha textures
leave a filtering margin at opaque edges. Opaque regions and visibility splitting
have separate budgets of 64 rectangles; excess complexity falls back to extra
drawing. Moving, hiding, restacking, changing opacity or revealing windows damages
their coverage so previously skipped pixels are reconstructed.

## Verification

- `make test`: native glue, Kernel damage, geometry/layout, animation, shortcuts,
  World scheduling, shared command-line options and Slint checks.
- `make test-occlusion`: native opaque-region/callback metadata and GLES pixel
  comparisons against full painting, including alpha holes, minification, all
  output transforms, partial damage, offroot popups and exposure.
- `make test-portability`: fresh-process dependency boundaries, an unrelated desktop
  host, and the full assistant/shell lifecycle on plain Infinite World.
- `make test-assistant`: mailbox/deadline scheduling, concurrent producers,
  reconnect/shutdown, audio fixtures, UI, approvals and preview processes.
  `tests/assistant-service-lifecycle.lisp` also injects startup failures and checks
  resource cleanup, existing callers, and controller replacement with native UI.
- `make test-computer-use`: actual Wayland input and captures, transformed and
  offscreen windows, popup grabs, clipboard, concurrent sessions and socket API.
- `make test-rmlui-shell test-rmlui-shell-world`: shell pixels, layout and World
  integration when changing shell chrome.
- `make benchmark-idle`: a five-second assistant-worker sample, a five-second
  headless Metaworld sample after warmup, and Slint timer/animation checks across
  two headless outputs. It starts no model service and does not modify the live
  desktop. Linux `/proc` and an EGL renderer are required.

The idle benchmark reports measurements rather than imposing machine-specific
CPU thresholds. Slint checks assert zero frames on unchanged outputs, continued
callback delivery without rendering, resize after clean texture reuse, and
completed Atlas animations. The worker should have zero timed wakeups. A quiet World should
render no frames between scheduled UI updates; `bar-updates` identifies a
clock/battery deadline crossed during the sample. The stop timer accounts for
the final dispatch. This measures compositor work, not a live Codex process,
hardware scanout, active clients, or a focused blinking text cursor.

Use headless tests for repeatable measurements. Keep live applications and
conversation state intact during reloads; code changes to a running worker loop
take effect when that worker is next started. Native library changes require a
new process. Do not unload graphics libraries under live objects.
