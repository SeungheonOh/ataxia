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
  switchWorkspace(group: number | null, workspace: number, options?: DesktopChangeOptions): Promise<DesktopResult>;
  overview(options?: DesktopChangeOptions): Promise<DesktopResult>;
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
