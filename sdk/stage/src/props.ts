// Host element props and their canonical wire form.
//
// Each host type lists the fields it accepts. A field turns one ergonomic
// prop (`shadow={{ blur: 24 }}`, `rotation` in degrees, CSS colors) into flat
// wire properties, so the compositor only ever validates scalars and colors.

import { isAbsolute, resolve } from "node:path";
import type { ReactNode } from "react";
import { type Color, toWireColor } from "./color.js";
import type { StageDragEvent, StageErrorEvent, StageEvent, StageGestureEvent, StageLoadEvent,
  StageMeasureEvent, StageNavigateEvent, StagePointerEvent, StageRequestEvent, StageResizeEvent,
  StageWheelEvent } from "./events.js";
import { isMotion, type Motion } from "./motion.js";
import type { WireProps, WireValue } from "./protocol.js";

/** A solid color, or a two-stop linear gradient; ANGLE is in degrees, 0 = left to right. */
export type Paint = Color | { from: Color; to: Color; angle?: number };

export interface Shadow {
  color?: Color;
  blur?: number;
  x?: number;
  y?: number;
  spread?: number;
}

export interface Border {
  width?: number;
  color?: Paint;
}

export interface Grid {
  kind?: "dots" | "lines" | "none";
  color?: Color;
  spacing?: number;
  /** Dot radius or line half-width in output pixels. */
  size?: number;
}

export interface TransformProps {
  x?: number;
  y?: number;
  scale?: number;
  /** Degrees, clockwise. */
  rotation?: number;
  opacity?: number;
  /** Transform origin as a fraction of the node's size; defaults to the center. */
  originX?: number;
  originY?: number;
  visible?: boolean;
}

export interface BoxProps extends TransformProps {
  width?: number;
  height?: number;
  radius?: number;
  border?: Border;
  shadow?: Shadow;
  /** Backdrop blur radius: frosted glass over whatever is drawn behind. */
  blur?: number;
}

/** Paint fields that can animate, as accepted by `initial` and `exit`. */
export type PaintValues = Color | { from?: Color; to?: Color; angle?: number };

/** Props that can be animated, as accepted by `initial` and `exit`. */
export interface AnimatedValues {
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  scale?: number;
  rotation?: number;
  opacity?: number;
  radius?: number;
  zoom?: number;
  fill?: PaintValues;
  /** Text color. */
  color?: Color;
  border?: { width?: number; color?: PaintValues };
  shadow?: Shadow;
  grid?: Omit<Grid, "kind">;
  blur?: number;
  dim?: number;
}

/** Single wire properties a transition may target apart from whole AnimatedValues. */
const transitionParts = { borderAngle: ["borderAngle"], fillAngle: ["fillAngle"] } as const;

/**
 * One motion for every prop, or motions per prop. `borderAngle` and
 * `fillAngle` target a gradient's angle alone, e.g. to spin a border forever
 * while its colors and width still settle normally.
 */
export type Transition = Motion | ({ default?: Motion }
  & { [K in keyof AnimatedValues | keyof typeof transitionParts]?: Motion });

export interface MotionProps {
  /** How changes animate: one motion for every prop, or per prop. */
  transition?: Transition;
  /** Values the node starts from when it first appears. */
  initial?: AnimatedValues;
  /** Values the node animates to after it is removed, before disappearing. */
  exit?: AnimatedValues;
  /** Nodes sharing a layoutId hand over their on-screen state when one replaces the other. */
  layoutId?: string;
}

export interface PointerHandlers {
  onPointerDown?: (event: StagePointerEvent) => void;
  onPointerMove?: (event: StagePointerEvent) => void;
  onPointerUp?: (event: StagePointerEvent) => void;
  onPointerEnter?: (event: StagePointerEvent) => void;
  onPointerLeave?: (event: StagePointerEvent) => void;
  onWheel?: (event: StageWheelEvent) => void;
}

/**
 * A draggable node follows the pointer inside the compositor, with no round
 * trip. Store the position from onDragEnd: until the next render declares a
 * different x/y, the node stays where the drag left it.
 */
export interface DragProps {
  draggable?: boolean;
  onDragStart?: (event: StageDragEvent) => void;
  /** Coalesced progress; use it for feedback, not to drive x/y. */
  onDrag?: (event: StageDragEvent) => void;
  onDragEnd?: (event: StageDragEvent) => void;
}

export interface GroupProps extends TransformProps, MotionProps, DragProps {
  /** Size of the group's box, for its transform origin and `clip`. */
  width?: number;
  height?: number;
  /** Hide children outside the box (axis-aligned on screen). */
  clip?: boolean;
  children?: ReactNode;
}

export interface RectProps extends BoxProps, MotionProps, PointerHandlers, DragProps {
  fill?: Paint;
  /** Hide children outside the box (axis-aligned on screen). */
  clip?: boolean;
  children?: ReactNode;
}

/** Text content: a string, or children that are strings and numbers. */
export type TextContent = string | number | readonly (string | number)[];

/**
 * A text label, laid out by Pango. The node's box is the text's measured size,
 * or `width` wide when given; it is reported through onMeasure.
 */
export interface TextProps extends TransformProps, MotionProps, PointerHandlers, DragProps {
  /** The text; string children are used when it is omitted. */
  text?: string;
  /** Read the text as Pango markup: <b>, <i>, <span foreground="#f80">, … */
  markup?: boolean;
  color?: Color;
  /** Family, or a comma-separated list of families. */
  font?: string;
  /** Font size in pixels. Animate `scale` rather than this. */
  size?: number;
  weight?: number | "normal" | "bold";
  italic?: boolean;
  /** Wrap width; `align` applies within it. */
  width?: number;
  align?: "start" | "center" | "end";
  /** Line height as a multiple of the font's own. */
  lineHeight?: number;
  /** With `width`: end with an ellipsis after this many lines. */
  maxLines?: number;
  onMeasure?: (event: StageMeasureEvent) => void;
  children?: TextContent;
}

/**
 * An image file decoded off the compositor thread: PNG, JPEG, WebP, GIF, SVG
 * and whatever else gdk-pixbuf reads. Without `width` and `height` it takes its
 * natural size; with one of them it keeps its aspect ratio.
 */
export interface ImageProps extends BoxProps, MotionProps, PointerHandlers, DragProps {
  /** Absolute path, a path relative to the world file, or an imported image. */
  src: string;
  /** How the image fills the box; "fill" stretches it. */
  fit?: "fill" | "contain" | "cover";
  onLoad?: (event: StageLoadEvent) => void;
  onError?: (event: StageErrorEvent) => void;
}

export interface WindowProps extends BoxProps, MotionProps {
  /** Window id from `useWindows()`. */
  window: number;
  /** Move natively with a "move" binding or the client's own title bar. */
  movable?: boolean;
  /** Resize natively with a "resize" binding or the client's own edges. */
  resizable?: boolean;
  onDragStart?: (event: StageDragEvent) => void;
  onDrag?: (event: StageDragEvent) => void;
  onDragEnd?: (event: StageDragEvent) => void;
  onResizeStart?: (event: StageResizeEvent) => void;
  onResize?: (event: StageResizeEvent) => void;
  onResizeEnd?: (event: StageResizeEvent) => void;
  /** Darken the content, 0..1, e.g. for inactive windows. */
  dim?: number;
  fullscreen?: boolean;
  maximized?: boolean;
  /** Ask the client to draw square, shadowless edges. */
  tiled?: boolean;
  focusable?: boolean;
  interactive?: boolean;
  onPointerEnter?: (event: StagePointerEvent) => void;
  onPointerLeave?: (event: StagePointerEvent) => void;
  /** Client-side decorations asked to move or resize; the pointer is captured
   * by this node until release, delivering onPointerMove/onPointerUp. */
  onMoveRequest?: (event: StageRequestEvent) => void;
  onResizeRequest?: (event: StageRequestEvent) => void;
  onPointerMove?: (event: StagePointerEvent) => void;
  onPointerUp?: (event: StagePointerEvent) => void;
  onFullscreenRequest?: (event: StageRequestEvent) => void;
  onMaximizeRequest?: (event: StageRequestEvent) => void;
  onMinimizeRequest?: (event: StageRequestEvent) => void;
  children?: ReactNode;
}

export interface BackgroundProps extends TransformProps, MotionProps, PointerHandlers {
  fill?: Color;
  grid?: Grid;
  /** Dragging or scrolling the empty plane pans the camera natively, with momentum. */
  pan?: boolean;
}

/**
 * Declares an output's camera. The camera itself lives in the compositor, so
 * pans and zooms track input exactly; x/y/zoom/rotation apply when they first
 * appear and whenever they change. Read it with useCamera() and move it from
 * code with moveCamera().
 */
export interface CameraProps {
  /** Output name; omit to apply to every output without its own camera. */
  output?: string;
  /** World point shown at the output's center. */
  x?: number;
  y?: number;
  zoom?: number;
  /** Degrees. */
  rotation?: number;
  minZoom?: number;
  maxZoom?: number;
  /** Transition for declared changes and moveCamera() without its own. */
  transition?: Motion;
}

export interface ScreenProps extends TransformProps, MotionProps {
  /** Output name; omit to show on every output. */
  output?: string;
  children?: ReactNode;
}

export type ModifierName = "super" | "logo" | "shift" | "ctrl" | "control" | "alt";

/**
 * Work a binding performs inside the compositor, in the same frame as the input.
 * "move"/"resize" act on the movable/resizable window (or draggable node) under
 * the pointer; "pan"/"zoom" act on the camera of the output under it.
 */
export type BindingAction = "move" | "resize" | "pan" | "zoom";

/**
 * Workspaces for the shell: the status bar shows them and its workspace
 * buttons, previous/next and overview arrive as onNavigate.
 */
export interface ShellProps {
  name?: string;
  /** Number of workspaces, at most 9 shown. */
  workspaces: number;
  /** Current workspace, from 1. */
  selected: number;
  /** False while an overview shows every workspace. */
  active?: boolean;
  onNavigate?: (event: StageNavigateEvent) => void;
}

/**
 * Screen space this world keeps for UI it draws itself, such as a bar: the
 * output's `workArea` and window layouts leave it free.
 */
export interface ReserveProps {
  /** Output name; omit to reserve on every output. */
  output?: string;
  top?: number;
  right?: number;
  bottom?: number;
  left?: number;
}

export interface ShortcutProps {
  /** For example "Super+Shift+Return". */
  keys: string;
  repeat?: boolean;
  onPress?: () => void;
  onRelease?: () => void;
}

export interface PointerBindingProps {
  button?: "left" | "right" | "middle" | number;
  modifiers?: ModifierName | ModifierName[];
  action?: Exclude<BindingAction, "zoom">;
  onDown?: (event: StagePointerEvent) => void;
  onMove?: (event: StagePointerEvent) => void;
  onUp?: (event: StagePointerEvent) => void;
}

export interface WheelBindingProps {
  modifiers?: ModifierName | ModifierName[];
  action?: "pan" | "zoom";
  onWheel?: (event: StageWheelEvent) => void;
}

export interface GestureBindingProps {
  gesture: "swipe" | "pinch" | "hold";
  fingers?: number;
  modifiers?: ModifierName | ModifierName[];
  action?: "pan" | "zoom";
  onBegin?: (event: StageGestureEvent) => void;
  onUpdate?: (event: StageGestureEvent) => void;
  onEnd?: (event: StageGestureEvent) => void;
}

export type HostType =
  | "group" | "rect" | "text" | "image" | "web" | "window" | "background" | "camera" | "screen"
  | "shell" | "reserve"
  | "shortcut" | "pointer-binding" | "wheel-binding" | "gesture-binding";

type Props = Record<string, unknown>;
type Writer = (value: never, out: WireProps) => void;

const degrees = Math.PI / 180;

function number(name: string): Writer {
  return (value: number, out) => { out[name] = value; };
}

function flag(name: string): Writer {
  return (value: boolean, out) => { out[name] = Boolean(value); };
}

function text(name: string): Writer {
  return (value: string, out) => { out[name] = value; };
}

const color = (name: string): Writer => (value: Color, out) => { out[name] = toWireColor(value); };

function isGradient(value: unknown): value is { from?: Color; to?: Color; angle?: number } {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** A paint is a solid color, or a gradient flattened into start, end and angle. */
function paint(start: string, end: string, angle: string): Writer {
  return (value: PaintValues, out) => {
    if (!isGradient(value)) {
      out[start] = toWireColor(value);
      return;
    }
    if (value.from !== undefined) out[start] = toWireColor(value.from);
    if (value.to !== undefined) out[end] = toWireColor(value.to);
    if (value.angle !== undefined) out[angle] = value.angle * degrees;
  };
}

function nested(fields: Record<string, Writer>): Writer {
  return (value: Record<string, unknown>, out) => {
    for (const [key, write] of Object.entries(fields)) {
      if (value[key] !== undefined) write(value[key] as never, out);
    }
  };
}

const shadow = nested({
  color: color("shadowColor"), blur: number("shadowBlur"), x: number("shadowX"),
  y: number("shadowY"), spread: number("shadowSpread"),
});
const border = nested({
  width: number("borderWidth"), color: paint("borderColor", "borderColorEnd", "borderAngle"),
});
const grid = nested({
  kind: text("grid"), color: color("gridColor"), spacing: number("gridSpacing"), size: number("gridSize"),
});
const rotation: Writer = (value: number, out) => { out.rotation = value * degrees; };

const modifierNames: Record<string, string> = {
  super: "logo", logo: "logo", meta: "logo", shift: "shift", ctrl: "control", control: "control",
  alt: "alt",
};

function modifierList(value: string | string[]): string[] {
  return [...new Set((Array.isArray(value) ? value : [value]).map((name) => {
    const modifier = modifierNames[name.toLowerCase()];
    if (!modifier) throw new TypeError(`Unknown modifier ${JSON.stringify(name)}`);
    return modifier;
  }))].sort();
}

const keyAliases: Record<string, string> = {
  enter: "Return", esc: "Escape", space: "space", pageup: "Prior", pagedown: "Next",
  plus: "plus", minus: "minus", comma: "comma", period: "period", slash: "slash",
};

const shortcutKeys: Writer = (value: string, out) => {
  const parts = value.split("+").map((part) => part.trim()).filter(Boolean);
  const key = parts.pop();
  if (!key) throw new TypeError(`Shortcut ${JSON.stringify(value)} has no key`);
  out.key = keyAliases[key.toLowerCase()] ?? key;
  out.modifiers = modifierList(parts);
};

const buttons: Record<string, number> = { left: 272, right: 273, middle: 274 };

const transform: Record<string, Writer> = {
  x: number("x"), y: number("y"), scale: number("scale"), rotation, opacity: number("opacity"),
  originX: number("originX"), originY: number("originY"), visible: flag("visible"),
};

const box: Record<string, Writer> = {
  ...transform, width: number("width"), height: number("height"), radius: number("radius"),
  border, shadow, blur: number("blur"),
};
const fill = paint("color", "colorEnd", "fillAngle");

const modifiers: Writer = (value: string | string[], out) => { out.modifiers = modifierList(value); };

let assetBase = process.cwd();

/** Directory relative asset paths resolve against: the running world file's. */
export function setAssetBase(directory: string): void {
  assetBase = directory;
}

export function resolveAsset(path: string): string {
  return isAbsolute(path) ? path : resolve(assetBase, path);
}

const fontWeights: Record<string, number> = { normal: 400, bold: 700 };

export function isTextContent(value: unknown): value is TextContent {
  const atom = (item: unknown) => typeof item === "string" || typeof item === "number";
  return atom(value) || (Array.isArray(value) && value.every(atom));
}

function textContent(value: TextContent): string {
  return Array.isArray(value) ? value.join("") : String(value);
}

const fields: Record<HostType, Record<string, Writer>> = {
  group: {
    ...transform, width: number("width"), height: number("height"), clip: flag("clip"),
    draggable: flag("draggable"),
  },
  rect: { ...box, fill, clip: flag("clip"), draggable: flag("draggable") },
  text: {
    ...transform, text: text("text"), markup: flag("markup"), color: color("color"),
    font: text("font"), size: number("fontSize"),
    weight: (value: number | string, out) => {
      out.fontWeight = typeof value === "number" ? value : fontWeights[value] ?? 400;
    },
    italic: flag("italic"), width: number("width"), align: text("align"),
    lineHeight: number("lineHeight"), maxLines: number("maxLines"), draggable: flag("draggable"),
  },
  image: {
    ...box, fit: text("fit"), draggable: flag("draggable"),
    src: (value: string, out) => { out.src = resolveAsset(value); },
  },
  web: {
    ...box, src: text("src"), data: text("data"), revision: number("revision"),
    focusable: flag("focusable"), interactive: flag("interactive"), autoFocus: flag("autoFocus"),
  },
  window: {
    ...box, window: number("window"), dim: number("dim"),
    fullscreen: flag("fullscreen"), maximized: flag("maximized"),
    tiled: flag("tiled"), focusable: flag("focusable"), interactive: flag("interactive"),
    movable: flag("movable"), resizable: flag("resizable"),
  },
  background: { ...transform, fill: color("color"), grid, pan: flag("pan") },
  camera: {
    output: text("output"), x: number("x"), y: number("y"), zoom: number("zoom"), rotation,
    minZoom: number("minZoom"), maxZoom: number("maxZoom"),
  },
  screen: { ...transform, output: text("output") },
  shell: { name: text("name"), workspaces: number("count"), selected: number("selected"),
           active: flag("active") },
  reserve: { output: text("output"), top: number("top"), right: number("right"),
             bottom: number("bottom"), left: number("left") },
  shortcut: { keys: shortcutKeys, repeat: flag("repeat") },
  "pointer-binding": {
    button: (value: string | number, out) => {
      out.button = typeof value === "number" ? value : buttons[value] ?? 272;
    },
    modifiers, action: text("action"),
  },
  "wheel-binding": { modifiers, action: text("action") },
  "gesture-binding": { gesture: text("gesture"), fingers: number("fingers"), modifiers, action: text("action") },
};

/** Wire properties each animated prop expands to, for per-prop transitions. */
const animatedWireNames: Record<keyof AnimatedValues, string[]> = {
  x: ["x"], y: ["y"], width: ["width"], height: ["height"], scale: ["scale"], rotation: ["rotation"],
  opacity: ["opacity"], radius: ["radius"], zoom: ["zoom"],
  fill: ["color", "colorEnd", "fillAngle"], color: ["color"],
  border: ["borderWidth", "borderColor", "borderColorEnd", "borderAngle"],
  shadow: ["shadowColor", "shadowBlur", "shadowX", "shadowY", "shadowSpread"],
  grid: ["gridColor", "gridSpacing", "gridSize"],
  blur: ["blur"], dim: ["dim"],
};

const handlerEvents: Record<string, string> = {
  onPointerDown: "pointerdown", onPointerMove: "pointermove", onPointerUp: "pointerup",
  onPointerEnter: "pointerenter", onPointerLeave: "pointerleave", onWheel: "wheel",
  onPress: "press", onRelease: "release", onDown: "down", onMove: "move", onUp: "up",
  onBegin: "begin", onUpdate: "update", onEnd: "end",
  onMoveRequest: "moverequest", onResizeRequest: "resizerequest",
  onDragStart: "dragstart", onDrag: "drag", onDragEnd: "dragend",
  onResizeStart: "resizestart", onResize: "resize", onResizeEnd: "resizeend",
  onFullscreenRequest: "fullscreenrequest", onMaximizeRequest: "maximizerequest",
  onMinimizeRequest: "minimizerequest",
  onMeasure: "measure", onLoad: "load", onError: "error", onMessage: "message",
  onNavigate: "navigate",
};

export function wireMotion(motion: Motion): WireValue {
  return { ...motion } as WireValue;
}

function wireTransition(transition: Transition): WireProps {
  if (isMotion(transition)) return { default: wireMotion(transition) };
  const out: WireProps = {};
  for (const [name, motion] of Object.entries(transition)) {
    if (!motion) continue;
    const targets = name === "default"
      ? ["default"]
      : animatedWireNames[name as keyof AnimatedValues]
        ?? transitionParts[name as keyof typeof transitionParts];
    if (!targets) throw new TypeError(`Cannot transition ${JSON.stringify(name)}`);
    // A whole value's motion leaves a part with its own motion alone.
    for (const target of targets) {
      if (!(target in out) || targets.length === 1) out[target] = wireMotion(motion);
    }
  }
  return out;
}

function writeFields(type: HostType, props: Props, out: WireProps, only?: Set<string>): void {
  const accepted = fields[type];
  for (const [name, value] of Object.entries(props)) {
    if (value === undefined || (only && !only.has(name))) continue;
    const write = accepted[name];
    if (write) write(value as never, out);
  }
}

const animatedNames = new Set(Object.keys(animatedWireNames));

export type EventHandler = (event: StageEvent) => void;

export interface Normalized {
  wire: WireProps;
  handlers: Map<string, EventHandler>;
}

/** Translate host element props into wire props and the handlers they declare. */
export function normalizeProps(type: HostType, props: Props): Normalized {
  const wire: WireProps = {};
  const handlers = new Map<string, EventHandler>();
  writeFields(type, props, wire);
  if (type === "text" && props.text === undefined && isTextContent(props.children)) {
    wire.text = textContent(props.children);
  }
  for (const [name, value] of Object.entries(props)) {
    const event = handlerEvents[name];
    if (event && typeof value === "function") handlers.set(event, value as EventHandler);
  }
  if (handlers.size > 0) wire.handlers = [...handlers.keys()].sort();
  if (props.transition) wire.transition = wireTransition(props.transition as Transition);
  for (const key of ["initial", "exit"] as const) {
    if (props[key]) {
      const values: WireProps = {};
      writeFields(type, props[key] as Props, values, animatedNames);
      wire[key] = values;
    }
  }
  if (typeof props.layoutId === "string") wire.layoutId = props.layoutId;
  return { wire, handlers };
}

function sameValue(left: WireValue | undefined, right: WireValue | undefined): boolean {
  if (left === right) return true;
  if (typeof left !== "object" || typeof right !== "object" || left === null || right === null) {
    return false;
  }
  const leftKeys = Object.keys(left);
  return leftKeys.length === Object.keys(right).length
    && leftKeys.every((key) => sameValue((left as Record<string, WireValue>)[key],
                                         (right as Record<string, WireValue>)[key]));
}

/** Changed wire props; a prop that disappeared is sent as null to restore its default. */
export function diffWire(previous: WireProps, next: WireProps): WireProps | null {
  let changes: WireProps | null = null;
  for (const [key, value] of Object.entries(next)) {
    if (!sameValue(previous[key], value)) (changes ??= {})[key] = value;
  }
  for (const key of Object.keys(previous)) {
    if (!(key in next)) (changes ??= {})[key] = null;
  }
  return changes;
}
