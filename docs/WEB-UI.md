# Browser UI components

`ataxia-web` embeds real Chromium HTML, CSS and JavaScript through CEF's
[offscreen rendering interface](https://chromiumembedded.github.io/cef/general_usage#off-screen-rendering).
React, Svelte, ES modules, CSS Grid, Canvas, WebGL and browser animations run in
the browser engine. There is no translation into RML or Slint.

This is an optional World adapter. Neither Kernel nor Runtime knows about web
pages, DOM nodes, JavaScript, Chromium processes or this adapter. No concrete
World implementation needs a browser-specific path.

## Build

```sh
make                         # includes the browser helper for the default shell
make web-example
```

The pinned Linux x86-64 SDK is CEF 154.0.32 / Chromium 154.0.8037.58. The fetcher
verifies its SHA-256 before extraction. The compressed download is about 326 MB;
allow several GB for the SDK/build. Dependencies are Python 3.12+, a C++20
compiler, CMake 3.21+, Ninja, pthreads, and GLES development libraries, plus CEF's
normal Linux runtime libraries. The accelerated adapter also requires GBM/libdrm,
EGL DMA-BUF import with modifiers, native fences, and GLES 3.0+. The
framework example additionally uses Node/npm and a committed lockfile.

`CEF_ROOT=/path/to/compatible/cef-sdk make web` selects an existing SDK. The
included download is x86-64 only; other architectures need their corresponding
SDK and have not been tested. Runtime resources and the CEF license remain in
the SDK directory and are linked into `build/web-native/`. Distribute them
alongside the helper, including CEF's license/credits; do not ship the executable
alone. `ATAXIA_WEB_HELPER` and `ATAXIA_WEB_NATIVE` override the helper and small
native bridge library paths.

Chromium sandboxing is enabled by default. On Ubuntu installations that restrict
unprivileged user namespaces, review and install the per-executable policy:

```sh
scripts/install-web-sandbox --print
sudo scripts/install-web-sandbox
```

This grants `userns` only to the configured helper, following the distribution's
Chrome profile pattern. It does not disable AppArmor or change the global
user-namespace restriction. Reinstall the rule if the executable moves. The
adapter never retries with `--no-sandbox`. A failed helper reports an asynchronous
`error` event and leaves the World running.

## Use from a World

Load the system in the usual controlled development workflow. Creation and
component operations run on the World owner, just like the other native UI
adapters. Do not reload arbitrary systems in a running compositor.

```lisp
(asdf:load-system "ataxia-web")

;; WORLD is the current World on its owner thread.
(ataxia.world.web:make-web-widget
 world
 :asset-root (asdf:system-relative-pathname "ataxia-web" "examples/web-ui/dist/")
 :x 40d0 :y 80d0 :width 640d0 :height 240d0
 :callbacks '("react-count" "svelte-count" "text" "error"))
```

A widget can instead use `:source "<!doctype html>..."`,
`:source-path #p"/path/to/site/index.html"`, or
`:url "http://127.0.0.1:5173/"` for a framework dev server with its own hot reload.
Supply one of those content sources, or an `:asset-root` directory containing
`index.html`. Inline HTML gets a private temporary directory that is removed
when the component is destroyed.

Local bundles are served at `ataxia://ui/` as a standard secure Chromium scheme
with normal module and fetch support. The adapter confines file resolution to
the selected asset directory, including symlinks. It does not relax CORS or CSP.
Each component has its own in-memory browser request context, so two independent
bundles do not share cookies/storage merely because they use the same local URL.
An HTTP(S) dev server also works; React and Svelte need no Ataxia plugin.

The example builds React and Svelte into one page, with text actions, rectangular
geometry, a monospace face and the existing high-contrast design vocabulary.

## Lisp and JavaScript

Inside the page:

```js
ataxia.postMessage('counter', {value: 3});
addEventListener('ataxia-message', event => {
  const {name, value} = event.detail;
  // Update framework state here.
});
```

On the owner:

```lisp
(ataxia.world:bind-agent-widget-event widget "counter"
  (lambda (widget event)
    ;; EVENT-VALUE is JSON text, copied before invoking this callback.
    (format t "~A~%" (ataxia.world:agent-widget-event-value event))))

(ataxia.world:set-agent-widget-property widget "text" "Updated from Lisp")
(ataxia.world.web:post-web-message
 (ataxia.world:overlay-component widget) "items" "[1,2,3]")
```

`ui-set-property` sends a named message with a scalar string, number or boolean.
It does not mutate React/Svelte's DOM behind the framework. `post-web-message`
accepts JSON for structured values. `evaluate-web-javascript` queues arbitrary
JavaScript for explicit host-side development; it never synchronously waits for
a result. JavaScript can reply through `ataxia.postMessage`. This bridge does
not expose Lisp evaluation, shell execution or host objects to the page.

Callbacks include `created`, `load` (HTTP status), `error`, `open-url` (a request
for another window), and application-defined names. New browser windows are
reported to the World through `open-url`; no unmanaged native browser window is
created. HTML select popups are additional ordinary surfaces on the same drawable
with DMA-BUF transport, or composited into its bitmap in compatibility mode.
Context menus are left to page code instead of creating external browser UI.

Queue limits are explicit: commands are under 60,000 UTF-8 bytes, event names
under 80 bytes, JSON event values under 8,192 bytes, and the event ring holds 32
entries. Overflow is counted in `web-component-stats` as `:dropped-events`.
Batch application state into messages instead of streaming per-pixel events.

## Existing contracts and ownership

`web-component` implements exactly the existing `drawable` and `interactable`
contracts: local bounds, surfaces, GLES render sources, damage, graphics attach/
detach, pointer/axis/key/focus delivery and object state/configuration. Rendering
publishes the same textured quad consumed by other World objects. The component
also implements the shared World `ui-*` lifecycle/property/callback protocol.

`make-web-widget` uses `create-agent-widget` and the existing overlay host
protocol. Lookup, positioning, resizing, event history and removal work through
`ataxia.world`. The small `web-widget` subclass adds only the existing visibility
notification. A World without overlays can use `make-web-component :world world`
directly and include it in its own scene, forwarding visibility through
`request-object-state :visible` or `set-web-visible`.

One optional World service owns one helper process and the event descriptors.
Multiple components share that browser host; Chromium manages renderer/GPU/
network subprocesses. The Lisp process loads only a small IPC/GLES library,
not `libcef`. Shared memory contains bounded copied messages and bitmap compatibility storage;
it contains no Lisp callbacks or World pointers. Accelerated frames cross the
local socket as DMA-BUF descriptors, plane layouts, formats and modifiers. Browser events arrive through an
eventfd and are dispatched on the owner. The private command socket is local to
the helper; there is no debugging port or network control service.

Removal retires GL resources through the existing World graphics lifecycle.
The last component releases the helper; World quiescence stops its event sources.
Shutdown/reaping runs off-owner with a bounded deadline. A helper crash closes
its channel, reports failure, and leaves existing World operation intact;
ordinary input to a failed component returns `:unavailable`. Creating a new
component starts a fresh helper.

## Scheduling and performance

There is no polling timer, screenshot loop, or continuous request for compositor
frames. Chromium's message loop blocks until it has work. A paint publishes a
notification, the ordinary widget invalidator requests an output frame, and
`drawable-prepare-frame` selects the newest DMA-BUF texture once. Bitmap
compatibility mode uploads the accumulated dirty rectangle instead. Static
components return before touching GLES, even when another object redraws.
Several browser paints before presentation coalesce into a single pending frame.

Visible animation is capped at 60 browser paints per second. Hidden widgets,
zero-opacity widgets, disconnected outputs and widgets outside their output's
bounds call Chromium's `WasHidden`, which suspends visual rendering and applies
browser background throttling. Visibility is updated from existing World events
and frame hooks, with no visibility polling timer. Custom scenes must forward
their own visibility changes. Occlusion behind another opaque object is not
currently inferred. JavaScript that deliberately runs a busy loop or frequent
timers still consumes browser CPU; hiding is not arbitrary-script suspension.

DMA-BUF transport is the default when a Wayland display is available. The World
adapter passes its Runtime's existing socket name to the helper; it does not
depend on the compositor inheriting `WAYLAND_DISPLAY` or change the host's
environment. A standalone native host can use `WAYLAND_DISPLAY`. CEF's
Wayland platform supplies accelerated offscreen frames; it does not create shell
windows or give the World a browser-specific rendering path. The pinned CEF
headless platform cannot allocate these frames. With no Wayland connection the
adapter uses bitmap compatibility mode. `ATAXIA_WEB_TRANSPORT=bitmap` explicitly
selects it; `ATAXIA_WEB_RENDER_NODE=/dev/dri/renderD128` selects the helper's GBM
render device on machines with multiple GPUs. Bitmap transport does not emulate
a GPU: WebGL still requires Chromium's graphics backend to initialize; the
display-less fixture could render HTML but could not initialize WebGL2.

Accelerated pixels stay on the GPU. The helper copies CEF's borrowed frame into
an owned GBM buffer, then passes its descriptors to the compositor. The existing
World graphics scope imports that buffer as an EGLImage and samples its texture
directly. There is **no CPU readback, pixel conversion, shared-memory pixel copy,
or texture upload** in this path. Imported textures are cached per buffer.

This is **zero-copy transport, not end-to-end zero-copy**: the public CEF
[paint callback contract](https://github.com/chromiumembedded/cef/blob/master/include/cef_render_handler.h)
recycles the source immediately on return and requires a client-owned copy.
Retaining a duplicated source descriptor would race Chromium's reuse. Removing
that final GPU copy needs an upstream CEF frame lease/release API (and a custom
CEF build); it cannot safely be done by holding the descriptor longer.

A pool holds at most three buffers per view or popup. The helper completes its
GPU copy before returning CEF's borrowed frame. The compositor exports a native
release fence after sampling; the helper waits on it on the GPU before reuse.
The owner never waits for a browser paint or GPU completion. A slow consumer
coalesces frames and requests a fresh frame when a buffer becomes available;
there is no unbounded frame queue or polling timer. Each buffer's descriptors,
images and fences are released on resize, retirement, detach or engine shutdown.

Each component keeps its own logical size and raster scale, including mixed-DPI
outputs. The Wayland CEF adapter uses local device metrics after page load to
match logical input to physical backing dimensions; no debugging port is opened.
Native select popups use CEF's native raster density and are scaled by the GPU
when necessary. Custom HTML menus use the full component raster density.

Bitmap compatibility mode retains dirty-rectangle uploads. Physical rasters are
capped below 4096 per side by reducing raster scale, and logical viewports are
limited to 16384 CSS pixels per side. Continuously animated large pages still
cost GPU bandwidth, and Chromium's renderer processes have their own CPU cost.

Use `web-component-stats` for transport, paints, GPU copies/imports, skipped
frames, CPU texture uploads, uploaded bytes, visibility and errors; use `web-engine-pid` to measure the complete browser process tree.
The browser runtime is substantially larger in memory and on disk than RmlUi.
Choose it where actual browser behavior is needed, and keep simple shell chrome
on the lighter existing engines.

## Browser status bar and menus

```lisp
(asdf:load-system "ataxia-web/status-bar")
;; On the World owner, after controlled system installation:
(ataxia.world.web.shell:enable-web-status-bar world)
```

Metaworld and its standalone Niri/Hyprland modes enable this presentation by
default on desktop backends, independently of the assistant. Use
`--no-status-bar` to omit it or `--status-bar` to enable it in a headless session.
`make web` builds just the browser adapter. The Ubuntu sandbox setup above is
required before its first launch on systems restricting user namespaces.

Enabling the service replaces the current bar with a web bar on each output, plus application
search/launch, battery/brightness/sleep, audio/media, clipboard history,
navigation menus, and hardware-key feedback. The assistant entry opens the HTML chat panel. Text actions invert foreground/background; corners stay
square, vertical padding stays compact, and horizontal spacing uses shared constants.
The browser documents are ordinary editable HTML/CSS/JavaScript in
`src/world/web/status-bar/`, with no RML translation or npm build step.


All built-in presentations now use real HTML: the assistant (including local model
and voice controls), agent sessions and cursor labels, sharing chooser and region
indicator, launcher, notifications, Metaworld headers/toolbar/notes, and Atlas panel.
The general Slint/RmlUi adapters and explicit RML app-preview tool remain available
for documents that request those formats; default compositor UI does not use them.

`ataxia-web/ui` provides reusable document components and widgets independently of
any concrete World or shell. `src/world/web/ui/document.css` holds the common
monospace theme; `document.js` binds DOM controls to cached models and events.
Built-in documents share the repository's `src/` asset root. User web components
continue to use their own explicitly supplied roots.

Text actions invert over 100 ms; panels enter over 180 ms. These finite effects
respect reduced-motion settings and leave no animation timer running after settling.
Clipboard transfers use the originating seat and cancel when focus changes.
Large Unicode model/event payloads use bounded chunks with acknowledgements, avoiding
native event-queue overflow. Ctrl+Enter submits after the browser has processed
pending edits. The browser adapter uses GTK3 to avoid CEF's GTK4 settings fallback,
and defers closing a view that was dismissed during asynchronous creation.

`make test-web-ui` exercises native Unicode input, large clipboard round trips,
large escaped transcripts, native select controls and idle. The migrated assistant
measured **zero additional paints/imports and 0.194 ms compositor CPU over 3 seconds**
after edits and animations settled in the headless fixture. This measures the Lisp
process; process-tree browser idle is checked separately by `make test-web`.
The updated live shell also measured 0 ms CPU across its 12 browser processes
over a five-second settled sample (10 ms OS accounting resolution).

`ataxia-shell` owns the shared controllers and shell policy in `src/world/shell/`.
It has no RmlUi or Chromium dependency. RmlUi and web presentations implement the
same small presentation methods and existing `agent-widget` lifecycle. The web
module does not need a concrete World subclass or a Kernel change.

Only changed values are sent, batched on a one-shot owner idle callback. There
is no JavaScript clock, animation loop, or device polling. The existing shell
uses a minute-aligned clock/battery deadline and subscription-driven audio/media
workers. Opening a menu creates a browser view; closing it retires that view.
All views share the World browser helper. Use
`ataxia.world.shell:disable-status-bar` to remove either presentation, or
`ataxia.world.shell:enable-rmlui-status-bar` after loading its optional system to
switch back explicitly. Startup uses the HTML presentation.

`make test-web-shell` checks startup selection and opt-out, native clicks/typing
and application launch, the menus, idle behavior and lifecycle cleanup. The original RmlUi shell tests also
cover the extracted shared controllers.

Live deployment was also verified without a World restart. The bar reported
DMA-BUF transport and zero uploaded pixel
bytes. After closing the menus, the eight-process browser tree used no measurable
CPU in a five-second sample (10 ms process-accounting resolution).

## Compatibility and verification

Compatibility is that of the pinned Chromium build, not a claim that every web
standard or browser feature is implemented. Framework programming, CSS/JS
animations, DOM events, Canvas/WebGL, modules and fetch use the real engine.
The current host adapter does not provide browser chrome, file-picker UI,
permission UI for camera/microphone/screensharing, external drag-and-drop,
Wayland clipboard synchronization, accessibility export, or IME preedit.
These need explicit World-side host integration; the current copied input
contract supports ordinary key/text/pointer input. Persistent profiles and
service-worker deployment on the custom scheme are not promised.

```sh
make test-web
```

Tests exercise real React and Svelte bundles alongside Slint/RmlUi; pointer,
keyboard and popup interaction; local ES modules/fetch; Grid, WebGL2, alpha and
orientation; DMA-BUF pixels, GPU buffer reuse, bitmap partial uploads and GL state isolation; CSS and Web
Animations; hidden/offscreen rendering; device scale; resize; process sharing;
cleanup; helper-crash recovery; and a separate World with no UI-host inheritance.

Idle checks count compositor frames, browser paints and uploads, and sample the
CPU of the browser process tree. Focused text fields blink their caret and are
therefore animated content; the static idle fixture explicitly removes focus.

On the development Intel Iris Xe laptop, the sandboxed fixture recorded zero
paints/uploads over five seconds and 20 ms of CPU across all nine browser
processes (0.4% of one core). Accelerated tests recorded zero CPU-uploaded bytes
and reused a bounded set of imported textures across animation frames. The mixed World recorded zero frames/paints and
0.26 ms of compositor CPU over three seconds. The browser shell recorded no
paints/imports and 0.21 ms of compositor CPU over three seconds. These are short samples, not
universal budgets. The test accounts for children forked from non-main threads
and verifies renderer seccomp/no-new-privileges state. A separate live demo
rendered both frameworks, delivered clicks, and used 20 ms of browser-tree CPU
in a three-second idle sample without restarting the compositor.

For a repeatable full-repaint workload, run `python3 tests/web-throughput.py` and
then `ATAXIA_WEB_TRANSPORT=bitmap python3 tests/web-throughput.py`. At 1280×720,
the five-second animated fixture delivered about 60 frames/s in both modes.
DMA-BUF used 3.17 s of browser-tree CPU and 0.136 s of consumer CPU, versus
5.10 s and 0.760 s for bitmap transport: about 44% less combined CPU for this
specific workload. It eliminated 1.11 GB of CPU texture uploads in that sample.
This is a synthetic repaint workload on the development laptop, not a general
application benchmark; CSS/JS layout cost and GPU bandwidth still matter.
