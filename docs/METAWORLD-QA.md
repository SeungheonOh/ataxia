# Metaworld regression coverage

`make test` runs the following checks without modifying a live desktop.

For thread ownership, idle scheduling and repeatable CPU measurements, see
[Maintenance and idle performance](MAINTENANCE.md).

| Suite | Coverage |
| --- | --- |
| `metaworld-layout-qa.lisp` | Niri zero-gap tiles, fullscreen height, focus and wheel scroll bounds; Hyprland fit and tiling; exact overview-camera restoration. Layouts cover 1–12 windows, three sizes and split ratios, and skewed stack weights. |
| `metaworld-performance.lisp` | Writer and launcher isolation, queue bounds, failure recovery, persistence and migration, visible border strokes across output transforms and rotations, touching workspace edges, and full-height Niri on landscape, portrait, and ultrawide displays. |
| `metaworld-animation.lisp` | Velocity/acceleration continuity on reversal, independent channels, bounded fades, callback chaining/cancellation, 60–240 Hz and missed-frame equivalence, and damage work restricted to animated windows. |
| `metaworld-hyprland.lisp` | Focused Dwindle insertion, local keyboard/pointer resize, swaps, edge drops, split rotation, saved trees, fullscreen bounds, workspace fade reversal/input ownership, and stationary grab geometry. |
| `metaworld-motion.lisp` | Retargeting, interrupted camera motion, direct grabs, resize configure counts, workspace-local column operations, and raster-density limits. |
| `metaworld-gestures.lisp` | Runtime-to-Kernel dispatch, modifier events, canvas pan/pinch/coast, subworld ownership, cancellation, and device isolation. |
| `metaworld-chrome.lisp`, `metaworld-title-layer.lisp` | Toolbar/header hover dwell, fade reversal, dismissal, header navigation, draw order, and pointer targeting. |
| `metaworld-idle.lisp` | Timer disarming, hover/save deadlines, and blocking Runtime dispatch. |
| `metaworld-packing.lisp` | Dense arrangements, chained pushes, rapid retargeting, contact separation, page growth, and carried window geometry. |
| `metaworld-minification.lisp`, `minification-gles.py` | Physical-pixel sample footprints and production GLSL compilation/rendering, including texture crops and transforms. |
| `slint-builtins.lisp` | Built-in property/callback interfaces, construction/destruction, and interpreted custom widgets. |
| `gesture-native.c` | Native event extraction and gesture signal addresses. |

For startup/shutdown smoke checks, use an isolated headless backend and disable
persistence and the control port:

```sh
WLR_BACKENDS=headless WLR_RENDERER=gles2 sbcl \
  --eval '(sb-int:set-floating-point-modes :traps nil)' \
  --script scripts/run-metaworld.lisp --backend headless --no-persist --no-sly --run-for 1
```

Repeat with `--world niri` and `--world hyprland` for standalone modes. These
checks require access to a suitable EGL renderer. Manual checks remain useful
for physical touchpad feel, client-specific minimum sizes, and display hotplug.

## Desktop integration

`make test-qol` runs isolated native tests for the RmlUi chooser,
sharing indicator, source-row clicks, two headless
outputs with different sizes, pointer crossings, output removal, and exact
rotated canvas capture and front-window occlusion. It also launches a real XWayland client with a popup and
resizes it. Screen sharing goes through an actual `xdg-desktop-portal` frontend
in a disposable D-Bus session, then uses its restricted PipeWire descriptor to
receive and inspect frames with GStreamer. Cancellation must export no stream.
Preparing sixteen sessions must not exhaust the active-stream quota. Two streams
must deliver frames concurrently; stopping one must leave the other running.
A static application keeps streaming from cached pixels, a changed client buffer
invalidates the cache, and closing all streams must disarm capture and output work.
`make test-drag` covers actual Wayland drag icons, frame callbacks, movement damage,
cross-window drop routing, canvas zoom/rotation and client-disconnect cleanup.
`make benchmark-desktop-idle` measures CPU, allocations, frames and capture ticks
with two outputs, both UI bars, the portal, and real Wayland/X11 windows.
The RmlUi test renders the production documents through GLES and checks that
Share cannot dispatch before selection. UI images are written to `build/qol-*.png`.

`make test-computer-use` checks the shared offscreen capture path, coordinate
transforms, application input and the desktop API. The main `make test` includes
independent monitor-camera unit tests.

These tests need Xwayland, Xlib development headers, a running PipeWire server,
xdg-desktop-portal, Python GI with GStreamer and its PipeWire plugin, and an EGL
renderer. They do not move windows on the live desktop. Physical monitor hotplug
and browser-specific screen-sharing flows still need hardware/manual coverage.
