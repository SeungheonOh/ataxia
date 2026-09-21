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

- No panel inset or extra spacing above/below text. Use a 16 dp text line,
  like terminal rows. Separate adjacent commands horizontally by one character
  (8 dp); wrapped commands remain on consecutive lines.
- Actions are text, without an outline, resting fill or button padding.
  Invert foreground/background on hover, keyboard focus, press and selection;
  keep disabled text unfilled. Retain semantic buttons for keyboard activation.
- Single-line editable fields are 18 dp including their 1 dp frame.
  The status bar is one text line, 18 dp including its boundary. Size popup
  hosts with their contents; do not leave the old oversized empty containers.
- Body text: 12–14 dp; panel headings: bold 14 dp. Avoid oversized greetings.
- Inverse ink/paper communicates hover, focus and selection. Red indicates
  destructive actions or critical status. Agent colors identify sessions.
- Text labels distinguish sections; a drawn line needs an additional purpose.
  A scrolling source list, editable field or window boundary may need a frame.
  A transcript message does not need another box around its role and text.
- Action rows wrap when needed; flexible labels must shrink without pushing
  commands outside their container. Use logical dp units and scrolling content.
  A visual state change must never change a control's geometry.
- Feedback may invalidate a bounded number of frames. Stationary UI must return
  to idle. The pan HUD draws only its anchor, velocity tether and dead zone;
  contrasting edges there and on share selections ensure visibility over apps.

Legacy Slint World widgets share `src/worlds/metaworld/theme.slint`'s palette.
The launcher and pan HUD embed Slint source in Lisp. Rebuild the Slint library
when changing compiled widgets; never redirect existing native component
pointers to a different library instance.

Run `make test-shell-theme` for native GLES renders, disjoint action bounds,
real hit tests and foreground/background inversion tests.
`build/workstation-ui.png` shows actual RmlUi output; `build/theme-*.png` covers
normal/narrow layouts and 1×, 1.5× and 2× scales. World and idle checks:
`make test-rmlui-shell-world test-rmlui-status-bar-world`
and `make benchmark-desktop-idle test-view-shift-idle`.
