# Workstation UI

Compositor UI uses white surfaces, black ink, square frames and monospaced type.
Every drawing must explain a control, a boundary, a selection or a state.
There are no ornamental title rules, patterns, badges, shadows or brand marks.
Application content belongs to the application and keeps its own styling.

`src/world/rmlui/theme.rcss` owns the palette, typography, spacing tokens and
control states for all 14 shell documents. Inline styles own each layout;
do not add theme overrides to correct document geometry. Each document links
the theme relative to its real source path and opts in with a `shell` body
class. Use `ataxia.world.rmlui:make-shell-rmlui-component` to load the four
DejaVu Sans Mono faces once. The generic factory hosts independently styled apps.

- Panel inset: 12 dp. Related controls: 8 dp gap. Sections: 16 dp gap.
  Labels and secondary text: 4 dp gap. Use the shared variables, including
  at narrow widths; change flow before changing spacing.
- Controls: 32 dp high with 8 dp horizontal padding. Frames: 1 dp.
  A 30 dp line fits the control interior without moving text on focus.
- Body text: 12–14 dp; panel headings: bold 14 dp. Avoid oversized greetings.
- Inverse ink/paper communicates hover, focus and selection. Red indicates
  destructive actions or critical status. Agent colors identify sessions.
- Space separates sections; a drawn line needs an additional purpose.
  A scrolling source list, editable field or window boundary may need a frame.
  A transcript message does not need another box around its role and text.
- Keep borders allocated across input states so controls do not shift. Use
  logical dp units, scrolling content and fixed action rows on small outputs.
- Feedback may invalidate a bounded number of frames. Stationary UI must return
  to idle. The pan HUD draws only its anchor, velocity tether and dead zone;
  contrasting edges there and on share selections ensure visibility over apps.

Legacy Slint World widgets share `src/worlds/metaworld/theme.slint`'s palette.
The launcher and pan HUD embed Slint source in Lisp. Rebuild the Slint library
when changing compiled widgets; never redirect existing native component
pointers to a different library instance.

Run `make test-shell-theme` for native GLES renders and control tests.
`build/workstation-ui.png` shows actual RmlUi output; `build/theme-*.png` covers
normal/narrow layouts and 1×, 1.5× and 2× scales. World and idle checks:
`make test-rmlui-shell-world test-rmlui-status-bar-world`
and `make benchmark-desktop-idle test-view-shift-idle`.
