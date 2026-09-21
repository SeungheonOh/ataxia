# Computer-use ownership and design

CUA is an optional World service. Kernel and Runtime must work without loading
it, and loading the service must not enable it on a World. Each World supplies
its own desktop and capture behavior, then explicitly enables the shared host.

## Dependency direction

```text
JavaScript client / MCP (sdk/computer-use)
                    │ local socket
                    ▼
World-owned CUA service (ataxia-computer-use)
                    │ desktop / capture protocols
                    ▼
Concrete World adapter and renderer (src/worlds/<world>)
                    │ stable objects / protocol delivery / frame leases
                    ▼
Kernel → Runtime → wlroots
```

The service also uses ordinary Kernel/Runtime primitives for seats, input,
timers, and owner-thread dispatch. Neither lower layer depends on the service,
the JavaScript SDK, an assistant, or a concrete World.

| Owner | Responsibilities |
| --- | --- |
| `sdk/computer-use/` | Client transport, observation caches, JavaScript API, AT-SPI and browser adapters, REPL/MCP process lifetime. |
| `src/world/computer-use/` | Sessions, input routing, pause/expiry, request validation, captures, UI, native client/clipboard queries, desktop transactions, local listener. |
| `src/world/synthetic-input/` | Optional native device allocation, emission, and destruction, shared with World input fixtures. |
| `src/worlds/infinite/` | Window eligibility, coordinates, focus policy, and capture through its renderer. |
| `src/worlds/metaworld/` | Groups, columns, floating placement, workspace limits, layout validation, restoration, and navigation. |
| Kernel / Runtime | Stable identities, caller-owned device adoption and registration, Wayland events, object lifetime, and frame accounting. No CUA state or commands. |

Optional modules define symbols in their own packages. Loading one must not add
CUA functions or state to `ataxia.kernel`, `ataxia.runtime`, or
`ataxia.runtime.raw`. Native helper sources belong beside their World module;
their shared libraries are built by `make computer-use`, not required by the
base Kernel/Runtime systems.

## Per-World integration

`ataxia-computer-use` is reusable host code. It does not load a concrete World.
The entry points are `ataxia-computer-use/infinite-world` and
`ataxia-computer-use/metaworld`. Metaworld deliberately reuses Infinite World's
capture implementation and supplies its own layout and navigation methods.

For another World, implement the desktop/UI protocols documented in
[WORLD-SERVICES.md](WORLD-SERVICES.md), provide `capture-window-pixels`, and
advertise only implemented capabilities. Put renderer-specific code under that
World, optionally in an ASDF integration system. Its entry point loads that
system and calls `ataxia.computer-use:enable` on the owner thread.

Enable requires `:ui`, `:desktop`, and `:window-capture` before allocating any
resources. Layout and navigation remain optional. A library load never opens a
listener, creates an agent seat, or attaches a controller. The shared service
uses opaque window handles and calls World methods; it never reads Metaworld
scene structures. World quiescence closes sessions and detaches the service.

Layout operations and their JSON schema come from the World. The portable
service checks transport size and scalar data; the World validates the meaning
of the entire plan before mutation. Metaworld adds workspace/column/floating
metadata to its own snapshots. `navigate-world-viewport` owns camera validation, region fitting and output-specific view policy; it requires no human seat on the target monitor. The portable service has no nine-workspace
limit or group-membership assumptions.

The JavaScript `arrange` API carries any advertised layout operation. Its
`moveWindow` and `setFloating` helpers construct `place-window` operations and
require that schema. They are conveniences for compatible Worlds, not a
universal window-manager implementation. Camera navigation is a separate `:viewport-navigation` capability, implemented by plain Infinite World as well as Metaworld.
The client cannot enable missing host capabilities.

## Generic lower-layer mechanisms retained

These mechanisms are useful independently of CUA and contain no agent policy:

- Runtime's `adopt-input-device` installs its normal native listeners without
  taking ownership of allocation or announcing a backend device. The optional
  World provider owns destruction.
- Kernel's `register-input-device` uses the same registration path as backend
  input and accepts the intended logical seat. Registering first on the human
  seat and reassigning afterward would disturb its keyboard and keymap.
- Kernel's `complete-wayland-surface-frame` validates an opaque live surface
  token and completes callbacks for offscreen consumers. The World decides
  which captures may use it. Completion does not claim display presentation.
- Pointer-grab routing, seat-local clipboard delivery, popup geometry, and
  surface damage are Wayland mechanisms applying equally to human and agent
  seats. Their correctness belongs below World policy.

CUA-specific client resource queries formerly exposed by Kernel, and optional
CUA bindings formerly defined in Runtime, now belong to the World service.
Synthetic device creation is also an optional World module.

## Session and transaction decisions

Each session owns its separate seat, input state, selected view, desktop
revision, pending plans, and Undo. Desktop state is stored directly in the session structure. Close releases it with the rest of the session.

World observations are structured inventories, not monitor captures. Worlds report
window availability and viewport intersections alongside their own placement data.
The portable CUA transaction layer passes those fields through without requiring
native window handles from hosts that only provide layout snapshots. Window-mode
discovery spans all mapped applications; World visibility policy still controls
input eligibility. An offscreen window does not need to be selected while visible
first. The session output anchors viewport capture, not the scope of window-local content access. Each navigation command names its target output explicitly. No change to these rules adds Kernel/Runtime CUA APIs.

Desktop actions use the same sequence, pause, expiry, and busy checks as native
input. They call explicit World methods; synthetic key input remains application
input and cannot accidentally invoke desktop shortcuts. Navigation intentionally
changes the human view on the session's selected output.

A layout preview validates the complete plan without applying it. Apply checks
the observed revision again, captures World restoration state, and rolls back
on a synchronous application failure. Plans and Undo are session-owned,
single-use, and expire after two minutes. Window controls clear retained layout
plans and Undo. These are arrangement transactions; they cannot undo client
side effects or resurrect a closed application. Ordinary input batches are
sequential and may have partially completed when a later action fails.

Revision comparison excludes titles and transient visibility so an animating
application does not continually invalidate a plan. A World should report
intended layout geometry, not interpolated animation positions. Clients retain
the last observed revision and must refresh after a conflict; they do not
silently rebase a stale action.

## Maintenance and deployment

CUA is unreleased. Design changes replace the implementation directly; do not
add protocol generations, migration scripts, or parallel historical code paths.
Changes to session structures and native module ownership are tested in fresh
processes and take effect after a normal compositor restart. Do not hot-reload
them into a desktop with old live objects or replace loaded native libraries.

`make test-computer-use` includes fresh-process dependency checks and an
unrelated World with its own layout operation and workspace 42. It also tests
real Wayland input, capture, clipboard isolation, concurrent sessions, and
teardown. `make test-cua` exercises the JavaScript/GTK/MCP/browser path and
Metaworld preview, rollback, Undo, conflicts, and navigation. `make test-portability`
checks opaque World handles and the assistant on plain Infinite World.
