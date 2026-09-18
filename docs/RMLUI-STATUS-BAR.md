# RmlUi status bar

An optional, full-width light bar at the bottom of each desktop World output. It
shows named workspace navigation, the focused window, audio volume, media, clipboard, battery/AC state, and local date and time. Metaworld supplies subworld and workspace navigation. It is 44 logical pixels high, with square controls, a single
baseline, opaque white backing and a one-pixel top border. Selection changes
immediately; the bar has no decorative animation or shadow.

The bar reserves its height through the World work-area protocol, keeping workspace
content above it. Removing the bar restores the full output area.

## Enable

Build the optional native engine with `make rmlui`, then load:

```lisp
(asdf:load-system "ataxia-rmlui/status-bar")
```

On the World owner thread, with a World implementing the UI and desktop protocols:

```lisp
(ataxia.world.shell:enable-rmlui-status-bar world)
(ataxia.world.shell:disable-rmlui-status-bar world)
```

Enabling again replaces existing bars, timers, clipboard transfers and system workers. New outputs receive a bar;
output removal destroys its component. World quiescence removes the maintenance
timers, event sources, queued actions, clipboard history, feedback overlays and all bars. This is opt-in per World; enabling it in a live session does
not change startup configuration. Fresh processes require native glue ABI 15, RmlUi ABI 2 and Slint ABI 5 (`make all rmlui`). Do not replace native handles underneath existing UI components in a running image.

## Controls and layout

- The Apps button opens an application menu. Type immediately to search,
  use Up/Down and Enter to launch, or browse pages. Escape, the close button,
  and outside clicks dismiss it and restore application focus.
- The location button opens a named workspace picker. Choose a group on the left,
  then a workspace card. Created or visited workspaces remain visible, including
  empty ones; unused slots are hidden. **New workspace** opens the first unused workspace. Cards identify the
  current workspace and show item counts and a window-title preview. The Overview
  button returns to the overview.
  With the picker open, keys 1–9 select workspaces in the chosen group.
  **Remove** moves a workspace's apps and notes to a neighboring workspace and
  renumbers the following pages. The last workspace is retained. **Remove subworld**
  leaves its apps and notes on the canvas. Neither action closes applications.
- The audio button opens output volume, mute and media controls. The active player
  shows its title, artist and playback state. Click its name to cycle players;
  previous, play/pause and next respect the player's advertised capabilities.
- The clipboard button opens searchable recent text. `Ctrl+Super+V` is its shortcut
  (`Super+V` remains the existing floating-window command). Up/Down and Enter choose
  an item; then paste normally in the application. Selection restores app focus.
  Clear history removes history without changing the current clipboard.
- The clock uses local 24-hour time. Click the battery to see charge status,
  estimated time remaining or until full, health relative to design capacity,
  charge cycles, and power source. Unavailable measurements are labelled.
- The battery fill follows charge level. Amber indicates 25% or less, and red
  indicates 10% or less while on battery. Charging and external power have a
  distinct symbol; fully charged and paused charging have separate labels.
  Systems without a present battery show `AC`.
- The power panel includes a brightness slider and −/+ buttons (5% steps), plus
  Sleep to suspend to memory. The display brightness keys work with the panel
  closed; `XF86Sleep` and `XF86Suspend` request sleep once per key press.
  Brightness has a 1% minimum to keep the display visible.
  Changes ease between levels over 250 ms at approximately 60 updates per second;
  new input redirects the fade from its current level. Brightness, volume and media
  keys show an output-local feedback panel for 1.6 seconds, with confirmed readback
  and errors. Feedback does not take focus or intercept pointer input.

The bar spans the output. Below 1,050 logical pixels it hides the focused title,
media title and date. Below 680 it hides battery text and separators. Below 380,
the location label is shortened and the clock/clipboard button are hidden to keep
workspace, audio and power controls reachable; the clipboard shortcut still works.
Workspace and media panels scroll on short outputs. The RML uses `dp`, with logical-width classes computed by Lisp so display
scale does not change the breakpoints. The bar overlays the canvas; it does not
reserve window-layout space.

The clock and battery share one wakeup per minute while the power panel is closed.
Opening power details refreshes immediately, then at most 30 seconds apart,
aligned to minute boundaries. Only changed values invalidate the component. Window and
workspace context updates with World frames. There is no idle animation or
continuous status polling. Style lives in `src/world/rmlui/status-bar/bar.rml`;
Presentation and cached updates live beside it in `status-bar.lisp`; navigation
policy comes from the World adapter. See [World services](WORLD-SERVICES.md).

## Verification

`make test-rmlui-status-bar` checks real GLES renders at 320, 480, 820 and 1,320
logical pixels, including 2× scaling, opaque square bounds, selection changes,
and settled idle. PNG previews are written to `build/status-bar-*.png`.

`make test-rmlui-status-bar-world` requires access to a GLES render device. It
checks repeated enable, workspace commands, resize, settled frames, removal,
and quiescence in a real headless Metaworld alongside its Slint chrome.

The app menu uses the installed `.desktop` entries already indexed by the World
launcher, prioritizing common browser, terminal, editor, and file-manager entries.
It launches through the existing asynchronous `gio launch` path. Applications
appear in six aligned rows with neutral initials. The menu is
400 × 480 logical pixels, constrained by the output size; the power panel is
340 × 500. Short displays scroll the power controls while keeping Close visible;
narrow displays retain the application list.
The search caret schedules its own blink while the menu is focused;
closing the menu retires that component and its pending visual work.

Battery readings use the first present system battery. Time estimates pair
energy with power, or charge with current, and are omitted when the rate is
missing or zero. This does not combine several batteries into one estimate.

Brightness uses the first valid device in `/sys/class/backlight/` and logind's
session `SetBrightness` method over one private `libsystemd` D-Bus connection per
fade. The user's display session is resolved explicitly, including for compositors
started as system services. It controls a hardware backlight; external monitor
DDC controls are not implemented. Sleep uses logind's `CanSuspend` and `Suspend`
methods, preserving system permissions and inhibitors. `busctl` and a systemd
login session are required. Unsupported controls are disabled, authorization
requirements are displayed, and failed operations show an error in the panel.
Interactive authentication is not requested.
When Ataxia runs as a system service, sleep requests run through `systemd-run --user`
so logind evaluates them in the user's service manager. The user's D-Bus and
runtime-directory environment must be available to that service.

System calls run on one worker with a bounded queue; rapid brightness changes
replace the active fade's target. Fades stop for teardown or a queued sleep request.
An eventfd delivers copied results to the owner
thread. Capabilities refresh at startup and when the panel opens; there is no
power-control polling timer. Closing a World discards queued requests and ignores
late results; an already-started system operation may finish. Native range model
updates suppress unchanged echoes so refreshing a percentage cannot set brightness.

`make test-rmlui-shell` tests battery states and estimates with sysfs fixtures,
and renders wide/narrow menus and power panels with real keyboard search.
`make test-rmlui-shell-world` checks World keyboard routing, live search, Escape,
outside dismissal, popup cleanup, and launching a temporary desktop entry that
writes a test marker. The RmlUi input adapter converts Kernel XKB key names to
numeric keysyms before calling the native renderer.

The shell tests also cover brightness bounds, logind arguments, unavailable sleep,
native range/button events, disabled controls and short-panel scrolling. A fake
power backend in the World test exercises readback, permission failures, held sleep
keys, responsiveness during blocked calls and cancellation at teardown. Tests do
not change hardware brightness or suspend the machine.

## Event-driven audio, media and clipboard

Volume uses `libpulse.so.0` and its native subscriptions, supporting PulseAudio and
PipeWire's Pulse server. It follows default-output changes, preserves channel
balance and limits requested volume to 0–100%. Increasing or setting volume unmutes
the output. Media uses MPRIS over a private `libsystemd` session-bus connection:
name-owner and property-change signals update players and metadata. A playing
player is preferred until the user chooses one. Neither connection polls while
connected; bounded retry backoff applies only while a service is unavailable.
Workers send copied state through eventfd, and all UI work stays on the owner thread.
No command-line process is launched to refresh audio or media state.

Wayland selections stay on their originating seat. Text reads use nonblocking pipes
with a two-second deadline and a 4 MiB transfer limit. History is memory-only,
deduplicated, and limited to 20 entries, 256 KiB per entry and 2 MiB total per seat.
Password-manager-marked selections and agent seats are excluded from history.
History is not written to disk. Native RmlUi and Slint text editors bridge copy/cut
and asynchronous paste to the seat's selection; delayed pastes are discarded if
focus changes. Primary-selection/middle-click paste, images and rich-text history
are not implemented.

`make test-shell-controls` runs native rendering and World integration checks for
workspaces, short-panel scrolling, volume/mute keys, feedback focus/expiry, history,
Unicode, large transfers, stale-paste cancellation and both native editors. It also
checks native source replacement, closed readers, timeouts and seat isolation.
`make test-shell-backends` tests actual Pulse subscriptions and MPRIS commands on
private PipeWire/Pulse and D-Bus instances. It requires PipeWire, `pw-metadata`,
`dbus-run-session` and Python GI; it does not change the user's output volume or
control the user's media players.
