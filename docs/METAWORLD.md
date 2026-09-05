# Metaworld

Metaworld is an infinite canvas containing movable, single-level window groups.
Each group owns either a scrolling-column layout inspired by Niri or a dynamic
tiling layout inspired by Hyprland. Groups contain real application windows and
spatial Slint widgets, not screenshots or nested compositor instances. Unowned
windows and notes remain ordinary canvas objects. Groups cannot contain groups.

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
- Move the pointer to the top edge for the active group's compact navigation,
  workspace, and terminal actions. These controls disappear when not needed.
- Drag a window by its title, or hold Super and drag anywhere in the window.
  Drop inside a group to join it, outside all groups to detach, or inside another
  group to transfer ownership. Group boundaries indicate the current drop target.
- Hold Control when dropping onto a Niri column to stack in that column. A
  regular drop reorders into a separate column.
- Hold Super and drag empty space inside a group to move it. Super + right-drag
  on empty group space resizes the group; on a window, it resizes the window.
- Hover a window's upper edge for actions attached to that window. Only
  applicable actions appear. Notes can be dragged by their upper edge and reveal
  their close control on hover.
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
| Escape | Dismiss an open context menu |
| Super + Return | Create a terminal in the current group or the parent canvas |
| Super + arrows | Focus a neighboring object |
| Super + Shift + arrows | Reorder the focused tile or Niri column |
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
Applications are matched by application ID and title, with application-ID
fallback. Saving a layout does not relaunch external applications after the
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

## Live validation

Validation takes place in the running UTM Linux VM; no automated test cases were
added. Computer Use keyboard interaction has exercised group creation, entry and
exit, Niri columns and stacking, width changes, workspaces, floating, fullscreen,
Hyprland master and dwindle, split-ratio resizing, and standalone mode switching
without closing clients. Notes and workspace membership survived a full
compositor restart and a round-trip through standalone modes. Group placement
has also been exercised through the live World API and visually inspected.

Pointer-driven dragging and hover actions still require final verification:
Computer Use can deliver guest keys and buttons, but guest pointer motion has
remained stationary during the current UTM automation session.
