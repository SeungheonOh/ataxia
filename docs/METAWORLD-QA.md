# Metaworld layout and navigation QA

Validated on 2026-09-07 with native GLES rendering and the running compositor.

| Area | Checks and result |
| --- | --- |
| Entry framing | Dotted page fits the viewport without an extra outer frame. Aspect ratio and centering checked on landscape, portrait, ultrawide and fractional-scale outputs. |
| Back navigation | Active header calls Leave; overview header calls Enter. Native pointer click on the breadcrumb returns to overview. Saved camera position, zoom and rotation restore exactly. |
| Niri | First/last-column focus, manual zoom, independent workspace scroll, vertical pages and exact outer padding pass. Removed the extra trailing column gap. |
| Hyprland | Master and Dwindle bounds and non-overlap pass across three split ratios. Remaining tiles retain room for their minimum sizes. |
| Tile density | All three layouts checked with 1–12 windows at 480×320, 1400×800 and 1920×1080, including skewed stack weights. |
| UI | Native breadcrumb and tiled terminal rendered and inspected. Header and window controls use vector icons. Toolbar is responsive; context panels stay within the output. Escape dismissal and direct actions do not reopen hover controls under a stationary pointer. |
| Animation | Existing interruption, straight camera path, sizing, raster-density and input-cancellation tests pass. |
| Persistence and services | Existing state, migration, independent-workspace and worker-isolation regressions pass. |
| Idle | Deadline and runtime-dispatch tests pass; live maintenance timer is disarmed after settling. |
| Native startup | Metaworld plus standalone Niri and Hyprland headless startup/shutdown pass. Slint built-in interfaces and dynamic fallback pass with compositor floating-point settings. |
| Live update | Existing application connections retained. Current 1280×720 output fits the 1400×800 page at zoom 0.9, giving 10 px side letterboxing and no top/bottom outer margin. |

Regression scripts: `metaworld-layout-qa.lisp`, `metaworld-chrome.lisp`,
`metaworld-motion.lisp`, `metaworld-performance.lisp`, `metaworld-idle.lisp`, and
`slint-builtins.lisp` under `tests/`. For the native Slint suite, use the same
floating-point configuration as compositor startup:

```sh
sbcl --eval '(sb-int:set-floating-point-modes :traps nil)' --script tests/slint-builtins.lisp
```

This covers the configurations above; it is not an assertion about every possible
client minimum size or arbitrarily dense layout.
