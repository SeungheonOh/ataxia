# Metaworld

Metaworld is an infinite canvas containing movable, single-level window groups.
Each group owns either a scrolling-column layout inspired by Niri or a dynamic
tiling layout inspired by Hyprland. Groups contain real application windows and
spatial Slint widgets, not screenshots or nested compositor instances. Unowned
windows and notes remain ordinary canvas objects. Groups cannot contain groups.

Niri workspaces are full-size pages stacked vertically. Each page has its own
columns, stacked windows, horizontal scroll position, and remembered focus.
Changing workspaces slides the camera to the page above or below. Empty pages
that have been visited remain in the layout; up to nine pages are supported.
The canvas overview includes all allocated pages.

## Run

Build the native libraries with `make`, using the same wlroots, Slint, and Lisp
dependencies as the existing infinite world. Launch on Linux:

```sh
sbcl --script scripts/run-metaworld.lisp
sbcl --script scripts/run-metaworld.lisp --world niri
sbcl --script scripts/run-metaworld.lisp --world hyprland
```

The standalone modes use the same layout implementation without visible group
boundaries or a containing canvas. Switching modes through the attached controls
replaces the World while retaining live Wayland clients. All live clients become
available to the standalone layout; this is not a second compositor process.
The Canvas action returns to the saved metaworld arrangement.

`--state-file PATH` selects a layout file, retained when returning from another
mode. `--no-persist` disables persistence,
including subsequent mode switches. The existing backend, debug, and SLY options
are also supported; use `--help` to list them. Terminal creation requires `foot`.

## Interaction

- Click a group title to enter; click the active title again to leave. Drag the
  title to move the group and all of its objects, including inactive workspaces.
- Hover a title to reveal its entry and context actions. Right-click empty
  canvas to create a group or a note; right-click a group to edit its layout.
- Hover near the top center for 350 ms to reveal navigation, workspace, and
  terminal actions. Navigation itself never opens the toolbar; it fades away
  after the pointer leaves.
- Drag a window by its title, or hold Super and drag anywhere in the window.
  Drop inside a group to join it, outside all groups to detach, or inside another
  group to transfer ownership. Group boundaries indicate the current drop target.
- Drop in the central top or bottom quarter of a Niri tile to stack above or
  below it. Hold Control to stack anywhere over a tile, using its upper/lower
  half to choose the insertion side. Side and center drops create a separate
  column. Drop onto another workspace page to move the window to that page.
- Hold Super and drag empty space inside a group to move it. Super + right-drag
  on empty group space resizes the group; on a window, it resizes the window.
- Hover the focused window's upper-right corner for 450 ms to reveal a small
  icon bar with direct window actions. Hover or focus an icon for its label.
  Click outside or press Escape to dismiss. Notes can be dragged by their upper edge and reveal their
  close control on hover.
- Super + wheel zooms around the pointer. Middle-drag pans the canvas.
  Shift + wheel scrolls the active Niri layout horizontally.

The visual treatment is light monochrome: neutral paper, unobtrusive cross
reticles, unboxed group names, and short screen-space dot–dash–dot boundaries.
Reticle density blends across zoom levels rather than accumulating into a dense
texture. Camera navigation and window rearrangement use short eased transitions.

## Keyboard

Super is the Logo/Windows key (Command when captured by UTM).

| Shortcut | Action |
| --- | --- |
| Super + E | Enter the group under the pointer, or the focused object's group |
| Super + Page Up / Page Down | Enter the previous / next group |
| Super + M / Escape | Leave; in the canvas, fit all objects; standalone: overview |
| Super + comma | Open or dismiss contextual controls |
| Escape | Dismiss an open context or window action menu |
| Super + Return | Create a terminal in the current group or the parent canvas |
| Super + Shift + Return | Create a terminal below the focused Niri tile |
| Super + Alt + Up / Down | Slide to the previous / next workspace page |
| Super + arrows | Focus a neighboring object |
| Super + Shift + arrows | Reorder a tile or Niri column; move a floating window |
| Super + Control + arrows | Resize a tile, stack weight, floating window, or split ratio |
| Super + Tab | Cycle through the current group's objects |
| Super + [ / ] | Stack into an adjacent Niri column / split out |
| Super + F | Toggle group-local fullscreen |
| Super + V | Toggle floating |
| Super + 1–9 | Switch workspace |
| Super + Shift + 1–9 | Move the focused object to a workspace and follow it |
| Super + Shift + E | Detach the focused object and reveal it on the canvas |
| Super + Q | Close the focused window or note |
| Super + Space | Open the existing application launcher |
| Super + Control + Shift, held | Mouse-directed viewport shifting |

Context controls support Tab, Shift+Tab, Return, and Space. Ungrouping requests
confirmation and releases the group's objects without closing applications.

## Persistence

Default files are `$XDG_STATE_HOME/ataxia/metaworld.sexp`, `niri.sexp`, and
`hyprland.sexp`, falling back to `~/.local/state/ataxia/`. Changes are saved through
atomic replacement. Unreadable state is preserved rather than overwritten.

Saved state includes group placement and policy, workspaces, column order and
widths, stack weights, floating geometry, output cameras, and note contents.
Live World switches match the Kernel's stable application identity within the
current compositor session. After a compositor restart, applications are matched
by application ID and title, with application-ID fallback. Saving a layout does not relaunch external applications after the
compositor exits. Identical application IDs and titles cannot uniquely identify
multiple restarted clients. Arbitrary agent-created Slint programs are not
serialized; built-in notes are.

## World-side API

Load `ataxia-metaworld` and use the `ataxia.metaworld` package:

- `make-metaworld`, `make-niri-world`, `make-hyprland-world`
- `create-subworld`, `metaworld-subworlds`, `move-subworld`, `remove-subworld`
- `enter-subworld`, `leave-subworld`
- `move-object-to-subworld`, `object-subworld`, `save-metaworld`

Pass `nil` as the destination to detach an object. Membership accepts live
canvas windows and agent widgets, but rejects internal controls, foreign
objects, and group nesting. `move-subworld` updates owned objects together with
the group's position. Use these operations on the compositor owner thread;
external agents should follow the guarded workflow in `AGENT_OPERATIONS.md`.

The implementation subclasses the infinite World and uses its camera, rendering,
input, and Slint facilities. It adds no Kernel or Runtime modifications. Two
small infinite-world rendering hooks select the background shader and draw group
boundaries. The shared Slint key bridge normalizes special keys before UTF-8
fallback, and native library installation uses atomic replacement for live use.
IMU viewport control and its status UI have been removed.

## Performance and validation

State snapshots are copied on the owner thread and sent to a single writer
thread. Pending saves coalesce by path; disk writes and atomic replacement do
not run in the event loop. World switches can restore the newest queued snapshot
without waiting for disk. `save-metaworld` queues work asynchronously; the
standalone launcher drains final saves after the Kernel stops.

Terminal launches use a separate bounded worker queue. Unique application IDs
associate arriving terminals with the requested group, workspace and optional
stack target, even when clients map out of order. Workers never access live
World, Wayland, Slint or GLES objects.

Border geometry uses a bounded cache with packed float buffers. Offscreen
workspace pages do not submit background draws. Layout skips unchanged window
geometry, and packed vertex buffers avoid per-frame float conversion.

Run the regression checks with:

```sh
sbcl --script tests/metaworld-performance.lisp
```

They cover a stalled state writer, save coalescing and snapshot isolation,
persistence, transformed border geometry, packed quad coordinates, Niri drop
zones and stacking, full-height workspace pages and camera placement. The local
Linux headless launcher and the nested Wayland session are also used for smoke
checks. Render timing measures compositor render calls, not end-to-end physical
pointer latency.

The six built-in Slint controls compile during the native library build, so
hover menus and toolbar creation do not compile Slint source on the event loop.
Each control has its own keyboard state backed by a shared immutable keymap.
Custom agent widgets still use the interpreter. UI synchronization runs after
animation sampling once per output frame, and rendering computes object bounds
once for all damage rectangles in that frame.

Validate the built-in property/callback interfaces and custom-widget fallback:

```sh
sbcl --script tests/slint-builtins.lisp
```

## Motion and direct manipulation

Layout changes animate the displayed rectangle toward a separate destination.
Repeated layout passes retain the current motion; changed destinations start at
the displayed position and retain compatible velocity. Position and size settle
together over 220 ms. Client resize requests use the final size once per target,
while the compositor scales the latest buffer during the transition.

Dragging keeps the grabbed object attached to the pointer and reflows neighboring
tiles into the insertion preview. A 12-pixel pointer threshold stabilizes preview
changes; releasing settles into the last shown preview. Grab feedback changes the
shadow elevation without scaling the window around its center. Moving a whole
group translates its children’s in-flight animation paths along with the group.
Camera transitions
also retarget continuously and yield immediately to dragging, panning, scrolling,
and direct view manipulation.

Run `sbcl --script tests/metaworld-motion.lisp` for deterministic checks covering
retargeting, repeated layout passes, resize configuration counts, drag reflow,
release continuity, camera interruption, and bounded interpolation.

Niri column identity is scoped by workspace. Keyboard resize, drag resize,
stacking and column reordering preserve other workspaces' widths and ordering,
even when persisted layouts reuse column numbers. Drop planning batches layout
changes before configuring clients; directional navigation uses destination
rectangles so repeated keys remain predictable during animations.

## UI raster quality

Slint overlays choose their render density from their displayed dimensions and
output scale, including camera zoom and fractional display scaling. They target
2x supersampling per displayed pixel, with half-octave allocation buckets and
shrink hysteresis to avoid reallocating textures on every animation frame.
Allocations respect the GPU texture dimension limit and a 16-megapixel budget per
component. Fixed Metaworld controls align to physical pixels. Changing raster
density preserves logical layout and input coordinates, and redundant component
resizes are skipped. Application buffers continue to be supplied by their clients.

The motion regression suite also covers cross-workspace column isolation,
coalesced layout configurations, raster density, fractional output scale,
allocation stability and texture limits.

## Quiet controls

Controls use a shared sans-serif typeface, restrained borders, compact spacing,
and soft hover/selection feedback. Group names remain lightweight canvas labels.
Chrome is created hidden and fades in over 160 ms and out over 120 ms; reversing
a fade continues from its displayed opacity. Dismissed chrome stops taking input
immediately, even while its last pixels fade out. Context menus anchor to the
click location. Explicit menus suppress the automatic toolbar and window hint.
Dragging and camera transitions suppress hover-triggered controls.

`tests/metaworld-chrome.lisp` checks dwell thresholds, compact defaults, direct icon actions, interrupted fades and input behavior during dismissal.

The native bridge resolves each Slint function through its library handle. This
avoids SBCL's global foreign-symbol lookup mixing native versions during a live
UI replacement. Existing components must be destroyed before switching handles;
old libraries remain mapped for their thread-local destructors.

Idle maintenance uses one-shot deadlines for hover dwell, control dismissal and
pending state saves. With no pending work its Wayland timer is disarmed; holding
the pointer over controls or leaving an explicit menu open does not poll the UI.
Input and render events update intent and rearm deadlines as needed. Slint's
component timer is also disarmed when no visible component needs a timer or
animation update. Background save and launch workers block on semaphores.
`tests/metaworld-idle.lisp` covers idle disarming and the deadlines that resume work.
The main runtime flushes client messages before blocking in Wayland dispatch;
input, client sockets, the control pipe and deadline timers wake it directly.
It does not use a periodic timeout to check for work.

Subworld entry and exit interpolate camera translation in screen space together
with scale, using one 280 ms easing curve. World points follow straight screen
paths during unrotated zooms instead of bowing sideways; interrupted transitions
restart from the displayed camera. Rotation takes the shortest arc.

Window shadows use a Gaussian rectangle integral evaluated at output resolution,
with continuous falloff around edges and corners. Elevation changes softness and
offset; window opacity also fades its shadow. Each shadow needs one draw call,
with no low-resolution blur texture or stacked rectangular bands. The shader is
owned and released with the canvas renderer, and its support fits within the
existing window damage bounds.

## Subworld framing and navigation

Entering a subworld fits its dotted page to the viewport without added outer
margins. The aspect ratio stays intact; any remaining letterboxing comes only
from a mismatch between the page and display proportions. The active page has its plain-text title and a small
back arrow at the top left, with no bar or background behind the title. Click it, or use Super+Escape,
to restore the exact overview camera from before entry. In standalone mode the
breadcrumb switches to Metaworld. The breadcrumb yields to the temporary toolbar
so they do not overlap on smaller displays. Overview headers enter their group
and have no ellipsis affordance.

Tiled content uses 16 world units on the left, right and bottom, a 52-unit top
inset for navigation, and 14-unit gaps. Maximized subworld windows use the same
content bounds. Niri page width includes both outer insets and only the gaps
between columns. Focus scrolling preserves those insets and clamps to the
available content, including after manual zoom; stale empty-page scrolls are
clamped on entry.

Weighted stacks reserve minimum window sizes before distributing remaining
space. Dwindle and master splits reserve enough room for their remaining tiles.
Crowded stack or split regions use a compact grid when needed instead of letting
minimum-size clamping create overlaps. Context panels fit within the output, and
the toolbar uses narrower controls on small displays. Escape and direct window
actions suppress hover reopening until the pointer moves.

`tests/metaworld-layout-qa.lisp` checks 1–12 windows across three sizes and three
split ratios, skewed stack weights, page fit on portrait/ultrawide/fractional-scale
outputs, Niri scroll bounds and exact overview-camera restoration. See
[the QA record](METAWORLD-QA.md) for the validation scope.

Subworld titles are canvas decorations: application windows paint over them and
receive input ahead of any covered title. Exposed titles remain clickable.
Overview titles have no hover icon; the active title retains its small back arrow.
`tests/metaworld-title-layer.lisp` verifies draw order and pointer targeting.

Subworlds keep their full footprints separate, including every Niri workspace
page. Dragging a title pushes neighboring groups aside with a short easing
animation; pushes propagate through crowded groups. A 96-unit soft gap starts
the motion before contact, and a 40-unit minimum gap prevents overlap during
fast drags while leaving room for titles. Creating or enlarging a group also
makes room automatically. Windows and floating restore positions move with
their group. Existing overlapping layouts separate when first displayed.
`tests/metaworld-packing.lisp` checks dense layouts, chained pushes, rapid
retargeting, frame-by-frame separation, page growth, and carried window geometry.

Zoomed-out windows use an adaptive area filter to suppress sparkling text and
moire patterns. The sample footprint follows physical display pixels, including
fractional output scales, buffer crops and rotations. Filtering fades away at
1:1 and magnification keeps the original bilinear path. Sampling is bounded to
16 per axis, operates directly on both regular and external client textures,
and preserves premultiplied transparency without allocating preview buffers or
resizing applications. `tests/metaworld-minification.lisp` checks footprint
geometry; `tests/minification-gles.py` exercises the production shaders on GLES
and produces a before/after gallery with rendering timings.

Gesture ownership follows the entered subworld. Ownership is captured when
fingers touch down; entering or leaving a group cancels an in-flight gesture
instead of transferring it to a different handler.

- On the canvas, three fingers pan with a short bounded coast, and two-finger
  pinch zooms around the pointer.
- Inside a subworld, three fingers swipe left/right between neighboring tiles
  and up/down between existing workspaces. Niri focus scrolls only far enough
  to reveal the selected tile. Four fingers navigate workspaces on either axis.
- Subworld navigation locks to the first clear axis. Each 96 logical pixels
  advances one tile/page; release commits a remaining half-step. Cancellation
  discards remaining travel; steps already taken stay selected.
- Unsupported gestures inside a group, including pinch, are consumed there.
  Ordinary two-finger application scrolling remains unchanged.

Niri tiles have zero gaps between columns and stacked rows. Workspace pages
are directly adjacent vertically and share one enclosing group border. Each
page retains its own column widths and horizontal scroll position. Entering
Niri fits the workspace height to the full monitor height; wide columns scroll
horizontally instead of shrinking the workspace to fit its width.

A button drag takes priority over gestures. Finger-count changes, device/seat
removal and output removal cancel unfinished gestures. Gesture signals are
available on direct libinput touchpads and on nested backends when the host
compositor forwards them.

`tests/metaworld-gestures.lisp` exercises the copied input path, panning, zoom
anchoring and limits, momentum, cancellation and workspace thresholds.
`tests/gesture-native.c` checks native event extraction and signal addresses.

Direct DRM startup runs `scripts/setup-desktop-session` asynchronously. It
publishes the current Wayland socket to D-Bus/systemd activation and selects an
Ataxia-specific GTK portal configuration. This avoids Firefox waiting for a
GNOME portal whose graphical session is inactive. The script preserves an
existing `ataxia-portals.conf` and does nothing in nested sessions. Desktop
launcher errors go to the compositor's stderr instead of being discarded.
