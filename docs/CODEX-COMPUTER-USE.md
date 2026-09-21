# Ataxia computer use

Ataxia's JavaScript `cua` API is centered on stable windows and an infinite World.
Each monitor is an independent camera; its screenshot cannot represent all apps
or their placement. The familiar app/tab methods remain compatible with the
supplied Computer Use interface. The existing data-only Unix socket API remains supported.

The JavaScript client is in `sdk/computer-use/`; `index.d.ts` describes the complete public surface. The native host is an optional World service; each World supplies its desktop and capture implementation. See [ownership and integration](COMPUTER-USE-DESIGN.md). `scripts/cua_repl` exposes persistent JavaScript as an MCP tool or CLI. The agent skill is in `skills/ataxia-computer-use/` and includes the supplied confirmation policy.

## Quick start

Build with `make computer-use`. Native applications require Python 3 with PyGObject and AT-SPI (`python3-gi`, `gir1.2-atspi-2.0` on Debian/Ubuntu), an accessibility-enabled application, and the running Ataxia computer-use service. The REPL requires Node.js 22 or newer. It has no npm runtime dependencies and does not call a model API.

```bash
scripts/cua_repl --session work <<'JS'
await cua.ataxia.getWorld();
JS
```

The first native request creates an active session automatically. Ataxia's **Agent sessions** panel displays activity and provides **Pause**, **Resume**, **Disconnect**, and **Pause all**. Human takeover, session expiry, and explicit stop controls still apply. The adapter does not automatically resume a paused session.

```javascript
var app = await cua.ataxia.getWindow(windowId); // choose an ID from getWorld()
// Use actual indices from the emitted tree:
await app.setValue(12, 'hello');
await app.click(18);
await app.getAXState();

var browser = await cua.getBrowser();
var tab = await cua.createBrowserTab(browser.browserId, 'https://example.com');
await tab.markDeliverable();
```

Bindings persist across calls using the same session. Await every operation; detached UI promises are unsupported. Bare expression values are suppressed, so observations are not printed twice. `nodeRepl.write` emits text and `nodeRepl.emitImage` emits PNG/JPEG/WebP. CLI images are written mode 0600 into the private runtime directory; MCP returns image content directly.

`scripts/cua_repl --session work --stop` deliberately disconnects native control and stops managed child processes. Session daemons persist until stopped or the user's runtime directory/session ends. Their sockets are mode 0600 inside a mode 0700 directory. The JavaScript REPL is trusted local code execution, not a security sandbox.

## Codex connection

Run `scripts/cua_repl --stdio` as an MCP server. The tool is named `cua_repl`. It supports the initialize-based MCP versions through `2025-11-25`, with JSON-lines stdio, tool discovery, image output, and cancellation. Newer clients can negotiate this protocol family.

```toml
[mcp_servers.ataxia_computer_use]
command = "/absolute/path/to/ataxia/scripts/cua_repl"
args = ["--stdio"]
startup_timeout_sec = 10
tool_timeout_sec = 75
```

This follows [Codex's stdio MCP configuration](https://developers.openai.com/codex/mcp). MCP sessions use `CODEX_THREAD_ID` when present, otherwise the parent process ID; explicit `--session` or `ATAXIA_CUA_SESSION` overrides that choice. CLI calls should use an explicit task session name. Reconnecting the MCP client preserves bindings for the same session. A cancelled or timed-out evaluation terminates its worker, disconnects native input, stops its managed children and resets bindings; it never retries uncertain actions. See the [MCP lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle) and [cancellation contract](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation).

For skill discovery, link `skills/ataxia-computer-use` into `~/.codex/skills/ataxia-computer-use`. The local installation also links `scripts/cua_repl` to `~/.local/bin/cua_repl`. Newly installed tools and skills are available when Codex reloads its configuration or starts a new session.

## Compatibility

| Supplied contract | Ataxia behavior | Limits/differences |
| --- | --- | --- |
| `getState`, apps/browser/tab inventory | Implemented, independent inventories and partial errors | Native inventory needs an active session; usage timestamps/counts are adapter-local |
| `getApp` by name, ID or full path, launch as needed | Installed desktop IDs, names, desktop-file/executable paths, runtime app-ID aliases | Linux desktop identity replaces bundle identity; ambiguous matches throw; unusual runtime IDs may require `getWindow` |
| `getBrowser`, `createBrowserTab`, `getTab` | Implemented; selection does not open a tab; initial AX emits | Chromium CDP providers only; no `iab` or extension provider |
| `visible`, `sessionName` before tab creation | Background-tab flag and isolated browser context applied before creation | Visibility does not hide an existing browser window; contexts are not durable browser profiles |
| AX state, default diffs, full state | Native AT-SPI and Chromium accessibility trees, stable indices, removals/changes/additions | Custom-drawn/native inaccessible controls use screenshots; bounded trees/text |
| Screenshot and combined observation | PNG bytes with coordinate scaling and internal settle | Screenshot-only observations invalidate indices; next tree is full |
| Click, multiple clicks, mouse buttons, drag, keys, scroll | Native agent seat or renderer input; page-relative scroll | Native apps must bind the agent seat; browser key aliases cover common XKB navigation/modifier/numpad keys |
| Native window placement, floating/tiling, groups and workspaces | `cua.ataxia` desktop methods backed by World APIs; see the [desktop reference](../skills/ataxia-computer-use/references/desktop.md) | CUA native keys bypass compositor shortcuts, pointers cannot operate World chrome, and `getWindow` does not switch the user's workspace; desktop changes use revisions and respect pause/disconnect |
| `typeText` | Unicode input; native scalar-safe chunks, Chromium text insertion | Native typing is slower for large text; use paste or setValue |
| `paste` text/Markdown/HTML | Native MIME source + Ctrl+V; browser text insertion or contenteditable HTML paste | Native 16,000-character limit. Human clipboard is untouched. Browser clipboard is also untouched, unlike the supplied browser paste side effect. Native HTML needs a compatible receiver |
| `selectText`, prefix/suffix, cursor placement | Native Unicode text offsets and browser input/contenteditable selection | Matching text must be unique; protected fields and unsupported controls throw |
| `setValue` | Native Value/EditableText, browser input/textarea/select/contenteditable | Application must expose/accept the operation; read-only and file-upload controls are rejected |
| `performSecondaryAction` | Native advertised action names; browser Expand/Collapse from AX expanded state | Do not guess actions; other browser actions use normal click/keys |
| Tab history, reload, close | Implemented, state settles after navigation | Inspect visible state for page-specific navigation errors |
| `markDeliverable`, `markHandoff` | Retains marked tabs during normal cleanup and records their purpose | Managed tabs depend on the persistent daemon; explicit stop/close still closes them |
| Automatic output, `emit:false`, first-use docs | Implemented, with persistent `nodeRepl` output helpers | Host SDK callers provide an emitter; only REPL calls automatically return its output |

The public method surface is complete. Behavioral equivalence depends on app accessibility and the available browser provider; the differences above are intentional or platform limitations.

## Browser setup

The default provider discovers an installed Chromium/Chrome or a Playwright-downloaded Chromium, launches an isolated temporary profile, and uses a debugging **pipe**, with the browser sandbox enabled. Set `ATAXIA_CUA_BROWSER` to choose its executable. `ATAXIA_CUA_BROWSERS` can point to a trusted JSON array:

```json
[
  {"id":"work","name":"Work browser","type":"cdp","endpoint":"http://127.0.0.1:9222"}
]
```

An attached provider operates the profile exposed by that endpoint; it does not silently attach to existing browser profiles. Only configured loopback endpoints are accepted. Host flags/configuration are separate from page content. Native Firefox remains usable through `getApp`; its tabs are not exposed through this CDP provider.

On this Ubuntu machine the downloaded Chromium is blocked by AppArmor's user-namespace policy. Production launch requires a system-installed, sandbox-compatible Chrome/Chromium or an already configured endpoint. No host protections were changed. The local disposable browser regression fixture uses `--no-sandbox` solely for its generated local pages; that flag is never a production default. See [Chromium's official AppArmor guidance](https://chromium.googlesource.com/chromium/src/+/main/docs/security/apparmor-userns-restrictions.md).

## Ataxia additions

`getWorld()` reports windows, membership, intended world geometry and separate
output cameras. `getDesktop()` remains its structured-state alias. `listWindows()`
discovers mapped windows outside every viewport, and reports target availability
separately from intersection with the session output. `getWindow(id)` captures and
controls that window directly; it never needs to move the human camera. `getApp`
requires explicit window selection when multiple windows match, and does not
launch another process just because the existing window is unavailable.

`captureViewport()` captures only the session output's current view and restores
the prior input view; `captureDesktop()` is its alias. Captures identify their
output/window, coordinate space, dimensions and popup origin. Native app methods
always select window view. Pointer actions reject a stale screenshot after a
resize or popup-bounds change instead of applying old pixels to new geometry.

The remaining `cua.ataxia` operations include `connect`, `status`, `capabilities`,
`batch`, `tabMarks`, `metrics`, and `disconnect`. The native protocol provides an
active-session-checked `target` query with a compositor-verified client PID,
seat-local paste, revision-checked layout preview/apply/Undo, window controls and
navigation. `arrange` accepts the active World's layout language; `moveWindow` and
`setFloating` require its `place-window` schema. Workspace limits belong to World.
Automatic AX observations tolerate continued updates; explicit stability waits
remain strict. The optional World-owned `libataxia-cua.so` supplies native client
and clipboard queries.

Native semantic actions validate the active selected target against the compositor before and after AT-SPI operations and reject stale/detached elements. The human clipboard is preserved by using a separate clipboard source on the agent's Wayland seat. Clipboard writes are asynchronous with bounded transfers and timeouts. Browser automation is scoped to the configured provider; it does not inherit Ataxia's native-session state. The skill's consequential-action policy applies to both.

## Efficiency and verification

Keep deterministic action sequences and their final observation in one REPL call. Native batches cross the socket once per batch, execute serially under the existing ownership checks, and settle inside the compositor. Native batches are not transactions: earlier actions may have happened when a later action fails. Browser observations wait for renderer quiet internally. AT-SPI and CDP connections remain open between calls. `setValue`/selection avoid screenshot interpretation; native paste avoids per-character synthetic typing. No speculative retry replays an input request.

The real Chromium fixture measured a 2,738-character full AX observation and a 569-character changed-state observation after editing and applying a value, a 79% reduction. This is a fixture measurement, not a general speed claim or comparison against Codex's implementation. `cua.ataxia.metrics()` exposes transport request counts for further measurements.

Run `make test-computer-use` for the existing protocol/input/capture suite and `make test-cua` for the new adapter. The latter uses an isolated headless compositor, private D-Bus, a GTK application, generated local Chromium pages, and the actual persistent REPL/MCP transport. It covers automatic activation, pause/resume, pause all and disconnect, trusted PID binding, Unicode text selection/value/input, clipboard paste, secondary actions, AX diffs, stale indices after screenshots, browser frames, navigation, partial inventory failure, output suppression, persistent bindings, cancellation/timeouts, and private socket permissions. Images are saved as `build/cua-native.png` and `build/cua-browser.png`.

The supplied skill/interface is the compatibility specification. The public [OpenAI computer-use guide](https://developers.openai.com/api/docs/guides/tools-computer-use) describes a separate tool integration and does not independently specify this JavaScript surface. Native accessibility follows [AT-SPI Text](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/iface.Text.html) and [EditableText](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/iface.EditableText.html); browser operations use the [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/).

After source changes, start a fresh CUA session to load the JavaScript client.
Changes to native libraries or session structures take effect in a new
compositor process; restart through the normal desktop lifecycle when appropriate.
