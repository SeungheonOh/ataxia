# Desktop assistant

The optional `ataxia-assistant` system connects the native RmlUi panel to the
installed Codex app-server. Opening the panel starts neither Codex nor audio.

```sh
make assistant
ataxia --assistant
# Optional initial project directory:
ataxia --assistant-project /path/to/project
```

`ATAXIA_ASSISTANT=1` also enables startup. `--no-sly` keeps the internal owner
queue available without opening a SLY listener. Existing sessions can load the
system and call `(ataxia.assistant:enable world)` on the compositor owner thread.

| Control | Action |
| --- | --- |
| Super+A / Assistant in the bar | Open or focus the panel |
| Super+Shift+A / Voice | Toggle voice |
| Send | Authorize the displayed scope and submit a task |
| Send during a turn | Steer that turn |
| Model settings | Open the centered dialog for model, effort and Fast mode |
| Details | Show task activity, plan and limits |
| Pause / Resume | Release agent input immediately / continue after a human action |
| Stop | Interrupt the task and close its input session |
| Undo layout | Restore the last arrangement if the desktop still matches |
| Escape while the panel has focus | Close the panel and audio |
| Ctrl+Alt+Escape | Pause all computer-use sessions and assistant audio |

Closing the panel preserves a running text task. It restores prior application
focus when that application is still available. The bar shows actual task and
microphone state while the panel is closed.

The panel uses the light shell style: white surfaces, gray borders and blue
accents. **Model settings** opens a dialog centered on the current screen with
model, reasoning effort and Fast mode together. Changes save automatically;
Done, Escape or clicking outside returns to the chat without losing the draft.
Escape closes the settings dialog first, then the assistant on a second press.
Pause and Stop appear during a task; Undo remains available after a layout
change. Routine activity and limits are under Details. Scope stays in the header.

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

## Scope

Click the scope button to cycle through:

- **Desktop:** application interaction, window controls and the shared Metaworld canvas layout.
  A human Send grants the current windows for layout changes. Layout plans validate
  all operations, reject intervening changes and active drags, apply once, and
  support conflict-checked Undo. Application titles and presentation animations
  do not count as layout edits. `remove-group` deletes a sub-world and moves its
  remaining windows and widgets onto the canvas. Its deletion can be undone;
  standalone worlds keep their only sub-world. Layout operations keep client windows open.
- **Selected app:** native input and window controls are limited to the window focused before opening
  the panel. The assistant cannot launch or switch to another application.
- **Project:** Codex may edit the chosen directory using its workspace-write
  sandbox. Native input and window controls are limited to previews created by this assistant.

`ataxia_window` controls a window by its stable ID: `close`, `minimize`, `restore`,
`maximize`, or `fullscreen`. Closing sends a normal application close request;
the assistant checks afterward for closure or a save dialog. It does not force-kill
the application, and closing has no Undo. A window is one application toplevel;
closing every window of an app requires selecting each matching window.
Snapshots include minimized windows and window state. Minimize persists across
layout updates; Restore unminimizes and exits expanded presentation. The launcher
can also unminimize a window. Maximize and fullscreen fill the containing sub-world
for grouped windows, or the output for canvas windows. Window controls invalidate
earlier layout plans and Undo. They do not move the human's focus to another app.

Command, file and permission requests required by Codex appear inline. Questions
support supplied choices and typed answers. Sign in opens the app-server's browser
flow; Retry rechecks account state. Credentials are managed by Codex.

## Response formatting

Assistant messages render paragraphs, Markdown headings, bold/italic text,
numbered and bulleted lists, checkboxes, inline/fenced code, quotes and simple
pipe tables. User messages have a separate background. Links show their labels
and addresses; they do not open automatically. Raw HTML remains literal text.
Formatting also works as a response streams in, with bounded message rendering.

## RmlUi apps

The assistant receives a built-in [UI authoring guide](../src/world/assistant/instructions.md)
on every new thread, together with its actual scope and project path. It covers
creating, opening, testing and updating custom UI, light styling, native form
controls, supported callbacks and storage limitations. Choose **Project** in the
header, enter a directory, then ask, for example, "Create a simple notepad and
open it." Every new UI opens as a separate Wayland window in its own dedicated
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
Project assets are restricted to that directory, with a fixed system-font
fallback. Up to four preview clients may be open. Stop preserves previews;
disabling the assistant or replacing its World closes them. Installing a preview
as a persistent compositor widget is a separate development action.

## Voice

The adapter targets **Codex CLI 0.153.4**, experimental realtime v2 over its
websocket transport. It uses `pw-record` / `pw-play`, PCM16 mono at 24 kHz, and
starts microphone capture only after the service confirms negotiation. The
server performs speech-to-task handoff; displayed transcripts are not submitted
as duplicate tasks. Talking during a task first pauses native input.

On this installation, ChatGPT sign-in works for typed tasks, but realtime returns
`realtime conversation requires API key auth`. Configure API-key authentication
locally for the Codex child, or supply `OPENAI_API_KEY` in the compositor's launch
environment, to use that service. The panel reports unavailability and keeps text
usable. It does not substitute another audio provider. Synthetic input/output and
all tested shutdown paths pass; a physical microphone conversation remains
unverified with the current credentials.

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
are bounded and stamped with controller/World identity. Reconnecting creates a
fresh ephemeral Codex thread and never replays physical actions automatically.

Defaults are 30 minutes per human submission and 256 local tool calls per turn;
`*assistant-time-limit*` and `*assistant-tool-limit*` configure these limits in
`ataxia.assistant`. The panel displays them. Idle UI schedules no continuous
frames; a focused text field can blink its caret.

Ataxia keeps at most 40 messages in memory and renders a bounded transcript.
`$XDG_STATE_HOME/ataxia/assistant/operations.jsonl` (normally under
`~/.local/state`) records accepted/completed call identifiers and tool names,
with mode 0600 and a 1 MiB retention bound. It contains no prompts, audio,
transcripts, screenshots or credentials. Codex manages its own process logging.
Unknown outcomes are not replayed after reconnect; begin with a new observation.

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

The deterministic suite covers protocol streaming, explicit approvals and answers,
duplicate calls, stale epochs, native panel rendering at wide/narrow sizes, idle
rendering, preview input and update recovery, animated layout Undo, synthetic
voice handoff/playback and cleanup. Window tests cover actual client closure,
minimize/restore across both tilers, canvas expansion, scope checks, stale IDs
and focus preservation. The real-model checks exercise registered native tools
in an isolated headless World, including UI creation from an empty project.
Notepad tests check multiline editing, scrolling, separate process/window IDs
and independent closure. They open no microphone.
