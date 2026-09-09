# Metaworld regression coverage

`make test` runs the following checks without modifying a live desktop.

| Suite | Coverage |
| --- | --- |
| `metaworld-layout-qa.lisp` | Niri zero-gap tiles, fullscreen height, focus and wheel scroll bounds; Hyprland fit and tiling; exact overview-camera restoration. Layouts cover 1–12 windows, three sizes and split ratios, and skewed stack weights. |
| `metaworld-performance.lisp` | Writer and launcher isolation, queue bounds, failure recovery, persistence and migration, visible border strokes across output transforms and rotations, touching workspace edges, and full-height Niri on landscape, portrait, and ultrawide displays. |
| `metaworld-animation.lisp` | Velocity/acceleration continuity on reversal, independent channels, bounded fades, callback chaining/cancellation, 60–240 Hz and missed-frame equivalence, and damage work restricted to animated windows. |
| `metaworld-hyprland.lisp` | Focused Dwindle insertion, local keyboard/pointer resize, swaps, edge drops, split rotation, saved trees, fullscreen bounds, workspace fade reversal/input ownership, and stationary grab geometry. |
| `metaworld-motion.lisp` | Retargeting, interrupted camera motion, direct grabs, resize configure counts, workspace-local column operations, and raster-density limits. |
| `metaworld-gestures.lisp` | Runtime-to-Kernel dispatch, modifier events, canvas pan/pinch/coast, subworld ownership, cancellation, and device isolation. |
| `metaworld-chrome.lisp`, `metaworld-title-layer.lisp` | Hover dwell, direct actions, fade reversal, dismissal, header navigation, draw order, and pointer targeting. |
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
