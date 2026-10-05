# Workstation UI

Compositor UI uses white surfaces, black ink, square frames and monospaced type.
Every drawing must explain a control, a boundary, a selection or a state.
There are no ornamental title rules, patterns, badges, shadows or brand marks.
Application content belongs to the application and keeps its own styling.

`src/world/web/ui/document.css` owns the palette, typography, spacing tokens
and control states for the built-in HTML documents. Each document's own styles
own its layout; do not add theme overrides to correct document geometry. Each
document links the theme relative to its real source path and opts in with a
`shell` body class. Web components created with their own source or asset root
style themselves independently. Stage's pages use `examples/stage/pages/theme.css`.

Sizes below are in logical pixels (dp).

- Use an 8 dp horizontal gutter at panel and text-field edges, an 8 dp gap
  between related commands, and 16 dp between independent columns. Apply the
  same gutters at narrow widths; wrap or truncate content instead of changing
  the spacing. Add the gutter once per container, not to each text action.
- Keep 16 dp text rows with no extra padding above or below text. Wrapped
  commands stay on consecutive lines. Use horizontal space for readability.
- Reading surfaces such as the assistant may use 16 dp horizontal gutters and
  8 dp around the header and between messages. Keep action text unpadded; use
  16 dp gaps to distinguish independent options. Model controls expand locally
  beside their task instead of covering the desktop with a modal.
- Actions are text, without an outline, resting fill or button padding.
  Invert foreground/background on hover, keyboard focus, press and selection;
  keep disabled text unfilled. Retain semantic buttons for keyboard activation.
- Single-line editable fields are 18 dp including their 1 dp frame.
  The status bar is one text line, 18 dp including its boundary. Size popup
  hosts with their contents; do not leave the old oversized empty containers.
- Battery details use aligned label/value columns. Show estimates and error
  explanations only when available. Media controls appear when a player exists.
  Clipboard previews preserve line breaks; use a column beside the list, or
  stack below it on narrow outputs. Empty results shrink to a single message.
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

Run `make test-shell test-web-shell` for shell behavior through the HTML bar,
and `make benchmark-desktop-idle test-view-shift-idle` for idle checks.
