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
The canvas overview includes all allocated pages. Columns and stacked windows
have zero gaps, and workspace pages touch within one enclosing border. Entered
Niri fits the full monitor height and scrolls horizontally when its columns
exceed the visible width. Hyprland fits both dimensions and retains its tile
padding and gaps.

## Run

Build the native libraries with `make`, using the same wlroots, Slint, and Lisp
dependencies as the existing infinite world. Launch on Linux:

```sh
sbcl --eval '(sb-int:set-floating-point-modes :traps nil)' --script scripts/run-metaworld.lisp
sbcl --eval '(sb-int:set-floating-point-modes :traps nil)' --script scripts/run-metaworld.lisp --world niri
sbcl --eval '(sb-int:set-floating-point-modes :traps nil)' --script scripts/run-metaworld.lisp --world hyprland
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
  Nearby groups move aside, keeping their complete footprints separate.
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
  on empty group space resizes the group. Super + right-drag resizes a window.
- An ordinary right-click inside an application reaches that application.
  Custom context menus, experimental window piles and the upper-right hover bar
  are removed. Apps and workspace navigation remain in the status bar.
- Notes can be dragged by their upper edge and reveal their close control on hover.
- Super + wheel zooms around the pointer. Middle-drag pans the canvas.
  Shift + wheel scrolls the active Niri layout horizontally.

The visual treatment is light monochrome: neutral paper, unobtrusive cross
reticles, unboxed group names, and short screen-space dot–dash–dot boundaries.
Reticle density blends across zoom levels rather than accumulating into a dense
texture. Camera navigation and window rearrangement use short eased transitions.

See [desktop integration](DESKTOP-QOL.md) for XWayland, screen sharing, and independent monitor viewports.

## Keyboard

Super is the Logo/Windows key (Command when captured by UTM).

| Shortcut | Action |
| --- | --- |
| Super + E | Enter the group under the pointer, or the focused object's group |
| Super + Page Up / Page Down | Enter the previous / next group |
| Super + M / Super + Escape | Leave; in the canvas, fit all objects; standalone: overview |
| Escape | Dismiss a shell popup or cancel a pending sharing request |
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
by application ID and title, with application-ID fallback. Saving a layout does
not relaunch external applications after the compositor exits. Identical application IDs and titles cannot uniquely identify
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

The implementation subclasses the infinite World. Runtime copies native touchpad
events before Kernel dispatch; gesture policy stays in the World. The rendering
hooks distinguish canvas decorations from overlays and synchronize UI once per
output frame after animation sampling.

## Touchpad gestures

Gesture ownership is captured when fingers touch down. Entering or leaving a
group cancels an in-flight gesture instead of handing it to a different handler.

- On the canvas, three fingers pan with a short bounded coast, and two-finger
  pinch zooms around the pointer. A new contact or button press stops the coast.
  Release velocity uses elapsed time, including coalesced events, and a pause
  clears stale momentum. The coast settles with zero speed and acceleration.
- Inside a subworld, three fingers navigate neighboring tiles horizontally and
  existing workspaces vertically. Four fingers navigate workspaces on either
  axis. Unsupported gestures, including pinch, are consumed by the subworld.
- Navigation locks to the first clear axis. Each 96 logical pixels advances one
  tile or page; release commits a remaining half-step. Cancellation discards
  remaining travel; steps already taken stay selected.
- Ordinary two-finger scrolling remains available to applications. Button
  drags, key presses, finger-count changes, and device/output removal cancel
  unfinished gestures.

Direct libinput touchpads provide these signals. Nested backends require the
host compositor to forward them.

## Rendering and motion

Built-in Slint controls compile with the native library. Custom agent widgets
use the interpreter. Each control owns keyboard state backed by a shared
immutable keymap. Dismissed controls stop accepting input immediately, then fade
out. Explicit menus and direct manipulation suppress automatic hover controls.

Layout animations retain separate displayed and destination rectangles. They
retarget from the displayed position and retain velocity and acceleration,
including on reversals. Quintic trajectories settle exactly with zero velocity
and acceleration. Sizes, opacity, and zoom constrain their trajectory control
points to valid ranges. Each window's layout, fade, and shadow lift has an
independent channel; the client receives its final size once per target.
Grabs stay attached to the pointer while neighboring tiles reflow. Moving a
group also translates its children's active animation paths. Fresh camera
pan/zoom transitions follow straight screen paths; interrupted transitions bend
smoothly toward the new target, and rotations take the shortest arc.

Slint timers advance before rendering each output frame, so control animations
follow the display refresh rate rather than a 16 ms polling timer. Application
timers still use their own deadlines. Animation damage samples only animated
windows and does no coverage work when the animator is idle. Callback-driven
cancellation and chaining preserve newly scheduled animations.

Hyprland subworlds keep a Dwindle split tree for each workspace, including
per-split ratios in saved state. New tiles split the focused tile; closing a tile
collapses its branch. Directional swaps and edge drops operate on those leaves.
Keyboard and pointer resizing adjust the nearest split on the selected axis.
Super+J rotates the focused tile's split. Master layout supports independent
stack weights for vertical resizing. Fullscreen fills the entire subworld.
Workspace visibility crossfades separately from window presence; outgoing
windows stop accepting input immediately. Shadow lift does not move content
away from the grabbed point.

These choices follow Hyprland's [Dwindle split model](https://wiki.hypr.land/configuring/layouts/dwindle-layout/)
and separate [window/workspace animation channels](https://wiki.hypr.land/configuring/core/animations/).
Split orientation stays fixed until explicitly rotated, corresponding to a
preserved-split policy. This is an Ataxia layout implementation; Hyprland's
configuration language, plugins, special workspaces and full decoration system
are not implemented here.

Niri column operations stay within their workspace. Weighted stacks reserve
minimum sizes before distributing space; crowded stacks and Hyprland splits
fall back to a grid. Group packing preserves a 40-unit contact gap and starts
moving neighbors at a 96-unit gap. These layouts cannot fit arbitrarily many
minimum-sized windows into a fixed region.

Slint raster density follows displayed size and output scale, with half-octave
allocation buckets and shrink hysteresis. Textures respect the GPU dimension
limit and a 16-megapixel budget per component. Application buffers remain
client-owned. Minified surfaces use a bounded area filter, while magnification
uses bilinear filtering. The same shader supports ordinary and external
textures. Window shadows use a Gaussian rectangle integral in one draw call.

Border vertices are packed floats in a bounded cache. Culling accounts for
canvas rotation. Object coverage is computed once per frame and reused across
damage rectangles. Titles render below application windows, and covered titles
do not intercept window input.

## Background work and desktop services

State saves and application launches use separate workers. Saves coalesce by
path and retain copied snapshots so World replacement can restore queued state
without waiting for disk. `save-metaworld` is asynchronous; shutdown drains
pending writes after the Kernel stops. The bounded launch queue handles both
terminals and desktop entries. Unique terminal application IDs retain the
requested group, workspace, and stack target across out-of-order arrivals.
Workers never access live World, Wayland, Slint, or GLES objects.

Hover dwell, dismissal, and save deadlines use one-shot timers. Idle timers are
disarmed, and workers wait on semaphores. Runtime flushes client messages before
blocking in Wayland dispatch; sockets, input, the control pipe, and timers wake
it without polling.

Direct DRM startup queues `scripts/setup-desktop-session`. It publishes the
Wayland socket to D-Bus/systemd activation and selects an Ataxia-specific GTK
portal configuration, avoiding unavailable GNOME portal services. It preserves existing portal choices, adding the Ataxia ScreenCast backend only
when no ScreenCast preference exists, and does nothing in nested sessions. Portal
setup and application launch failures are logged to stderr.

Native library installation uses atomic replacement. The Slint bridge resolves
functions through an explicit library handle to prevent mixed native versions.
Destroy existing components before switching handles; old libraries stay mapped
for their thread-local destructors.

## Validation

Run the complete regression suite with:

```sh
make test
```

This builds the native libraries, runs the Lisp and native gesture tests, then
exercises the production minification shaders on a surfaceless GLES context.
The shader checks require Python 3, Pillow, and DejaVu fonts. Set
`ATAXIA_SHADER_TEST_DIR` to retain the comparison gallery; otherwise its temporary
files are removed. `ATAXIA_LISP_DEPS` and `ATAXIA_DEPS` work as in the launcher.
Individual Lisp scripts can also run through SBCL; native Slint tests need the
floating-point configuration shown in the launch commands above.

See [the QA checklist](METAWORLD-QA.md) for coverage and headless smoke commands.
Render-call timings do not measure end-to-end physical pointer latency.
