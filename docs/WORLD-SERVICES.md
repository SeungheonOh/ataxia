# Attaching UI and assistant services to a World

The assistant, computer-use service, and RmlUi shell depend on `ataxia.world`
protocols. They do not depend on a concrete World's package or scene structures.
A World supplies placement, visibility, focus, rendering, and optional layout
policy. The services own their controllers, widgets, input state, timers, and
workers. These boundaries are checked in fresh Lisp processes.

## Systems and ownership

| System | Provides | Concrete World dependency |
| --- | --- | --- |
| `ataxia-world` | UI hosting, desktop protocols, optional service dispatch, shared geometry and scheduling helpers | None |
| `ataxia-slint` | Slint components, widgets and notifications | None |
| `ataxia-rmlui` | RmlUi components, widgets and cached property updates | None |
| `ataxia-rmlui/status-bar` | Status bar, application menu and power panel | None |
| `ataxia-world/synthetic-input` | Optional World-owned native input devices | None |
| `ataxia-computer-use` | Sessions, native input, capture coordination, batches and socket API | None |
| `ataxia-assistant` | Assistant worker, tools, approvals, previews, voice and panels | None |
| `ataxia-computer-use/infinite-world` | Window capture using Infinite World's renderer | Infinite World |
| `ataxia-computer-use/metaworld` | Shared capture with Metaworld layout and navigation | Metaworld |
| `ataxia-assistant/infinite-world` | Assistant plus that capture backend | Infinite World |
| `ataxia-assistant/metaworld` | Assistant plus Metaworld's navigation and layout policy | Metaworld |

The service implementation packages are `ataxia.assistant`,
`ataxia.computer-use`, and `ataxia.world.shell`. Layout-specific methods live in
`src/worlds/metaworld/desktop*.lisp`; they have no assistant or computer-use
dependency. Infinite World's adapter lives in `src/worlds/infinite/desktop.lisp`
and its optional renderer adapter in `capture.lisp`.

World-specific chrome, such as Metaworld group controls, remains beside its
policy. Its widgets use the same shared UI component and overlay contracts.
Avoid putting generic service state into a World's package or adding aliases
for another module's private controller functions.

The Slint native crate builds without World assets by default. The desktop
Makefile enables its optional `metaworld-controls` feature, compiling the
controls from `src/worlds/metaworld/native/`. That extension owns the compiled
components and their property/callback mappings. Dynamic Slint widgets and
notifications remain available in either build. To build just the engine:

```sh
cargo build --locked --release --manifest-path src/world/slint/native/Cargo.toml
```

Use `ATAXIA_SLINT_NATIVE` to select that library when attaching another World.

## UI hosting

Use the `ataxia.world:ui-host` mixin before `ataxia.kernel:world` in the class's
superclass list for widget IDs and the agent event stream. The mixin closes its
stream on detachment, waking external agents so they can resolve the new World.
Implement the hosting protocol in `src/world/overlays.lisp`:

- `world-outputs` returns connected Kernel outputs, in stable order.
- `world-overlays` and its setter expose attached `ui-overlay` instances.
- `add-overlay`, `remove-overlay`, `show-overlay`, and `hide-overlay` manage
  scene and input membership. Removing an overlay must call `destroy-overlay`
  when graphics retirement is safe. Hiding or removing focused UI must release
  its input references and restore the displaced application focus.
- `damage-overlay` invalidates its current coverage. Geometry changes damage
  both old and new coverage.
- `request-overlay-update` schedules a frame or component deadline. It must
  stop scheduling after the World begins quiescing.

Overlay geometry is output-local, in logical pixels. The component implements
the engine-neutral `ui-*` protocol plus Kernel drawable/interactable contracts.
The host owns compositing, hit testing, raster density, and graphics lifetime.
Pass an explicit `:component-factory` to `create-agent-widget`, or use
`ataxia.world.rmlui:make-rmlui-widget` or
`ataxia.world.slint:make-agent-widget`.

`tests/world-ui-host.lisp` is a small independent host exercising geometry,
invalidation, bounded callback events, and disposal. It loads no concrete World
or UI engine.

## Desktop operations

The desktop protocol is documented at each generic function in
`src/world/desktop.lisp`. Window handles are opaque to services: a World may use
bindings, structs, or its own classes. `window-application` maps a handle to the
stable Kernel application and returns `nil` for non-window targets.

| Responsibility | Operations |
| --- | --- |
| Windows | `world-windows`, `world-window-visible-p`, `window-application` |
| Coordinates and picking | `window-output-bounds`, `window-local-to-output`, `output-to-window-local`, `world-target-at` |
| Human focus | `world-seats`, `world-seat-output`, `world-seat-focus`, `world-seat-previous-focus`, `focus-world-target`, `world-pointer-position` |
| Agent cursor | `present-agent-cursor` |
| Capture | `request-world-capture`, `capture-window-pixels` |
| Window controls | `control-world-window`, `world-active-operation-p` |
| Optional launcher | `world-application-catalog`, `launch-world-application` |
| Optional navigation | `world-shell-state`, `world-shell-action`, `navigate-world-desktop` |

`world-output-work-area` returns output-local logical x, y, width and height.
Attached services reserve edges through `service-output-insets` (left, top, right,
bottom); overlapping reservations use the maximum on each edge. Call
`world-output-work-area-changed` after adding or removing a reservation so the
World can refit its active layout. Fullscreen remains a separate policy.

`navigate-world-desktop` validates data-only navigation requests before mutation.
The concrete World chooses valid destinations, workspace limits, and the human
seat on the selected output. Shared CUA code does not interpret those rules.

`world-shell-state` supplies the existing workspace entries for each group,
including empty pages, with `:removable` flags on groups and workspaces. The shell
sends `:remove-workspace` with `(group-id number)` or `:remove-subworld` with a group
ID; the World rechecks those constraints before changing its layout.

`world-windows` includes mapped, minimized windows. Visibility checks must reject
stale handles and non-window targets. Application coordinates include the
application's local bounds; output coordinates include the World's placement,
view scale, and rotation. Keep these transformations in the adapter.

Computer-use sessions own their pointer coordinates, pressed buttons, grabs,
and selected application. They do not borrow the World's private human-seat
state. The host's normal focus path must honor `seat-focus-allowed-p` and
`seat-raises-focused-window-p`: unrelated mapping or layout changes must not
redirect agent input. Use `agent-seat-p` when distinguishing human input.

`present-agent-cursor` invalidates both old and new coverage. A `nil` tint removes
the customization; offscreen coordinates hide its presentation. Kernel retains
ownership of the actual seat, keyboard, pointer, and protocol delivery.

Window capture runs during a Kernel frame lease. The renderer adapter fills
the supplied RGBA buffer with only the application's surfaces, including
popups, and restores every graphics state it changes. The service owns bounded
allocation, frame priming, cancellation, output transforms, PNG encoding, and
temporary-file cleanup. Keep rendering details out of the session and API code.

## Capabilities and layout

Loading a service or a World adapter never enables a controller. The World entry
point explicitly loads its integration system and calls `enable` on the owner
thread. Metaworld consumes the shared CUA service through
`ataxia-computer-use/metaworld` and deliberately reuses Infinite World capture.
Other Worlds must provide their own desktop and capture methods before enabling
the service; unsupported Worlds fail before allocating resources. See the
[CUA design](COMPUTER-USE-DESIGN.md).

Advertise implemented capabilities through `world-supports-p`. The shell needs
`:ui` and `:desktop`; computer use and the assistant also need `:window-capture`.
Enable fails immediately when required capabilities are absent. `:launcher`,
`:shell-navigation`, and `:layout` are optional.

`world-desktop-state` has a generic window/output observation. Override it for
additional state such as groups, workspaces, or cameras. Return copied data with
stable application IDs. Metaworld reports target geometry while animations run,
so cosmetic motion does not invalidate transactions.

A layout-capable World provides `world-layout-schema`, `validate-world-layout`,
`capture-world-layout`, `apply-world-layout`, and `restore-world-layout`. The
schema and its description define that World's operations. Validation must
check **every affected window** against the supplied allowed IDs, including
windows indirectly affected by a group operation.

The assistant owns task grants, revision checks, plan expiration, rollback, and
Undo tokens. The World owns operation validation and layout mutations. Worlds
without this capability receive ordinary desktop tools and no layout tools.

## Composing services

Use `attach-world-service`, `world-service`, and `detach-world-service`. A service
key has one owner per World. This registry is also the controller lookup; each
service keeps its state on that controller. Implement the relevant `service-*` generics on the
controller's type. Shared dispatch delivers output/object/seat lifecycle,
render, and input events; services do not install competing methods with the
same Kernel specializers.

Callbacks run on the compositor owner thread. Render callbacks run within the
frame lease. Input callbacks precede World policy; a true `service-key-event`
result consumes that event. Agent input has its own routing and bypasses human
shortcuts. The assistant owns a separate shortcut controller, including held-key
tracking, so it does not require access to the World's shortcut bindings.

On quiescence, stop workers and timers and detach the service. Dispatch uses a
snapshot, so a callback can detach itself without skipping another service.
Keep callbacks short. Use the existing owner queue for worker requests; only
the worker may wait for capture, input completion, subprocesses, or audio.

Initialization must undo partially created resources if it fails. The assistant
and computer-use `service.lisp` modules show this pattern: startup registers the
controller before creating callbacks, and failure removes its timers and UI.
The assistant rolls back a newly created computer-use dependency on failure;
an already enabled input service remains available to its existing callers.

The in-process computer-use API is exported from `packages.lisp`.
`request-on-owner` performs a validated request on the owner thread;
`finish-request` waits for an asynchronous result on a worker. Connection activates the session automatically. `activate-session` also resumes
a paused session from the human UI; socket requests cannot resume it.

## Verification

Run `make test-portability` for an unrelated desktop host and a real headless
Infinite World with the assistant, shell, native session, mock tool call, idle
rendering, and cleanup. `make test-assistant` includes these checks. The ordinary
`make test`, `make test-computer-use`, and shell tests cover existing behavior.

`tests/portable-desktop-host.lisp` demonstrates opaque handles and a different
coordinate mapping without loading any concrete World. Its only native stub is
the client input-resource query. Real input and graphics remain covered by the
Wayland integration suites.

Existing public assistant and computer-use entry points retain their names.
Load the matching adapter system before enabling them on Infinite World or
Metaworld. Shell entry points now live in `ataxia.world.shell`; the optional
`ataxia-rmlui/status-bar/infinite-world` system retains the former exported
Infinite World names. Existing `canvas-overlay` names remain compatibility
aliases; new code uses `ui-overlay` and `overlay-*`.

This refactor changes implementation packages and controller/class layouts.
Start a new compositor process to use it in an existing session. Do not redefine
these structures underneath active workers or native UI objects.
