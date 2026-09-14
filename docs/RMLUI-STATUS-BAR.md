# RmlUi status bar

An optional floating bar for Metaworld. It sits near the bottom of each output,
clear of the existing top-edge controls, and shows the active subworld, workspace,
focused window, application count, battery/AC state, local date and time.

The mint workspace indicator slides with a 320 ms cubic easing curve. Buttons have
180–220 ms hover and press transitions; the bar enters with a short fade and slide.
Animations run through the World component scheduler and settle when finished.

## Enable

Build the optional native engine with `make rmlui`, then load:

```lisp
(asdf:load-system "ataxia-rmlui/status-bar")
```

On the World owner thread, with the current Metaworld:

```lisp
(ataxia.infinite-world:enable-rmlui-status-bar world)
(ataxia.infinite-world:disable-rmlui-status-bar world)
```

Enabling again replaces existing bars and their timer. New outputs receive a bar;
output removal destroys its component. World quiescence removes the maintenance
timer and all bars. This is opt-in per World; enabling it in a live session does
not change startup configuration. An already-running image may need
`(asdf:load-asd #P"/path/to/ataxia/ataxia-rmlui.asd")` before loading the new system.

## Controls and layout

- The Ataxia mark opens an animated application menu. Type immediately to search,
  use Up/Down and Enter to launch, or browse pages. Escape, the close button,
  and outside clicks dismiss it and restore application focus.
- The subworld name opens the overview.
- The arrows cycle through subworlds on the bar's output.
- Numbers select workspaces inside a subworld, or subworlds from the overview.
- The clock uses local 24-hour time. Click the battery to see charge status,
  estimated time remaining or until full, health relative to design capacity,
  charge cycles, and power source. Unavailable measurements are labelled.
- The battery fill follows charge level. Amber indicates 25% or less, and red
  indicates 10% or less while on battery. Charging and external power have a
  distinct symbol; fully charged and paused charging have separate labels.
  Systems without a present battery show `AC`.

The bar is centered and limited to 1,320 logical pixels. Below 1,050 pixels it
hides the focused title, app count and date. Below 680 it also hides the brand,
subworld name and battery text, and shows three workspace numbers around the
selection. Below 380 it tightens the controls further while keeping the Ataxia
menu and battery buttons accessible. Existing keyboard shortcuts
remain available for workspaces outside that visible range. The RML uses `dp`,
with logical-width classes computed by Lisp so display scale does not change the
breakpoints. The bar overlays the canvas; it does not reserve window-layout space.

The clock and battery maintenance timer wakes at most every 30 seconds, aligned
to minute boundaries. Only changed values invalidate the component. Window and
workspace context updates with World frames. There is no idle animation or
continuous status polling. Style lives in `src/world/rmlui/status-bar/bar.rml`;
World behavior and cached updates live beside it in `status-bar.lisp`.

## Verification

`make test-rmlui-status-bar` checks real GLES renders at 320, 480, 820 and 1,320
logical pixels, including 2× scaling, transparent corners, a moving selection,
and idle after animation. PNG previews are written to `build/status-bar-*.png`.

`make test-rmlui-status-bar-world` requires access to a GLES render device. It
checks repeated enable, workspace commands, resize, settled frames, removal,
and quiescence in a real headless Metaworld alongside its Slint chrome.

The app menu uses the installed `.desktop` entries already indexed by the World
launcher, prioritizing common browser, terminal, editor, and file-manager entries.
It launches through the existing asynchronous `gio launch` path. App tiles use
colored initials. Short displays scroll the panel; narrow displays use two
columns. The search caret schedules its own blink while the menu is focused;
closing the menu retires that component and its pending visual work.

Battery readings use the first present system battery. Time estimates pair
energy with power, or charge with current, and are omitted when the rate is
missing or zero. This does not combine several batteries into one estimate.

`make test-rmlui-shell` tests battery states and estimates with sysfs fixtures,
and renders wide/narrow menus and power panels with real keyboard search.
`make test-rmlui-shell-world` checks World keyboard routing, live search, Escape,
outside dismissal, popup cleanup, and launching a temporary desktop entry that
writes a test marker. The RmlUi input adapter converts Kernel XKB key names to
numeric keysyms before calling the native renderer.
