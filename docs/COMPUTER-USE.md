# Agent computer use

## Codex JavaScript interface

For the Codex-compatible `cua` API, persistent `cua_repl` tool, agent skill,
browser providers and compatibility limits, see [CODEX-COMPUTER-USE.md](CODEX-COMPUTER-USE.md).
The data-only protocol provides capabilities, target PID metadata, seat-local
paste, desktop snapshots, direct layout arrangement, window controls, and
navigation; see the [desktop API](../skills/ataxia-computer-use/references/desktop.md).
These operations use the same native session and honor pause, disconnect, expiry,
and sequence checks. Desktop mutations require the observed revision. A desktop snapshot covers the whole current World; camera navigation explicitly names the output to change.

CUA navigation uses `setViewport`, `panViewport`, `frameWindow`, and `frameRegion`,
with an explicit monitor ID. X/y and pan deltas are world units; rotation is radians.
Framing respects the output work area and leaves window placement and focus alone.

## Native protocol

An agent connects to the World and starts active immediately. A selected output
anchors its activity UI and viewport captures. Camera commands explicitly select
their output; window discovery and local control span the World.
Ataxia shows its name, activity, and current view. Connecting automatically creates
a separate Wayland seat, keyboard, pointer, colored cursor, and cursor label.
The human pointer and keyboard retain their own seat and focus.

The panel is hidden when no sessions are open. It uses the same flat light
style as the shell. The Agent sessions panel provides **Pause**, **Resume**, **Disconnect**, and
**Pause all**. **Ctrl+Alt+Escape** pauses every active agent. Typing into or
clicking an application an agent controls also pauses that agent. Pause releases
held keys/buttons, cancels movement/typing/capture, clears focus, and removes the
last screenshot. A paused session stays paused until resumed through the activity panel.

Window view is the default. Select an application with `focus`; captures contain
that application's surfaces, including popups and subsurfaces. Pointer coordinates
are local to the image, independent of desktop position, zoom, rotation, and other
windows. Focus does not raise the application or change human focus. A selected
window can be selected initially even when covered, offscreen, or on another monitor.
When an application
unmaps or closes, Ataxia clears the target and screenshot; the agent must explicitly
select another window. Closing during movement, typing, or held input pauses the
session. Mapped minimized/hidden-workspace windows remain discoverable with
`available: false`; restoring or navigating to them is a separate World action.

Use `getWorld()` for structured arrangement and `getWindow(id)` for app content.
Explicit `desktop` view and `captureViewport()` show only the selected monitor's
current camera; they are not an overview of the infinite World. SDK target methods
always select window view, including after a low-level viewport operation.
An agent cannot
click World chrome, the application menu, or its own session controls; synthetic
keys bypass World shortcuts. Application launch is limited to desktop IDs from
the existing launcher catalog. New windows do not steal an agent's focus.

## Enable

Build the optional native input helper and RmlUi UI:

```sh
make computer-use
```

Load `ataxia-computer-use/infinite-world` for Infinite World, or
`ataxia-computer-use/metaworld` for Metaworld, and call
`(ataxia.computer-use:enable world)` on the
compositor owner thread, after starting the existing SLY control plane. In the
World's startup code:

```lisp
;; Load the adapter before constructing the compositor.
(asdf:load-system "ataxia-computer-use/metaworld")
;; After the World, Runtime, and control queue are started on the owner thread:
(ataxia.computer-use:enable world)
```

Enable creates a Lisp listener at `$XDG_RUNTIME_DIR/ataxia-computer-use.sock`
with mode 0600. The listener runs in the compositor's Lisp image; the CLI is
also Lisp. Requests enter the existing owner-thread queue directly. There is no
Python bridge, separate broker process, or SLY TCP round trip.

To choose another socket, use a directory owned by you and not writable by others:

```lisp
(ataxia.computer-use:enable world :socket "/run/user/1000/my-agent.sock")
```

`(ataxia.computer-use:disable world)` disconnects all sessions and removes the UI
and listener. Stopping the listener shuts down accepted connections; partial or
queued requests from that listener cannot enter a replacement listener.
Repeated enable calls retain the current listener. To enable only
the UI and Lisp API, pass `:start-server nil`.
World replacement or output removal disconnects affected sessions. Enable is
opt-in per World; this module does not change startup configuration.

## Batch actions and observe once

Use `batch` for a sequence whose next steps are already known. One request can
focus Firefox, open a tab, enter a URL, wait for its title, and return a screenshot:

```json
{
  "op": "batch",
  "token": "…",
  "sequence": 1,
  "actions": [
    {"op": "focus", "window": 483},
    {"op": "key", "key": "t", "modifiers": ["Control_L"]},
    {"op": "type", "text": "https://finance.yahoo.com/quote/NVDA/"},
    {"op": "key", "key": "Return"},
    {"op": "wait-window", "window": 483, "title": "NVIDIA", "timeout": 10}
  ]
}
```

Replace the window ID with one from `observe`. Pass the JSON to
`scripts/ataxia-computer-use request` as an argument or through stdin.
The response includes the final session, visible windows, `completed` action
count, and a screenshot. Set `"capture": false` to omit the screenshot.
Before the screenshot, a batch waits for the selected window's surface commits,
title, dimensions, and available window list to stay unchanged for 150 ms, up to
two seconds. `image.settled` reports whether that quiet interval was observed;
`image.wait-seconds` reports time spent waiting. This helps capture completed UI
updates but cannot prove that an application has finished asynchronous work.
Set `"settle": 0` for immediate capture, or a value up to two seconds to choose
the quiet interval.

Movement and typing finish before the next action starts; there is no need for
the agent to poll `status` between them. Before input, a batch waits up to one
second for the application's client to bind this seat's keyboard or pointer.
`wait-window` waits for a visible window
matching its optional numeric `window`, exact `app-id`, and case-insensitive
`title` substring. At least one filter is required. `"focus": true` also focuses
the match, which is useful after `launch`; multiple matches then produce an
error. Window titles indicate application state, not complete webpage loading.
Use `{"op":"wait-stable","settle":0.15,"timeout":2}` between actions when
opening a search field or changing a view before typing. It watches the selected
window, an optional `window` ID, or all allowed windows in desktop view. Unlike
the final screenshot's bounded wait, this explicit wait fails with `wait-timeout`
if updates continue. A quiet interval is an observation heuristic; use
`wait-window` when a known title change or new dialog is the required condition.

A batch accepts up to sixteen actions and has a thirty-second execution budget.
It supports `focus`, `view`, `move`, `button`, `scroll`, `key`, `type`, `launch`, and
`wait-window` and `wait-stable`. Window waits default to ten seconds; stable waits
default to two seconds. Both accept a twenty-second maximum timeout. The whole
batch consumes **one sequence number** when accepted.
Other input requests receive `busy` while it runs; `status`, `observe`, and
`disconnect` remain available. Human takeover cancels pending input and stops
the remaining actions.

On failure, the response reports `completed`, `failed-action` (one-based), the
error, and the final session state. `failed-action` is null if all actions
completed and the final observation failed. Completed actions have already happened;
do not replay the whole batch. Held input is released. Invalid action shapes
are rejected before execution; target and focus checks happen at each step.

Batch only steps that follow from the current observation. Use the returned
image to choose the next sequence when page content or placement is uncertain.
Prefer a window condition to repeated screenshots or a guessed long sleep.

## Agent protocol

Send one UTF-8 JSON object followed by a newline per Unix socket connection.
The reply is one JSON object and newline. No Lisp form, callback, shell command,
or arbitrary file path is accepted. The CLI accepts a JSON argument or stdin:

```sh
scripts/ataxia-computer-use request '{"op":"outputs"}'
scripts/ataxia-computer-use request \
  '{"op":"connect","name":"Atlas","purpose":"Organize the open project","output":1}'
```

Use an output ID from `outputs`; omit `output` to request the first output.
`connect` returns a secret `token` and an `active` session, ready for discovery and
control without a permission prompt. Paused sessions have no access to screenshots,
window titles, or input. The displayed name/purpose are
agent-provided descriptions, not authenticated identity.

Every action, including capture and disconnect, requires `sequence` equal to the
last accepted sequence plus one. `status` and `observe` do not advance it. A
rejected action normally leaves the sequence unchanged; capture consumes its
sequence when queued, even if the capture later fails. After any timeout or lost
response, use `status` before deciding what to do next; do not blindly retry input.
Actions are accepted serially. Movement and typing return `busy:true`; poll
`status` until `busy:false` before sending another action. Disconnect can cancel
a busy action.

| Operation | Additional fields | Behavior |
| --- | --- | --- |
| `outputs` | none; no token | Connected output IDs, names, logical sizes, scales |
| `connect` | `name`, `purpose`, optional `output`, `mode`; no token | Start an active session; default mode `window`; name ≤40, purpose ≤160 characters |
| `status` | `token` | State, sequence, busy flag, last activity, view, selected window, local position, focused window |
| `observe` | `token` | Available windows, their input readiness, and launchable desktop IDs |
| `view` | `mode`, optional `window` | Switch between `window` and `desktop`; optionally select an application |
| `move` | `x`, `y`, optional `duration` | Smooth cursor motion; duration 0.016–2 seconds, default 0.25 |
| `button` | optional `button`, `state` | `left`/`right`/`middle`; `click`/`down`/`up`; defaults left click |
| `scroll` | optional `x`, `y` | Horizontal/vertical wheel deltas, ±1000, positive right/down |
| `focus` | `window` | Select and focus an application; raises it only in desktop view |
| `key` | `key`, optional `state`, `modifiers` | XKB base key name; `tap`/`down`/`up`; default tap |
| `type` | `text` | Type up to 256 Unicode characters, including newline/tab |
| `launch` | `application` | Launch a desktop ID returned by observe, asynchronously |
| `capture` | none | Capture selected window, or selected output in desktop view; return PNG metadata |
| `batch` | `actions`, optional `capture`, `settle` | Execute a known sequence, wait internally, return one observation |
| `disconnect` | none | Release input and destroy the agent seat |

All rows after `observe` also require `token` and `sequence`.
Coordinates use **logical pixels of the current view, origin at top left**.
In window view, `observe` reports each window's native image dimensions and zero
origin. Select a window before capture or input; no window is selected on connect.
Each window's `input.keyboard` and `input.pointer` report whether that client has
bound the agent's devices. Unbound input is rejected as `input-not-ready`, without
claiming it was sent. Capture remains available. Some GTK clients bind seats only
at startup; launching a new application process after connecting allows those
clients to bind the agent seat. A new window in an existing process may retain
the same limitation. Ataxia never redirects this input through the human seat.
Remain inside `0 ≤ x < coordinate-width`, `0 ≤ y < coordinate-height` from the
latest image. Resizing invalidates pointer coordinates until a fresh capture;
the API returns `window-resized`. Changes to popup extents take effect with the
next capture, preserving the current input origin between observations.
Desktop view uses output-local coordinates and desktop bounds in `observe`.
Switch modes with `{"op":"view","mode":"desktop",…}` or request
`"mode":"desktop"` on connect. Release held input before changing modes or windows.
To drag, move to an application, send button down, move, then button up. A drag
retains its pressed surface and coordinate basis until all buttons are released,
including when crossing a popup or subsurface. Destroying that surface does not
redirect the release to another surface. Explicit protocol grabs, such as a
popup menu or drag-and-drop operation, retain their normal client behavior.

For a chord, use a base key such as `a`, `Return`, `BackSpace`, or `Left`, and a
modifier list drawn from `Control_L`, `Shift_L`, `Alt_L`, `Super_L`:

```json
{"op":"key","token":"…","sequence":3,"key":"a","modifiers":["Control_L"]}
```

Chords require no held keys and state `tap`. Use `type` for capitalization,
punctuation, and Unicode; it temporarily installs a keymap on the agent's own
keyboard and restores US afterward. It accepts at most 200 distinct characters
per action. Text reaches the application as ordinary Wayland key events; whether
particular Unicode characters insert text depends on the application's input
handling. The human keymap is unaffected.

Clipboard selections stay on the seat that requested them. Clients can transfer
text between applications through that seat's normal Wayland clipboard; selections
are not shared with the human or another agent. Native serial validation remains
in force, and destroying a source removes its offer.

Clipboard shortcuts also depend on the client's support for multiple seats. Some GTK
and Firefox paths send clipboard requests through their default seat even when
the key came from an agent seat; the mismatched serial is rejected. A successful
key reply confirms input delivery, not a completed copy or paste. Verify the
application result and use explicit `type` actions for observed text when needed.
Ataxia does not bridge an agent's clipboard into the human seat.

Successful replies contain `ok:true`. Errors contain `ok:false`, `error`, and
`message`, for example `not-active`, `sequence-mismatch`, `busy`, `target-blocked`,
`no-focus`, or `rate-limited`. Window/output IDs are valid only in the current
World. Tokens stop working across World replacement or after closed sessions are
pruned by the next connection request.

## Screenshots and limits

`capture` returns `image.path`, `width`, `height`, `coordinate-width`,
`coordinate-height`, `view`, `window`, and a compositor monotonic `timestamp`.
Window images include only the application over a neutral background, with no
World UI or cursors. They include surfaces extending beyond the main window.
Desktop images include World UI and visible cursors. Convert image coordinates to logical input
coordinates using the reported dimensions; images fit within 1280×960 without
upscaling. Output scale, rotation, and reflection are handled during conversion.
Only the most recent PNG per session is retained. Read/copy it before requesting
another capture; pause or disconnect deletes it. Files live in a private random
directory under `XDG_RUNTIME_DIR` (the temporary directory is a fallback).

At most four sessions may be active or paused. Active sessions close after
120 seconds without API traffic, paused sessions after ten minutes. Active `status` calls renew the session. Any key or
button held for five seconds triggers pause and release. Each session accepts at
most 100 requests per second; the listener bounds request size to 64 KiB and admits
eight concurrent requests. Captures are limited to 16 million source pixels.

The API is a guardrail for cooperative local agents, **not an OS sandbox**.
A process running as the desktop user can still use privileged SLY or other
same-user facilities directly. Permission to control an application also includes
what that application can do, including a terminal. Use OS/process isolation if
an agent must be prevented from bypassing this interface.

## Verification

Run `make test-computer-use` with access to a render device. The suite uses
separate headless compositors and native Wayland clients. It checks actual PNG
pixels and delivered input, including covered and offscreen windows, popups,
drags, clipboard isolation, concurrent agents, and all eight output transforms
at scales 1, 1.5, and 2 with a rotated canvas. Session activation and human takeover
are exercised inside the test fixtures. The suite does not connect to the running
desktop's computer-use socket.

## Implementation and checks

The World owns placement, focus policy, and rendering. The portable computer-use
service owns session activation, scope, deadlines, input state, capture authorization,
and UI. [World services](WORLD-SERVICES.md) documents the adapter contract.
The optional module contains session/input/UI/capture policy, a batch
runner, a bounded JSON data reader, and a local socket listener. It accepts
connections through the existing Runtime FD event API and dispatches bounded
Lisp workers. The JSON reader never invokes the Lisp reader or interns supplied
field names. Workers use the existing owner-thread queue in process; input
completion waits and PNG resizing/compression run off the owner thread.
Pixel readback happens during an authorized frame lease. Window capture samples
the application's drawable surfaces into a separate bounded framebuffer and
restores graphics state. Offscreen frame callbacks are completed before the
capture to let throttled clients repaint; this does not claim physical display
presentation. Clients still control when their new content is ready.
There is one deadline timer, armed only for sessions or actions. Idle UI does not
request recurring frames.

The optional `ataxia-world/synthetic-input` module owns synthetic wlroots devices
and emits ordinary keyboard events through Runtime. The CUA native bridge, client
identity queries, and formatted clipboard sources live in
`src/world/computer-use/`. They define no functions or state in Runtime or Kernel.
Runtime's `adopt-input-device` installs normal listeners on a caller-owned device;
Kernel's `register-input-device` attaches it directly to the intended seat. This
avoids temporarily replacing the human keyboard during registration. Kernel's
generic surface-frame completion supports offscreen consumers without claiming
physical presentation. It contains no session or capture policy.

The [design and ownership decisions](COMPUTER-USE-DESIGN.md) describe the boundary,
per-World integration and transaction limits.

```sh
make test-computer-use  # Real Wayland client, headless GLES, native Lisp socket API
make test              # Existing World, input, animation, rendering regressions
```

The integration tests use SLY port 4007 and require an available GLES renderer.
They exercise independent agent/human seats, capabilities, keymaps, pointer/button
events, chords, Unicode, ordering, human interruption, emergency pause, held-input
timeout, PNG encoding and all output transforms, shell-control protection, UI
pause/resume callbacks, disconnect, batch ordering and interruption, condition waits,
malformed JSON, covered/offscreen windows, fresh frame callbacks, resize guards,
outside subsurfaces, popup rendering and drags, explicit desktop mode, clipboard
seat isolation and serial rejection, listener replacement, four concurrent agents,
and zero settled frames. The socket integration runs with the SLY TCP listener stopped. Visual
artifacts are written to `build/agent-capture.png`
and `build/agent-api-capture.png`.

The Kernel regression suite also covers popup damage with floating-point positions
and nested fractional offsets. Pixel damage rounds outward to integer bounds;
drawable placement keeps its original precision.
