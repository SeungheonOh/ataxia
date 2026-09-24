# Desktop assistant

The reusable `ataxia-assistant` system connects the native RmlUi panel to the
installed [Codex app-server](https://learn.chatgpt.com/docs/app-server).
Opening the panel starts neither Codex nor audio.

```sh
make assistant
ataxia
# Optional initial project directory:
ataxia --assistant-project /path/to/project
```

Normal desktop sessions enable the service with full access. `--no-assistant`
or `ATAXIA_ASSISTANT=0` opts out; headless sessions still require `--assistant`.
Attaching the service and opening its panel starts no Codex process and opens no
audio devices. Connect, Send, or Voice starts the app-server lazily.

`ATAXIA_ASSISTANT=1` also enables startup. `--no-sly` keeps the internal owner
queue available without opening a SLY listener. Load the system before starting
the World; call `(ataxia.assistant:enable world)` on its owner thread to attach it.

| Control | Action |
| --- | --- |
| Super+A / Assistant in the bar | Open or focus the panel |
| Super+Shift+A / Voice | Toggle voice |
| Send | Submit a task |
| Ctrl+Enter | Send the composer; Enter remains a newline |
| Send during a turn | Steer that turn |
| Model name | Expand or collapse Model and Effort controls above the composer |
| Details | Show task activity, plan and limits |
| Pause / Resume | Release agent input immediately / continue after a human action |
| Stop | Interrupt the task and close its input session |
| Escape while the panel has focus | Close the panel and audio |
| Ctrl+Alt+Escape | Pause all computer-use sessions and assistant audio |

Closing the panel preserves a running text task. It restores prior application
focus when that application is still available. The bar shows actual task and
microphone state while the panel is closed.

The panel follows the shell's monochrome workstation style: square boundaries,
16 dp text rows and inverse text actions. Its reading area uses 16 dp horizontal
gutters, 8 dp header insets and separation between messages; controls use 12 dp
monospaced text with 16 dp horizontal gaps. The current model, Fast toggle and
Voice action stay beside Send. Clicking the model expands Model and Effort rows
inside the panel, directly above the composer. There is no separate overlay or
screen-wide input capture; the conversation and draft remain usable. Changes
save automatically. Done, Escape, or clicking the model name again collapses
settings without losing the draft. A second Escape closes the assistant.
Pause and Stop appear during a task. Routine activity and limits are under Details.
The working directory is editable below the header.

The model picker uses the signed-in Codex account's available models. **Connect**
loads these without submitting a task or granting desktop input. The first model
entry follows your configured model and effort. Effort lists only the selected
model's supported levels; **Auto** restores its default. Switching to a model that
does not support the chosen effort resets the effort to Auto. Fast uses the
model's advertised speed tier and displays unavailable when unsupported; turning
it off explicitly requests standard speed. Fast and effort are independent.

These choices last for the assistant session and preserve the conversation. They
apply to the next new typed task; steering keeps the active task's settings. A
pending-change note appears while a task runs. Realtime audio uses its separate
Codex voice configuration.

## Access and layout

The assistant always has full access to commands, files, applications, World
layout and live Lisp. Codex threads start and resume with `sandbox` set to
`danger-full-access` and `approvalPolicy` set to `never`. There is no scope
selector, per-task window allowlist or extra execution approval dialog.
New windows are accessible as soon as they appear. Pause and Stop remain user
controls over the current task.

The working directory supplies Codex's `cwd` and resolves relative file paths;
it is not an access boundary. Metaworld defaults to the Ataxia source tree.
Other Worlds can choose a directory with
`(ataxia.assistant:enable world :project "/path/to/project/")`.

The default control path is `ataxia_lisp`, using the same owner queue as SLY.
It can discover, resolve, change and report World objects in one short call,
returning only the fields needed. Native input/capture remains available through
`ataxia_observe` and `ataxia_act` for the contents of client applications. SLY
cannot inspect a Firefox page or a native application's widgets by itself.

A task creates no native input seat until its first CUA tool call. Lisp, shell,
file and voice-only work therefore creates no agent cursor, input-session state
or session timeout. Existing sessions still pause at task completion or human
takeover and resume only on a new human request. Tool calls never undo a pause.
The compatible CUA desktop tools below also create a session when first used.

`ataxia_arrange` applies a batch directly using the latest desktop snapshot
revision. The assistant and CUA share the same revision and operation path.
There are no retained layout plans, apply tokens or Undo history. Validation
checks the whole batch before mutation, and the World rolls back a failed batch.
Intervening layout changes and active drags reject stale requests. Titles and
presentation animations do not count as layout edits. `remove-group` returns
its remaining windows and widgets to the canvas without closing them;
standalone Worlds keep their only sub-world.

`ataxia_lisp` reads and compiles one form off the owner thread. `inspect` and
`apply` bind `WORLD` to the active World and run on its owner thread with a
250 ms execution budget; `apply` requests a full refresh. `inspect` also permits
World control calls that already record their own damage, avoiding that full repaint. `worker` permits filesystem
work and compilation off the compositor thread with a 30 second budget. It must
not mutate World state or install class/generic-function definitions. Output is
bounded to 16 KiB and printed on the owner thread before live values can escape
to the worker. Errors return to the chat without replacing the World.
Changes made before an error are not rolled back or automatically replayed.
This is trusted live development access, not a Lisp sandbox. Pause and Stop reject subsequent calls; they do not reverse completed changes.

Do not ASDF-reload a live World's dependency tree from a worker. Class redefinition
can temporarily remove accessors used by frames. Read/compile on workers and
install prepared definitions in a short owner-thread operation. No Kernel or
Runtime implementation changes are needed by this service.

`ataxia_window` controls a window by its stable ID: `close`, `minimize`, `restore`,
`maximize`, or `fullscreen`. Closing sends a normal application close request;
the assistant checks afterward for closure or a save dialog. It does not force-kill
the application. A window is one application toplevel;
closing every window of an app requires selecting each matching window.
Snapshots include minimized windows and window state. Minimize persists across
layout updates; Restore unminimizes and exits expanded presentation. The launcher
can also unminimize a window. Maximize and fullscreen fill the containing sub-world
for grouped windows, or the output for canvas windows. Window state changes update the layout revision. They do not move the human's focus to another app.

`ataxia_observe` without a window returns the window inventory and installed app
catalog without taking a screenshot or changing the selected target. Supplying
a window captures it by default; `capture:false` requests metadata only. To open
an app, use `ataxia_act` with `op:"launch"`, an `application` ID from that catalog,
and `capture:false`, then observe to verify its window. Launching is asynchronous;
an accepted request alone does not prove that a window opened.

The launcher reads `applications/*.desktop` from `XDG_DATA_HOME` and every
directory in `XDG_DATA_DIRS`, using the [XDG defaults and precedence](https://specifications.freedesktop.org/basedir/latest/).
This includes Snap and Flatpak export directories advertised by the session.
User entries take precedence by desktop ID, including hidden overrides. The
catalog stays cached between launches; discovery adds no idle polling.

Native action schemas describe each operation separately: a click is `move`
followed by `button`, key chords use XKB base names such as lowercase `n` with
`Control_L`, and timing values are seconds. The assistant uses its existing
native session rather than an external CUA MCP connection with another approval
flow. Application discovery does not require a second permission request.

Execution requests follow the full-access policy without another prompt. Model
questions support supplied choices and typed answers. Sign in opens the app-server's browser
flow; Retry rechecks account state. Credentials are managed by Codex.

## Response formatting

Assistant messages render paragraphs, Markdown headings, bold/italic text,
numbered and bulleted lists, checkboxes, inline/fenced code, quotes and simple
pipe tables. User messages have a separate background. Links show their labels
and addresses; they do not open automatically. Raw HTML remains literal text.
Formatting also works as a response streams in, with bounded message rendering.

## RmlUi apps

The assistant receives a built-in [UI authoring guide](../src/world/assistant/instructions.md)
on every new thread, together with the working directory. It covers
creating, opening, testing and updating custom UI, light styling, native form
controls, supported callbacks and storage limitations. Enter a working directory
and ask, for example, "Create a simple notepad and open it." Every new UI opens as a separate Wayland window in its own dedicated
process; it is not embedded in the assistant or compositor. The
[notepad starter](../examples/assistant/notepad.rml) is a working
multiline editor with temporary text; closing or reloading clears its contents.

Ask the assistant to create an RML app inside the selected project. The isolated
Wayland preview host renders it and returns a screenshot and window ID. The
assistant can click and type using its independent seat. Invalid XML preserves
the last working preview; valid updates replace the document.

[The counter example](../examples/assistant/counter.rml) uses the initial host's
predefined events: `increment`, `decrement`, and `reset` update `counter`;
`input:change` copies text into `result`; `submit` sets `status`. Native form
controls also work. These events execute no Lisp or arbitrary application code.
Preview paths may be absolute or relative to the working directory. Each preview
host resolves assets within the project, or the document directory for a file
outside the project, with a system-font fallback. Up to four preview clients may be open. Stop preserves previews;
disabling the assistant or replacing its World closes them. Installing a preview
as a persistent compositor widget is a separate development action.

## Voice

Voice uses the signed-in **Codex CLI account**, through app-server's v3 WebRTC
transport. It does not require a separate API key. The previous WebSocket adapter
selected an API-key-only path; that was an integration error, not an account
limitation. Codex chooses its configured realtime model independently of the
panel's text/task model selector, as in the CLI's own voice mode.

The adapter is checked against **Codex CLI 0.156.1**. Ataxia locates the packaged
`codex-voice-host` beside the configured CLI executable, resolves PATH symlinks,
and uses its manifest build identifier for the versioned helper handshake. This
is Codex's internal same-build protocol, not a stable public audio API; other
CLI versions require compatibility verification. Install the packaged CLI with
its voice resources. No additional PipeWire utilities or audio libraries need
to be installed for the adapter.

The helper handles WebRTC, capture and playback outside the compositor. Only
bounded control messages and SDP signaling cross the worker's pipes; no PCM
passes through Lisp. SDP and native diagnostics are not logged. Microphone and
speaker devices open after the WebRTC answer connects, initially muted, and the
UI displays **Microphone on** only after audio is enabled. **Mute mic** preserves
playback and waits for acknowledgement that the helper has invalidated the old
capture generation before displaying **Microphone muted**. Missing control
acknowledgements close voice after a bounded deadline. End voice, closing the
panel, Pause, Stop and World teardown immediately terminate the local audio
host; process cleanup happens off the compositor owner.

The server performs speech-to-task handoff; displayed transcripts are not
submitted as duplicate tasks. Voice errors leave typed chat usable. There is no
audio metering timer or periodic helper polling, and no voice process when voice
is off. The control reader blocks on its pipe; startup and mute transitions use
the assistant worker's existing deadline-based wait.

`make test-assistant` covers the real framing/state machine with a synthetic
helper: negotiated device opening, mute/unmute, withheld acknowledgements,
captions, single handoff, stale messages, helper failure and teardown. The
opt-in check `ATAXIA_TEST_CODEX=1 sbcl --script tests/assistant-codex-voice.lisp`
connected the installed native host to the realtime service using ChatGPT
sign-in, with devices left closed. A physical microphone conversation is not
part of that check.

## World attachment

`ataxia-assistant` is independent of concrete Worlds. Load
`ataxia-assistant/metaworld` for Metaworld, or
`ataxia-assistant/infinite-world` for plain Infinite World. Both use the same
controller, panels, computer-use service, and preview implementation. Layout
tools appear only when the World provides a layout schema and transaction
adapter. See [World services](WORLD-SERVICES.md) to attach another implementation.

## Lifecycle and retention

The controller has separate connection, task and microphone state. Owner-thread
mutations are short; subprocess I/O, encoding and audio run in workers. Events
are bounded and stamped with controller/World identity. The Codex child starts
only on Send, Voice, or an explicit model-list connection. After 60 seconds
without a task, question, pending RPC or voice session, the worker closes its
stdio connection, lets Codex flush its conversation, and exits along with the
reader. The next submission starts a child and resumes the same persisted
thread, including its tool definitions and conversation context. An unused empty
thread is created anew because Codex does not persist it until its first turn.
Working-directory changes and recovery from an uncertain connection failure create a new
thread; physical actions are never replayed automatically.

Defaults are 30 minutes per human submission and 256 local tool calls per turn;
`*assistant-time-limit*` and `*assistant-tool-limit*` configure these limits in
`ataxia.assistant`. The panel displays them. `*assistant-idle-timeout*` controls
the child shutdown delay (seconds; NIL disables it). Idle UI schedules no
continuous frames; a focused text field can blink its caret. The worker waits on
a semaphore or the nearest actual deadline, with no periodic polling.

Ataxia keeps at most 40 messages in memory and renders a bounded transcript.
`$XDG_STATE_HOME/ataxia/assistant/operations.jsonl` (normally under
`~/.local/state`) records accepted/completed call identifiers and tool names,
with mode 0600 and a 1 MiB retention bound. It contains no prompts, audio,
transcripts, screenshots or credentials. Codex stores conversation rollouts in
its own configured state directory so idle shutdown can preserve full context;
Ataxia's 40-message display bound does not delete that Codex history.
Unknown outcomes are not replayed after reconnect; begin with a new observation.

On this development laptop, `make benchmark-idle` measured zero worker CPU time
and voluntary wakeups over five seconds. The isolated World measured zero
frames, zero allocated bytes, and 0.34 ms process CPU over five seconds, excluding
caret blinking and unrelated desktop activity. Codex 0.156.1 itself used CPU
while idle in a separate subprocess probe, which is why the child is released
after the grace period. After release there is no assistant worker, reader, or
Codex child left to poll. Active inference and voice are not idle workloads.

## Verification

Run from an environment with render-device access:

```sh
make test-assistant
make test-computer-use
make test-rmlui-shell test-rmlui-status-bar
make test-rmlui-shell-world test-rmlui-status-bar-world
# Uses the installed account and makes a real model request:
ATAXIA_TEST_CODEX=1 WLR_RENDERER=gles2 sbcl --noinform --disable-debugger \
  --eval '(sb-int:set-floating-point-modes :traps nil)' \
  --script tests/assistant-codex-world.lisp
# Exercises normal application closing through a real model in an isolated World:
ATAXIA_TEST_CODEX=1 WLR_RENDERER=gles2 sbcl --noinform --disable-debugger \
  --eval '(sb-int:set-floating-point-modes :traps nil)' \
  --script tests/assistant-close-codex-world.lisp
# Creates and exercises a separate notepad process/window in an empty project:
ATAXIA_TEST_CODEX=1 WLR_RENDERER=gles2 sbcl --noinform --disable-debugger \
  --eval '(sb-int:set-floating-point-modes :traps nil)' \
  --script tests/assistant-ui-codex-world.lisp
```

The deterministic suite covers protocol streaming, full-access protocol settings and question answers,
duplicate calls, stale epochs, native panel rendering at wide/narrow sizes, idle
rendering, preview input and update recovery, direct animated arrangements and failure rollback, synthetic
voice handoff/playback and cleanup, bounded live Lisp evaluation, and idle child
shutdown/resume. The real Codex test also verifies a shell write outside the working directory
without approvals, and that context and dynamic tools survive subprocess replacement. Window tests cover actual client closure,
minimize/restore across both tilers, canvas expansion, access to newly opened windows, stale IDs
and focus preservation. The real-model checks exercise registered native tools
in an isolated headless World, including UI creation from an empty project.
Notepad tests check multiline editing, scrolling, separate process/window IDs
and independent closure. They open no microphone.
