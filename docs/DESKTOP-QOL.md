# Desktop integration

The screen-sharing chooser, region selector and sharing indicator are HTML pages.
Capture policy and monitor cameras belong to World. Runtime's optional XWayland
module owns native wrappers, listeners and copied protocol requests. Kernel's
adapter translates these into stable application objects and World requests; the portal worker handles
D-Bus/PipeWire transport without calling Lisp or GL.

The experimental window stacks, selection gesture and canvas/window context menus
have been removed. The old window corner hover bar remains removed. Super + drag
moves a window; Super + right-drag resizes it. Application right-click menus remain
available. Apps and workspace navigation are accessible from the status bar.

## Monitors

Every output has a separate camera (position, zoom and rotation) on the same world.
New monitors start to the right of the existing physical layout. Panning or zooming
one monitor does not change another monitor's camera. Relative pointer input crosses
physical monitor edges, including different output sizes and vertical arrangements.

Physical monitor placement is independent of the world camera. On the compositor
owner thread, configure it with:

```lisp
(ataxia.infinite-world:set-output-position world output 0 -1080)
```

Coordinates are logical desktop pixels. Metaworld saves physical placement and
camera state by output name. The desktop snapshot includes each output's name,
logical size, physical position and camera. A removed output transfers its seat to
a surviving output; applications remain in the world.

## XWayland

Metaworld starts a lazy XWayland server and exports its `DISPLAY` to launched
applications. Install `Xwayland` alongside the compositor's wlroots build. Managed
X11 windows use the same World layout, focus, close, maximize and fullscreen paths
as Wayland windows; override-redirect menus are attached to their application.
X11 applications implement the same `drawable` and `interactable` protocols as
Wayland applications and HTML components. World consumes their drawable
records, transforms local coordinates, and calls the common input, focus,
configuration and state methods. Popup surface routing and XWM translation stay
inside Kernel's adapter; there are no X11 rendering or input hooks in World.
Unsupported advisory hints are ignored: `:suspended` does not minimize X11 windows.
`make test-xwayland` exercises the contract with a real X11 client in plain Infinite
World, including popup pixels and input outside the root bounds, camera transforms,
pointer grabs, keyboard focus, resizing, fullscreen and close.
`--no-xwayland` disables the server. X11 accessibility depends on the application;
pixel capture and application input work when no accessibility tree is available.

## Screen sharing

Install the PipeWire and GLib development packages to build the transport
(`pkg-config libpipewire-0.3 gio-2.0 gio-unix-2.0`), plus PipeWire,
xdg-desktop-portal and a desktop portal backend such as GTK at runtime.
`make all` builds the transport.

Sharing is enabled by default outside headless mode. `--screen-sharing` enables it
explicitly; `--no-screen-sharing` disables it. Direct DRM sessions run
`scripts/setup-desktop-session`, installing the checkout's portal descriptor and
adding an Ataxia ScreenCast preference when none is already configured. The helper
preserves other portal preferences and skips nested sessions.

An application's portal request opens **Choose what to share**. Choose one application,
or **Select a region of the canvas**, drag a rectangle and review its size/location.
Click **Share** to grant access; choosing a source alone does not start a stream.
Escape or **Cancel** rejects the request. The persistent indicator on every monitor
offers **Stop sharing**, which ends all active shares. Removing the selected application ends its stream.

Application sharing follows the application and its popups, including when offscreen;
resizing it retains aspect ratio within the stream. Region sharing fixes both the
world position and orientation selected by the rectangle, so subsequent monitor
pan, zoom and rotation do not move the capture. It includes application content and
spatial widgets. Shell controls, consent dialogs and agent overlays are excluded.
Removing the picker’s monitor cancels that pending request. Existing streams continue
on surviving outputs. Changing Worlds closes existing grants and starts a fresh chooser
service in the replacement World.

Up to eight independent sharing sessions can run at once, each with its own source
and consent. Closing one application’s sharing session leaves the others running.
The chooser selects one source per request; it does not select multiple sources
in a single request.

Current stream limits: up to 1920×1080 at 30 fps,
RGBA shared-memory buffers, and hidden cursor mode. There is no audio capture or
persistent consent restoration. Canvas captures use a neutral backing rather than
exporting shell decoration and preserve the desktop's back-to-front window order.
Prepared sessions have a separate bounded quota from active streams, with per-client
limits and cleanup when the client disconnects. The backend deliberately advertises only its supported
source and cursor modes, as specified by the
[ScreenCast backend protocol](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.impl.portal.ScreenCast.html).

## Laptop idle behavior

The portal worker blocks on file descriptors; the capture timer is disarmed with
no active sessions. XWayland starts lazily. Static application shares reuse their
last pixels and keep streaming without output redraws or GPU readbacks. A new
application/popup/subsurface drawable revision invalidates that cache. Region
shares and changing application content still require capture work at up to 30 fps.

Run `make benchmark-idle`, `make benchmark-desktop-idle` and `make test-screencast`.
The latter verifies cached-frame delivery, a real client repaint, simultaneous
streams, and zero capture ticks/output frames after the last stream closes.
The desktop benchmark includes two differently sized outputs, two HTML bars,
real Wayland and X11 clients (including an X11 popup), and the enabled portal.

Measurements on Intel Iris Xe / Mesa 26.0.8, headless GLES2, 2026-09-21:

| Scenario | Interval | Process CPU | Output frames | Capture ticks |
| --- | ---: | ---: | ---: | ---: |
| Previous commit `942bd73`, shell + assistant | 5.001 s | 0.389 ms | 0 | n/a |
| Current shell + assistant | 5.001 s | 0.322 ms | 0 | n/a |
| Current full integrations, two outputs | 3.001 s | 0.374 ms | 0 | 0 |
| After closing concurrent shares | 2.001 s | 0.438 ms | 0 | 0 |

The full integration sample used about **0.013% of one CPU core**, with zero Lisp
allocations during the sample. These short runs show no measurable idle regression;
they are diagnostic results, not machine-independent CPU or battery-life guarantees.
The baseline used an isolated source snapshot and the same compatible native build.
The live DRM desktop had an active 1378×1080 canvas-region share during review:
a 15-second sample used 10.394 seconds of process CPU (about 69% of one core),
with 441 region captures. This active workload still has substantial readback/copy
cost; the static application cache does not apply to canvas regions. It was not
treated as an idle measurement. Physical laptop battery/power measurements remain
separate.

## Drag previews

Wayland drag icons (including Firefox tab previews) follow their seat’s pointer
above windows. Kernel exposes the committed surface tree and protocol offsets;
World owns its screen position, damage and drawing. Canvas zoom and rotation do
not change the preview. Frame callbacks continue during a stationary drag, and
drop targets use the pointer’s current position. Drop, cancellation and client
exit remove the preview. `make test-drag` exercises actual Wayland input and GLES
pixels; the sharing test also decodes two simultaneous PipeWire streams.

Detached Firefox tabs open with their top-left corner at the release point in
the infinite world, including on another monitor or a zoomed/rotated viewport.
World snapshots that point before the drag ends and applies it to the next new
toplevel from the same Wayland connection. This overrides saved/default placement
and keeps the detached window on the free canvas. A drop accepted by another app,
ordinary non-tab drags and cancelled drags do not establish a placement hint.
Unclaimed hints expire after five seconds or the next button/key press, without
an idle timer. The native regression also covers delayed mapping, source surface
destruction and unrelated clients sharing an application ID.

Native helpers expose client pointers and listener primitives to Runtime only.
Runtime owns typed connection wrappers and listener cleanup; Kernel allocates
stable connection identities in its normal object registry. World sees only
those opaque identities. No Firefox detection, placement or expiry lives below
World. Native listener libraries remain loaded while their listeners are alive.

Run `make test`, `make test-qol` and `make test-computer-use` for regression coverage.
See [the QA checklist](METAWORLD-QA.md) for dependencies and the limits of headless
testing. Replacing the loaded core native libraries requires a fresh compositor
process; Lisp updates and new additive native helpers can be loaded on the owner
thread without replacing live protocol objects.
