// Host element props and their canonical wire form.
//
// Each host type lists the fields it accepts. A field turns one ergonomic
// prop (`shadow={{ blur: 24 }}`, `rotation` in degrees, CSS colors) into flat
// wire properties, so the compositor only ever validates scalars and colors.

import { isAbsolute, resolve } from "node:path";
import type { ReactNode, Ref } from "react";
import { type Color, toWireColor } from "./color.js";
import type { StageDragEvent, StageElement, StageErrorEvent, StageEvent,
  StageGestureEvent, StageLoadEvent, StageMeasureEvent, StagePointerEvent,
  StageRequestEvent, StageResizeEvent, StageWheelEvent } from "./events.js";
import type { Dimension, FlexContainerProps, FlexItemProps, LayoutBox } from "./layout.js";
import { type Animation, wireAnimations } from "./animation.js";
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

/** Theme cursor names, as in CSS; "none" hides the pointer. */
export type Cursor = "none" | "default" | "pointer" | "text" | "crosshair" | "move" | "grab"
  | "grabbing" | "not-allowed" | "help" | "wait" | "progress" | "zoom-in" | "zoom-out"
  | "ew-resize" | "ns-resize" | "nwse-resize" | "nesw-resize";

export interface CursorProps {
  /** Pointer shape over this node and its children, unless they set their own. */
  cursor?: Cursor;
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

/** Props shared through objects, merged under the element's own; later entries win. */
export type Style<P> = Partial<P> | false | null | undefined | readonly Style<P>[];

/**
 * A fragment shader a node and its children are drawn through, as a CSS filter.
 * SHADER is GLSL ES 1.0 defining `vec4 effect(vec2 position)`, which returns the
 * premultiplied color at POSITION, in the node's local pixels. It can call
 * `content(p)` (the node as drawn) and, with `backdrop`, `backdrop(p)` (what is
 * behind it), and read `size`, `time` (seconds, with `time`), `pointer` (with
 * `pointer`), `amount`, `pixel` (local units per output pixel) and its own uniforms.
 */
export interface Effect {
  shader: string;
  /** Float, vec2 or vec4 uniforms by name; changes animate with `transition.effect`. */
  uniforms?: Record<string, UniformValue>;
  /** How strongly it applies, 1 by default. At 0 the node is drawn as is, at no cost. */
  amount?: number;
  /** Room around the box the effect may draw into, e.g. for a shadow, a glow or a ripple. */
  margin?: number;
  /** The shader reads `content` only at its own position, so changes repaint only where they are. */
  local?: boolean;
  /** Advance `time` every frame while shown; like a loop, it keeps the output repainting. */
  time?: boolean;
  /** Provide `backdrop(p)`: what is drawn behind the node. */
  backdrop?: boolean;
  /**
   * Provide `pointer`, where the pointer is in local pixels, kept current as it
   * moves; an output showing such an effect repaints it on pointer motion.
   */
  pointer?: boolean;
  /** "output" runs it over the whole output; `position` and `size` are then the output's. */
  area?: "box" | "output";
}

export interface EffectProps {
  effect?: Effect | null;
  /** The effect's shader did not compile; the node shows unchanged. */
  onError?: (event: StageErrorEvent) => void;
}

/** Props of every node a <Box> can lay out. */
export interface ElementProps<P> extends FlexItemProps {
  ref?: Ref<StageElement>;
  /** Called after a commit in which a <Box> gave this node a new box. */
  onLayout?: (layout: LayoutBox) => void;
  style?: Style<P>;
}

export interface ShapeProps extends TransformProps {
  /** Logical pixels; percentages resolve inside a <Box>. */
  width?: Dimension;
  height?: Dimension;
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
  effect?: { amount?: number; uniforms?: Record<string, UniformValue> };
}

/** A float, vec2 or vec4 uniform of an effect; a color is a vec4. */
export type UniformValue = number | readonly [number, number] | readonly [number, number, number, number]
  | Color;

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
  /**
   * Keyframe animations the compositor plays over the props, such as
   * `{ x: [0, -8, 8, 0], composite: "add", duration: 0.3 }`, or a list of them.
   */
  animate?: Animation | readonly Animation[] | null | false;
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

export interface GroupProps extends TransformProps, MotionProps, PointerHandlers, DragProps,
  CursorProps, EffectProps, ElementProps<GroupProps> {
  /**
   * Size of the group's box, for its transform origin and `clip`. A sized
   * group with pointer handlers catches the pointer anywhere inside it.
   */
  width?: Dimension;
  height?: Dimension;
  /** Hide children outside the box (axis-aligned on screen). */
  clip?: boolean;
  children?: ReactNode;
}

export interface RectProps extends ShapeProps, MotionProps, PointerHandlers, DragProps,
  CursorProps, EffectProps, ElementProps<RectProps> {
  fill?: Paint;
  /** Hide children outside the box (axis-aligned on screen). */
  clip?: boolean;
  children?: ReactNode;
}

/** A Rect that lays out its children with flexbox. */
export interface BoxProps extends Omit<RectProps, "style">, FlexContainerProps {
  style?: Style<BoxProps>;
}

/** Text content: a string, or children that are strings and numbers. */
export type TextContent = string | number | readonly (string | number)[];

/**
 * A text label, laid out by Pango. The node's box is the text's measured size,
 * or `width` wide when given; it is reported through onMeasure. A <Text> inside
 * another styles its part of the text, as in React Native:
 * `<Text>Saved <Text weight="bold" color="#8f8">3</Text> files</Text>`; there
 * only `color`, `font`, `size`, `weight` and `italic` apply.
 */
export interface TextProps extends TransformProps, MotionProps, PointerHandlers, DragProps,
  CursorProps, EffectProps, ElementProps<TextProps> {
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
  /** Wrap width; `align` applies within it. In a <Box>, the width the Box gives it. */
  width?: Dimension;
  align?: "start" | "center" | "end";
  /** Line height as a multiple of the font's own. */
  lineHeight?: number;
  /** With `width`: end with an ellipsis after this many lines. */
  maxLines?: number;
  onMeasure?: (event: StageMeasureEvent) => void;
  /** Strings, numbers and nested <Text>s; with `markup`, strings are markup. */
  children?: ReactNode;
}

/**
 * An image file decoded off the compositor thread: PNG, JPEG, WebP, GIF, SVG
 * and whatever else gdk-pixbuf reads. Without `width` and `height` it takes its
 * natural size; with one of them it keeps its aspect ratio.
 */
export interface ImageProps extends ShapeProps, MotionProps, PointerHandlers, DragProps,
  CursorProps, EffectProps, ElementProps<ImageProps> {
  /** Absolute path, a path relative to the world file, or an imported image. */
  src: string;
  /** How the image fills the box; "fill" stretches it. */
  fit?: "fill" | "contain" | "cover";
  onLoad?: (event: StageLoadEvent) => void;
  onError?: (event: StageErrorEvent) => void;
}

export interface WindowProps extends ShapeProps, MotionProps, EffectProps, ElementProps<WindowProps> {
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
  /**
   * The client asked for the window to be shown and focused, e.g. for a link
   * opened from another application. Without a handler it is focused where it is.
   */
  onActivateRequest?: (event: StageRequestEvent) => void;
  children?: ReactNode;
}

export interface BackgroundProps extends Omit<TransformProps, "originX" | "originY">, MotionProps,
  PointerHandlers, CursorProps {
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

export interface ScreenProps extends Omit<TransformProps, "originX" | "originY">, MotionProps {
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
  | "group" | "rect" | "box" | "text" | "image" | "web" | "window" | "background" | "camera" | "screen"
  | "reserve"
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

/** A size; percentages only mean something to layout. */
function size(name: string): Writer {
  return (value: Dimension, out) => {
    if (typeof value === "number") out[name] = value;
  };
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

// Background and screen nodes have no size, so they take no transform origin.
const placement: Record<string, Writer> = {
  x: number("x"), y: number("y"), scale: number("scale"), rotation, opacity: number("opacity"),
  visible: flag("visible"),
};
const transform: Record<string, Writer> = {
  ...placement, originX: number("originX"), originY: number("originY"),
};

const box: Record<string, Writer> = {
  ...transform, width: size("width"), height: size("height"), radius: number("radius"),
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

function fontWeight(value: unknown): number {
  return typeof value === "number" ? value : fontWeights[String(value)] ?? 400;
}

export function isTextContent(value: unknown): value is TextContent {
  const atom = (item: unknown) => typeof item === "string" || typeof item === "number";
  return atom(value) || (Array.isArray(value) && value.every(atom));
}

export function textContent(value: TextContent): string {
  return Array.isArray(value) ? value.join("") : String(value);
}

const markupEscapes: Record<string, string> = {
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;",
};

export function escapeMarkup(text: string): string {
  return text.replace(/[&<>"']/g, (char) => markupEscapes[char]!);
}

/** The weight and style around a nested <Text>, which its children inherit. */
export interface SpanFont {
  weight: number;
  italic: boolean;
}

function hexColor(red: number, green: number, blue: number): string {
  return `#${[red, green, blue].map((channel) =>
    Math.round(channel * 255).toString(16).padStart(2, "0")).join("")}`;
}

/** Pango span attributes for a nested <Text>'s PROPS, and the font it passes on. */
export function spanAttributes(props: Props, outer: SpanFont): [string, SpanFont] {
  const font: SpanFont = {
    weight: props.weight === undefined ? outer.weight : fontWeight(props.weight),
    italic: props.italic === undefined ? outer.italic : Boolean(props.italic),
  };
  const sized = typeof props.size === "number";
  let attributes = "";
  // A pixel size is a whole font description, which resets weight and style
  // too, so a sized span states them again.
  if (sized) attributes += ` font="${props.size}px"`;
  if (typeof props.font === "string") attributes += ` font_family="${escapeMarkup(props.font)}"`;
  if (sized || font.weight !== outer.weight) attributes += ` weight="${font.weight}"`;
  if (sized || font.italic !== outer.italic) {
    attributes += ` style="${font.italic ? "italic" : "normal"}"`;
  }
  if (props.color !== undefined) {
    const [red, green, blue, alpha] = toWireColor(props.color as Color);
    attributes += ` foreground="${hexColor(red, green, blue)}"`;
    if (alpha < 1) attributes += ` fgalpha="${Math.max(1, Math.round(alpha * 100))}%"`;
  }
  return [attributes, font];
}

const cursor = text("cursor");

const effect = nested({
  shader: text("shader"), amount: number("amount"), margin: number("margin"), local: flag("local"),
  time: flag("time"), backdrop: flag("backdrop"), pointer: flag("pointer"), area: text("area"),
  uniforms: (value: Record<string, UniformValue>, out) => { out.uniforms = wireUniforms(value); },
});

const rect = { ...box, fill, clip: flag("clip"), draggable: flag("draggable"), cursor, effect };

const fields: Record<HostType, Record<string, Writer>> = {
  group: {
    ...transform, width: size("width"), height: size("height"), clip: flag("clip"),
    draggable: flag("draggable"), cursor, effect,
  },
  rect,
  box: rect,
  text: {
    ...transform, text: text("text"), markup: flag("markup"), color: color("color"),
    font: text("font"), size: number("fontSize"),
    weight: (value: number | string, out) => { out.fontWeight = fontWeight(value); },
    italic: flag("italic"), width: size("width"), align: text("align"),
    lineHeight: number("lineHeight"), maxLines: number("maxLines"), draggable: flag("draggable"),
    cursor, effect,
  },
  image: {
    ...box, fit: text("fit"), draggable: flag("draggable"), cursor, effect,
    src: (value: string, out) => { out.src = resolveAsset(value); },
  },
  web: {
    ...box, src: text("src"), data: text("data"), revision: number("revision"),
    focusable: flag("focusable"), interactive: flag("interactive"), autoFocus: flag("autoFocus"),
    cursor, effect,
  },
  window: {
    ...box, window: number("window"), dim: number("dim"),
    fullscreen: flag("fullscreen"), maximized: flag("maximized"),
    tiled: flag("tiled"), focusable: flag("focusable"), interactive: flag("interactive"),
    movable: flag("movable"), resizable: flag("resizable"), effect,
  },
  background: { ...placement, fill: color("color"), grid, pan: flag("pan"), cursor },
  camera: {
    output: text("output"), x: number("x"), y: number("y"), zoom: number("zoom"), rotation,
    minZoom: number("minZoom"), maxZoom: number("maxZoom"),
  },
  screen: { ...placement, output: text("output") },
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
  blur: ["blur"], dim: ["dim"], effect: ["amount", "uniforms"],
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
  onMinimizeRequest: "minimizerequest", onActivateRequest: "activaterequest",
  onMeasure: "measure", onLoad: "load", onError: "error", onMessage: "message",
};

function wireUniforms(uniforms: Record<string, UniformValue>): WireProps {
  const out: WireProps = {};
  for (const [name, value] of Object.entries(uniforms)) {
    out[name] = typeof value === "number" ? value
      : typeof value === "string" ? toWireColor(value)
      : [...(value as readonly number[])];
  }
  return out;
}

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

/** Props a <Box> reads to place and size a node. */
const layoutKeys = new Set([
  "x", "y", "width", "height", "minWidth", "minHeight", "maxWidth", "maxHeight", "aspectRatio",
  "flexGrow", "flexShrink", "flexBasis", "alignSelf", "position", "display",
  "margin", "marginX", "marginY", "marginTop", "marginRight", "marginBottom", "marginLeft",
  "flexDirection", "flexWrap", "justifyContent", "alignItems", "alignContent",
  "gap", "rowGap", "columnGap",
  "padding", "paddingX", "paddingY", "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
]);

/** The host type the compositor knows a node as. */
export function wireType(type: HostType): string {
  return type === "box" ? "rect" : type;
}

export type EventHandler = (event: StageEvent) => void;

export interface Normalized {
  wire: WireProps;
  handlers: Map<string, EventHandler>;
  /** What a <Box> reads to lay the node out. */
  style: Props;
  onLayout: ((layout: LayoutBox) => void) | null;
}

function mergeStyle(style: unknown, into: Props): void {
  if (Array.isArray(style)) for (const entry of style) mergeStyle(entry, into);
  else if (style && typeof style === "object") Object.assign(into, style);
}

/** PROPS over the objects of their `style` prop, as in React Native. */
function withStyle(props: Props): Props {
  const merged: Props = {};
  mergeStyle(props.style, merged);
  for (const [name, value] of Object.entries(props)) if (value !== undefined) merged[name] = value;
  return merged;
}

/** Translate host element props into wire props, handlers and layout style. */
export function normalizeProps(type: HostType, given: Props): Normalized {
  const props = given.style ? withStyle(given) : given;
  const wire: WireProps = {};
  const handlers = new Map<string, EventHandler>();
  const style: Props = {};
  writeFields(type, props, wire);
  if (type === "text" && props.text === undefined && isTextContent(props.children)) {
    wire.text = textContent(props.children);
  }
  for (const [name, value] of Object.entries(props)) {
    if (value === undefined) continue;
    if (layoutKeys.has(name)) style[name] = value;
    const event = handlerEvents[name];
    if (event && typeof value === "function") handlers.set(event, value as EventHandler);
  }
  if (style.display === "none") wire.visible = false;
  if (handlers.size > 0) wire.handlers = [...handlers.keys()].sort();
  if (props.transition) wire.transition = wireTransition(props.transition as Transition);
  for (const key of ["initial", "exit"] as const) {
    if (props[key]) {
      const values: WireProps = {};
      writeFields(type, props[key] as Props, values, animatedNames);
      wire[key] = values;
    }
  }
  if (props.animate) wire.animate = wireAnimations(props.animate as Animation | Animation[]);
  if (typeof props.layoutId === "string") wire.layoutId = props.layoutId;
  const onLayout = typeof props.onLayout === "function"
    ? props.onLayout as (layout: LayoutBox) => void
    : null;
  return { wire, handlers, style, onLayout };
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
