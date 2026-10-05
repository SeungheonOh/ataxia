import type { WireEvent, WireValue } from "./protocol.js";

export type Modifier = "shift" | "control" | "alt" | "logo";

/** Pointer position in every space a handler may need. */
export interface StagePointerEvent {
  /** Output under the pointer and the position in its logical pixels. */
  output: string;
  screenX: number;
  screenY: number;
  /** Position in world space, through that output's camera. */
  worldX: number;
  worldY: number;
  /** Position in the target node's parent space: add to its x/y when dragging. */
  x: number;
  y: number;
  /** Position in the target node's own space. */
  localX: number;
  localY: number;
  modifiers: Modifier[];
  /** Linux input button code (272 left, 273 right, 274 middle). */
  button?: number;
  /** For bindings: the window under the pointer, if any. */
  window?: number | null;
}

export interface StageWheelEvent extends StagePointerEvent {
  orientation: "vertical" | "horizontal";
  delta: number;
  discrete: number;
  source: "wheel" | "finger" | "continuous" | "wheel-tilt";
}

export interface StageGestureEvent extends Partial<StagePointerEvent> {
  fingers: number;
  /** Movement since the previous update, in logical pixels. */
  dx: number;
  dy: number;
  /** Pinch scale relative to the gesture start, and rotation in degrees. */
  scale: number;
  rotation: number;
  cancelled: boolean;
}

export interface StageRequestEvent extends Partial<StagePointerEvent> {
  /** Requested state for fullscreen/maximize/minimize requests. */
  value?: boolean;
  /** xdg_toplevel resize edges for resize requests. */
  edges?: number;
}

/** Position a native drag left a node at, in its parent space. */
export interface StageDragEvent {
  x: number;
  y: number;
}

/** Box a native resize left a window with, in its parent space. */
export interface StageResizeEvent extends StageDragEvent {
  width: number;
  height: number;
}

/** Size a text node measured at, or an image's natural size once decoded. */
export interface StageMeasureEvent {
  width: number;
  height: number;
}

export type StageLoadEvent = StageMeasureEvent;

export interface StageErrorEvent {
  message: string;
}

/** A shell navigation request, e.g. from the status bar's workspace buttons. */
export interface StageNavigateEvent {
  action: "workspace" | "select-workspace" | "previous" | "next" | "overview";
  /** Output the request came from. */
  output: string;
  /** Target workspace for "workspace" and "select-workspace". */
  workspace?: number | null;
}

export type StageEvent = StagePointerEvent | StageWheelEvent | StageGestureEvent | StageRequestEvent
  | StageDragEvent | StageResizeEvent | StageMeasureEvent | StageErrorEvent | StageNavigateEvent;

/** Convert a wire event's kebab-case fields into a handler argument. */
export function toStageEvent(message: WireEvent): StageEvent {
  const event: Record<string, WireValue> = {};
  for (const [key, value] of Object.entries(message)) {
    if (key === "type" || key === "node" || key === "name") continue;
    event[key.replace(/-([a-z])/g, (_, letter: string) => letter.toUpperCase())] = value;
  }
  return event as unknown as StageEvent;
}
