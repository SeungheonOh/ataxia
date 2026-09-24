# Direct World operations

From the Ataxia checkout, `scripts/ataxia-eval --world` evaluates on the active
World's owner thread, with lexical `world` and `kernel`. SLY normally listens
on localhost:4005; `--port` selects another compositor. The embedded assistant
uses `ataxia_lisp` with `mode:"inspect"` and lexical `world` for the same work.
It needs no external SLY listener. Pure World work allocates no input seat.

## Inspect only what matters

```sh
./scripts/ataxia-eval --world '(list
  :generation (ataxia.kernel:kernel-world-generation kernel)
  :world (type-of world)
  :outputs (mapcar (lambda (output)
    (list (ataxia.kernel:object-id output) (ataxia.kernel:output-name output)))
    (ataxia.world:world-outputs world))
  :windows (mapcar (lambda (window)
    (let ((app (ataxia.world:window-application window)))
      (list (ataxia.kernel:object-id app) (ataxia.kernel:application-title app)
            (ataxia.kernel:application-app-id app))))
    (ataxia.world:world-windows world)))'
```

Use `(ataxia.world:world-desktop-state world)` when placement, cameras or hidden
window state matters. It returns copied plists with `:windows` and `:outputs`,
plus World-specific layout data. Filter these before returning them if the task
concerns only a few objects. Do not fetch a full desktop or capture a monitor
after every action. Use a targeted app screenshot when appearance matters.

## Batch resolve, act and verify

Use observed IDs; the IDs below are placeholders. Resolve objects anew each call.
This pans only output 42 and returns its resulting camera:

```sh
./scripts/ataxia-eval --world --generation 7 '
  (when (ataxia.world:world-active-operation-p world)
    (error "A human is moving the layout"))
  (let ((output (or (find 42 (ataxia.world:world-outputs world)
                          :key (function ataxia.kernel:object-id))
                    (error "Output disappeared"))))
    (ataxia.world:navigate-world-viewport world output :pan :dx 400d0 :dy 0d0)
    (getf (find 42 (getf (ataxia.world:world-desktop-state world) :outputs)
               :key (lambda (entry) (getf entry :id))) :camera))'
```

`navigate-world-viewport` also accepts `:set` with `:x/:y/:zoom/:rotation`,
`:frame-window` with a stable `:window` ID, or `:frame-region` with
`:x/:y/:width/:height`. Use world units and radians; these operations preserve
other cameras, window placement and human focus. They do not restore hidden apps.

For window state, resolve `(ataxia.world:find-world-window world id)` and call
`(ataxia.world:control-world-window world window :restore output)`; other actions
are `:close`, `:minimize`, `:maximize`, `:fullscreen`. A close is asynchronous and
may open a save dialog. Verify later before reporting closure; do not wait inside
the owner operation.

For launch, get catalog IDs from
`(ataxia.world:world-application-catalog world output)`, then call
`(ataxia.world:launch-world-application world output id)`. Catalog IDs, window IDs
and app IDs are different. Verify the new window separately; never guess IDs or
launch repeatedly after an uncertain result.

For placement, check `(ataxia.world:world-supports-p world :layout)` and read
`(ataxia.world:world-layout-schema world)`. Pass a vector of string-keyed hash
tables matching that World's schema to `ataxia.world:apply-world-layout`.
This validates and applies the batch atomically; it retains no Undo history.
Check current targets/layout assumptions inside the same owner operation,
especially if a human has changed the World since discovery. A generation check
detects World replacement, not layout edits within the same World.

## Execution and lifetime

`--world` / `inspect` compile off-thread, then run and print values on the owner
thread for at most 250 ms. They add no full repaint; public World methods record
their own damage. Use `--apply` / `apply` for raw mutations that need a refresh.
These modes are execution choices, not access tiers. No kernel/runtime/native
changes are needed. Respect Pause/Stop; do not change transport to bypass them.

Use unflagged SLY evaluation or `ataxia_lisp` worker mode for reading/compiling
source, files or event waits. Never perform I/O, compile, sleep or wait for an app
on the owner thread. Never ASDF-reload a live World or redefine its classes from
a worker. Install prepared definitions briefly on the owner and follow the
World's drawable/interactable and UI-service protocols.

Errors and timeouts return without replacing the World. Arbitrary Lisp can make
partial changes before failing; inspect current state before deciding what to
do next, never blindly replay. Keep copied data and stable IDs, not live handles
across calls. The CLI supports stdin and `--file` to avoid shell quoting errors.

## Application contents

The portable `ataxia-agent` system supplies these functions on any desktop World.
Use **worker mode**, with lexical `agent`, and a stable application window ID:

| Function | Arguments after `agent window` |
| --- | --- |
| `ataxia.agent:capture-window` | optional `:settle` in seconds, default 0.05 |
| `ataxia.agent:click` | `x y`, optional `:button :left/:right/:middle` |
| `ataxia.agent:move-pointer` | `x y`, optional `:duration` in seconds |
| `ataxia.agent:button` | `:left/:right/:middle` and `:down/:up/:click` |
| `ataxia.agent:press-key` | XKB base key string, optional `:modifiers` list and `:state :tap/:down/:up` |
| `ataxia.agent:type-text` | string, up to 256 characters |
| `ataxia.agent:paste` | string, up to 16,000 characters; optional `:format :text/:md/:html` |
| `ataxia.agent:scroll` | `:x`/`:y` scroll deltas at the agent pointer |

Capture returns a plist with PNG `:path`, pixel and coordinate dimensions,
window ID and coordinate-space metadata. It renders that window and its popups
independently of occlusion, camera pan, zoom or rotation. The embedded tool emits
up to four captures per call in order; the CLI prints paths for the image-viewing
tool. In Codex code mode the embedded tool's image result is a string with data
URLs and JSON metadata, not an MCP content object. Emit each matched PNG URL with
`image(url)` and print only the remaining metadata. Reuse the existing result;
do not rerun an action because its image was not forwarded. Native input returns T and performs no automatic capture or inventory.

Use `"n" :modifiers '("Control_L")` for Ctrl+N, `"Return"` for Enter. For a drag,
move, press `:down`, move to the destination, release `:up`. Keep held input short;
errors and human takeover release it. Paste uses the agent clipboard and preserves
the user's clipboard. These operations preserve human focus and monitor cameras.

External SLY forms bind `agent` to the `--agent` name (default `SLY`). Choose a
separate stable name (up to 34 characters) for independent tasks. The embedded host binds its task
object instead. `ataxia.agent:disconnect` takes only `agent` and releases native
resources. A closed or paused name is not silently reconnected. Ordinary World
inspection needs no named input session.

This interface exposes compositor objects and native window input/capture. It
has no browser DOM or application accessibility-tree API. Browser windows can
be operated through their screenshots, keyboard commands and pointer input.
