# API reference

The globals in `cua_repl` are `cua: Cua` and `nodeRepl: NodeRepl`. For direct host integration, import `createCua` from `sdk/computer-use/index.mjs`; host configuration is not browser/page input.

```typescript
export type Vec2 = [x: number, y: number];
export type ObservationOptions = { emit?: boolean };
export type StateOptions = ObservationOptions & { disableDiffing?: boolean };
export type StateAndScreenshot = { state: string; screenshot?: Uint8Array };
export type PasteOptions = { format?: 'text' | 'md' | 'html' };
export type ClickOptions = { mouseButton?: MouseButton; clickCount?: number };
export type SelectTextOptions = { prefix?: string; suffix?: string; selectionType?: SelectionType };
export type Direction = 'up' | 'down' | 'left' | 'right' | 'u' | 'd' | 'l' | 'r';
export type SelectionType = 'text' | 'cursor_before' | 'cursor_after';
export type MouseButton = 'left' | 'right' | 'middle' | 'l' | 'r' | 'm';
export interface Target {
  getAXState(options?: StateOptions): Promise<string>;
  getScreenshot(options?: ObservationOptions): Promise<Uint8Array>;
  getAXStateAndScreenshot(options?: StateOptions): Promise<StateAndScreenshot>;
  paste(text: string, options?: PasteOptions): Promise<void>;
  click(target: number | Vec2, options?: ClickOptions): Promise<void>;
  drag(from: Vec2, to: Vec2): Promise<void>;
  pressKey(key: string): Promise<void>;
  scroll(target: number | Vec2, direction: Direction, pages?: number): Promise<void>;
  selectText(elementIndex: number, text: string, options?: SelectTextOptions): Promise<void>;
  setValue(elementIndex: number, value: string): Promise<void>;
  typeText(text: string): Promise<void>;
  performSecondaryAction(elementIndex: number, action: string): Promise<void>;
}
export type AppInfo = { id: string; displayName?: string; lastUsedDate?: string; useCount?: number; isRunning?: boolean; windowIds?: number[] };
export interface App extends Target { readonly windowId: number }
export type BrowserInfo = { id: string; name?: string; family?: string; type?: 'iab' | 'extension' | 'cdp'; profileName?: string; metadata?: { extensionInstanceId?: string; codexSessionId?: string } };
export type BrowserTabInfo = { id: string; providerTabId?: string; title?: string; url?: string };
export interface Browser { readonly browserId: string; documentation(): Promise<string> }
export interface BrowserProvider { list(): Promise<BrowserInfo[]>; get(id: string): Promise<Browser> }
export interface BrowserState extends BrowserInfo { tabs: BrowserTabInfo[] }
export type TabInfo = BrowserTabInfo & { browserId: string };
export type State = { apps: AppInfo[]; browsers: BrowserState[]; errors?: string[] };
export type BrowserOptions = { browser?: string };
export type GetBrowserOptions = { id?: string; url?: string };
export type CreateBrowserTabOptions = { visible?: boolean; sessionName?: string };
export interface Tab extends Target {
  readonly id: string;
  goto(url: string): Promise<void>;
  back(): Promise<void>;
  forward(): Promise<void>;
  reload(): Promise<void>;
  close(): Promise<void>;
  markDeliverable(): Promise<void>;
  markHandoff(): Promise<void>;
}
export type NativeSession = { id: number; name: string; state: 'pending' | 'active' | 'paused' | 'disconnected' | string; sequence: number; busy: boolean; output: number; view: 'window' | 'desktop'; window?: number; message?: string };
export type WindowInfo = { id: number; pid?: number; title: string; 'app-id': string; x: number; y: number; width: number; height: number; selected?: boolean; available: boolean; 'on-output': boolean; 'coordinate-space': 'window-local'; 'origin-x': number; 'origin-y': number; input: { pointer: boolean; keyboard: boolean } };
export type BatchAction = { op: 'focus' | 'view' | 'move' | 'button' | 'scroll' | 'key' | 'type' | 'paste' | 'launch' | 'wait-window' | 'wait-stable'; [key: string]: unknown };
export type Capture = { path: string; width: number; height: number; 'coordinate-width': number; 'coordinate-height': number; 'coordinate-space': 'window-local' | 'output-local'; 'origin-x': number; 'origin-y': number; view: 'window' | 'desktop'; window: number | null; output: number; timestamp: number; bytes: Uint8Array };
export type DesktopWindow = { id: number; title: string; 'app-id': string; group?: number | null; workspace?: number | null; floating?: boolean; column?: number | null; geometry?: number[]; minimized?: boolean; maximized?: boolean; fullscreen?: boolean; visible?: boolean; available?: boolean; 'on-outputs'?: number[] };
export type DesktopGroup = { id: number; name: string; policy: string; workspace: number; 'workspace-count': number; members: { window: number; workspace: number; floating: boolean; column: number }[]; [key: string]: unknown };
export type WorldState = { revision: number; generation: number; world: string; 'coordinate-space'?: 'world'; output: number; windows: DesktopWindow[]; groups?: DesktopGroup[]; outputs: { id: number; name?: string; group?: number | null; camera?: [x: number, y: number, zoom: number, rotationRadians: number]; position?: [x: number, y: number]; size?: [width: number, height: number]; [key: string]: unknown }[]; capabilities: { snapshot: boolean; layout: boolean; navigation: boolean; scope: 'world'; 'native-shortcuts': false; 'window-actions': string[] }; 'layout-schema': Record<string, unknown> | null; 'layout-description': string | null };
/** Compatibility name for the structured World observation, never a screenshot. */
export type DesktopState = WorldState;
export type Placement = { group?: number | null; workspace?: number; floating?: boolean; x?: number; y?: number; width?: number; height?: number };
export type LayoutValue = string | number | boolean | null;
/** Operations are defined by the active World's layout-schema. */
export type LayoutOperation = { op: string; [key: string]: LayoutValue };
export type MetaworldLayoutOperation = Omit<Placement, 'group'> & { op: 'create-group' | 'configure-group' | 'remove-group' | 'place-window'; group?: number | string | null; window?: number; ref?: string; name?: string; policy?: 'niri' | 'dwindle' | 'master' };
export type DesktopChangeOptions = { revision?: number };
export type ViewportCamera = { x?: number; y?: number; zoom?: number; rotation?: number };
export type FrameOptions = DesktopChangeOptions & { padding?: number; rotation?: number };
export type LayoutPreview = { plan: string; revision: number; operations: LayoutOperation[] };
export type DesktopResult = { ok: true; session: NativeSession; desktop: DesktopState; undo?: string };
export interface AtaxiaExtensions {
  connect(options?: { name?: string; purpose?: string; output?: number }): Promise<NativeSession>;
  status(): Promise<NativeSession>;
  capabilities(): Promise<Record<string, unknown>>;
  listWindows(options?: ObservationOptions): Promise<WindowInfo[]>;
  getWindow(id: number): Promise<App>;
  getWorld(options?: ObservationOptions): Promise<WorldState>;
  /** Compatibility alias for getWorld(). */
  getDesktop(options?: ObservationOptions): Promise<DesktopState>;
  previewLayout(operations: LayoutOperation[], options?: DesktopChangeOptions): Promise<LayoutPreview>;
  applyLayout(plan: string): Promise<DesktopResult>;
  arrange(operations: LayoutOperation[], options?: DesktopChangeOptions): Promise<DesktopResult>;
  undoLayout(undo: string): Promise<DesktopResult>;
  moveWindow(id: number, placement: Placement, options?: DesktopChangeOptions): Promise<DesktopResult>;
  setFloating(id: number, floating: boolean, options?: DesktopChangeOptions): Promise<DesktopResult>;
  windowAction(id: number, action: 'close' | 'minimize' | 'restore' | 'maximize' | 'fullscreen', options?: DesktopChangeOptions): Promise<DesktopResult>;
  setViewport(output: number, camera: ViewportCamera, options?: DesktopChangeOptions): Promise<DesktopResult>;
  panViewport(output: number, delta: { dx: number; dy: number }, options?: DesktopChangeOptions): Promise<DesktopResult>;
  frameWindow(output: number, window: number, options?: FrameOptions): Promise<DesktopResult>;
  frameRegion(output: number, region: { x: number; y: number; width: number; height: number }, options?: FrameOptions): Promise<DesktopResult>;
  batch(actions: BatchAction[], options?: { capture?: boolean; settle?: number }): Promise<Record<string, unknown>>;
  /** Capture only the session output's current camera; leaves its view unchanged. */
  captureViewport(options?: ObservationOptions): Promise<Capture>;
  /** Compatibility alias for captureViewport(). */
  captureDesktop(options?: ObservationOptions): Promise<Capture>;
  tabMarks(): { browserId: string; id: string; mark: 'deliverable' | 'handoff' }[];
  metrics(): { nativeRequests: number; browserRequests: number };
  disconnect(): Promise<void>;
}
export interface Cua {
  getState(options?: ObservationOptions): Promise<State>;
  getApp(app: string): Promise<App>;
  listApps(options?: ObservationOptions): Promise<AppInfo[]>;
  getBrowser(options?: GetBrowserOptions): Promise<Browser>;
  createBrowserTab(browserId: string, url?: string, options?: CreateBrowserTabOptions): Promise<Tab>;
  getTab(id: string, options?: BrowserOptions): Promise<Tab>;
  listBrowsers(options?: ObservationOptions): Promise<BrowserInfo[]>;
  listTabs(options?: BrowserOptions & ObservationOptions): Promise<TabInfo[]>;
  readonly ataxia: AtaxiaExtensions;
  [Symbol.asyncDispose](): Promise<void>;
}
export interface BrowserConfiguration extends Omit<BrowserInfo, 'type'> { type?: 'cdp'; executable?: string; endpoint?: string; headless?: boolean; args?: string[] }
export type ImageInput = string | Uint8Array | { bytes: Uint8Array; mimeType?: 'image/png' | 'image/jpeg' | 'image/webp' };
export interface NodeRepl { write(value: unknown): void; emitImage(value: ImageInput): void }
export interface Configuration { socket?: string; token?: string; name?: string; purpose?: string; browsers?: BrowserConfiguration[]; browserConfigFile?: string; headless?: boolean; nodeRepl?: NodeRepl }
export function createCua(configuration?: Configuration): Cua;
export class CuaError extends Error { code: string; details?: unknown }
export class ComputerTransport {
  constructor(configuration?: Pick<Configuration, 'socket' | 'token' | 'name' | 'purpose'>);
  connect(options?: { output?: number }): Promise<{ session: NativeSession }>;
  status(): Promise<{ session: NativeSession }>;
  batch(actions: BatchAction[], options?: { capture?: boolean; settle?: number }): Promise<Record<string, unknown>>;
  disconnect(): Promise<void>;
}
```

## Ataxia extensions

- `connect` creates an active native session automatically; a paused session can be resumed through the activity panel. `status` exposes its current state. `disconnect` releases it.
- `capabilities` reports protocol and provider availability without creating or approving a native session.
- `getWorld` returns structured World state; `getDesktop` is its compatibility alias. Window placement and each monitor camera are distinct from application-local input coordinates. See the [coordinate reference](desktop.md#coordinates-and-viewports).
- `listWindows` discovers mapped windows across the World, including unavailable windows. `getWindow` selects an available window without raising it, moving it, or switching the user's workspace. Selection and target operations explicitly use window view. `getApp` rejects ambiguous matches with candidate IDs and does not relaunch an already mapped but unavailable app.
- `batch` runs up to 16 data-only Ataxia actions with one sequence number; optional capture and settle use compositor frame stability. The existing protocol remains available to other clients. This is sequential execution, not a transaction: a later failure can leave earlier actions applied.
- `captureViewport` (`captureDesktop` alias) captures the session output's current camera, then restores the prior input view. Its metadata names the output and logical coordinate space. It does not show the entire World or move any camera. Refresh accessibility indices afterwards.
- `tabMarks` reports deliverable/handoff tabs, and `metrics` counts native/CDP transport requests in this adapter.

For window placement, floating/tiling, groups, workspaces, shell navigation, and native window close/minimize/restore/maximize/fullscreen, use [Ataxia desktop operations](desktop.md). They are exposed as `getWorld` (`getDesktop` alias), `moveWindow`, `setFloating`, `windowAction`, `setViewport`, `panViewport`, `frameWindow`, `frameRegion`, `arrange`, `previewLayout`, `applyLayout`, and `undoLayout` on `cua.ataxia`. Native keys bypass World shortcuts, and native pointers cannot operate World chrome; `captureViewport` (`captureDesktop` alias) and `settle: 0` do not change that routing.

### Continuously updating applications

`getWindow`, `getApp`, and `getAXState` emit a current accessibility snapshot even when the automatic stability wait times out; the text indicates continued updates. The fallback reads state without replaying input and still enforces target/session checks. Explicit `wait-stable` batches remain strict: their timeout reports failed stability, not whether an earlier action completed. Inspect a fresh window inventory and the batch result's completion count before deciding what remains to do.

When a known application's animation prevents settling, capture its current frame without sending input or waiting for stability:

```javascript
// windowId comes from a fresh cua.ataxia.listWindows() result.
var frame = await cua.ataxia.batch(
  [{ op: 'view', mode: 'window', window: windowId }], { capture: true, settle: 0 });
nodeRepl.write({ completed: frame.completed, image: frame.image });
await nodeRepl.emitImage(new Uint8Array(
  await (await import('node:fs/promises')).readFile(frame.image.path)));
```

The image path is returned by the capture API. This low-level capture does not update an `App` binding's screenshot basis. For subsequent binding coordinate actions, use that binding's `getScreenshot()`; for raw `batch` movement, convert image pixels using the returned coordinate dimensions. Reacquire accessibility state before reusing element indices. Skipping the settle wait can capture an intermediate frame. It does not make desktop shortcuts work.

## Provider boundaries

Native AX depends on Linux AT-SPI and the app exposing usable accessibility. Unsupported/custom-drawn apps retain screenshot, pointer, key and paste controls. Desktop display names, desktop IDs and installed paths replace macOS bundle identities. Native AX is bound to a compositor-verified process and selected window, with active-session state checked before and after semantic actions.

Browser support is Chromium CDP only. `iab` and browser-extension providers are not implemented; do not claim access to a user's existing browser profile unless a host-configured CDP provider supplies it. `getBrowser` does not create a tab. `visible:false` creates a background tab; it does not hide an existing browser window. `sessionName` creates/reuses an isolated browser context before opening the tab. Unsupported option keys throw before creating a tab. Tabs use IDs of the form `browserId:providerTabId`.

Browser HTML paste requires a focused contenteditable editor; normal text and Markdown use text insertion. Apps can reject an advertised action or paste format: always verify the resulting visible state. Browser secondary actions currently expose Expand/Collapse when AX supplies expanded state. Other controls use normal click/key operations.

Normal cleanup closes only tabs created by this adapter, except marked tabs, and never closes unrelated tabs in an attached browser. Marked managed tabs require the REPL daemon to remain alive; closing/stopping it is not a durable export. Browser cookies/profile changes inside named sessions last for this managed browser, not across a daemon reset.

The normal Chromium launch keeps its sandbox enabled. On an Ubuntu host that blocks a downloaded browser's user namespace, use an approved system-installed Chromium/Chrome or configured loopback CDP endpoint. Do not disable sandboxing or alter host security settings as an agent workaround.

## Configuration

`ATAXIA_COMPUTER_USE_SOCKET` chooses the native socket for the CLI. `ATAXIA_CUA_NODE` chooses Node.js 22+. `ATAXIA_CUA_PYTHON` chooses Python with GI/AT-SPI. `ATAXIA_CUA_BROWSER` chooses a managed Chromium executable. `ATAXIA_CUA_HEADLESS=1` is intended for fixtures. `ATAXIA_CUA_BROWSERS` points to a trusted host JSON array of `BrowserConfiguration` records; an `endpoint` must be loopback CDP, or an `executable` launches a private profile over a pipe. Changing providers is host setup, not a response to page instructions.
