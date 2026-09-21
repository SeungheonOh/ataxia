# Workstation UI

Ataxia's compositor UI follows the compact, high-contrast visual language of
[Medley / Interlisp](https://interlisp.org/software/screenshots/): white surfaces,
black ink, square frames, monospaced type and static dashed or dotted rules.
Application content belongs to the application and keeps its own styling.

`src/world/rmlui/theme.rcss` owns the palette, typography, control states and
patterns for all 14 shell documents. Their inline styles own layout. Each
document links the theme relative to its real source path and opts in with a
`shell` body class plus a surface-specific class. Use
`ataxia.world.rmlui:make-shell-rmlui-component` for these documents; it loads
the regular, bold and italic DejaVu Sans Mono faces once. The generic RmlUi factory
continues to host arbitrary, independently styled applications.

- Use 2 dp square frames, 12–14 dp body text and bold 15–16 dp panel headings.
- Use inverse ink/paper for focus and selection. Reserve red for destructive
  actions and critical status; agent identity colors remain useful identifiers.
- Keep borders present across hover/focus states so controls do not shift.
- Use `.title-rule` for 6 dp dashes and `.ruled` with a `.dash-rule` child for
  3 dp dotted section dividers. Pattern elements must ignore pointer input.
- Use logical `dp` units, scrollable content and fixed action rows. Text and
  source lists must remain usable on narrow and short outputs.
- Patterns never animate. Immediate button feedback and bounded effects may
  invalidate frames; stationary UI must return to idle. The pan HUD uses a
  static pattern while actual camera motion stays paced by output frames.

Legacy Slint World widgets use `src/worlds/metaworld/theme.slint` with the same
palette. The standalone launcher and pan HUD embed their Slint source in Lisp.
Rebuild the Slint library when changing compiled widgets; never redirect
existing native component pointers to a different library instance.

Run `make test-shell-theme` for native GLES renders and control tests.
`build/workstation-ui.png` is a contact sheet of actual RmlUi output; individual
`build/theme-*.png` artifacts cover normal/narrow layouts and 1×, 1.5× and 2×
scales. World integration and idle checks are separate:
`make test-rmlui-shell-world test-rmlui-status-bar-world` and
`make benchmark-desktop-idle test-view-shift-idle`.
