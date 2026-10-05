// Wire protocol between a director and the Stage World.
//
// Messages are newline-delimited JSON objects over a local stream socket.
// The director sends `hello`, receives a `welcome` snapshot, then streams
// scene `commit`s. Every scene value on the wire is canonical: colors are
// straight-alpha [r, g, b, a] in 0..1, angles are radians and durations are
// seconds. The compositor validates every field and never trusts it further.

export const PROTOCOL_VERSION = 1;

export type WireColor = [number, number, number, number];
export type WireValue = number | string | boolean | null | WireValue[] | { [key: string]: WireValue };
export type WireProps = Record<string, WireValue>;

export interface WireWindow {
  id: number;
  title: string;
  app: string;
  mapped: boolean;
  width: number;
  height: number;
}

export interface WireRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface WireOutput {
  name: string;
  x: number;
  width: number;
  height: number;
  scale: number;
  "work-area": WireRect;
}

export interface WireFocus {
  seat: string;
  window: number | null;
}

/** Where an output's camera is headed: world point at its center, zoom and rotation. */
export interface WireCamera {
  output: string;
  x: number;
  y: number;
  zoom: number;
  rotation: number;
}

/** An installed application from the compositor's catalog. */
export interface WireApplication {
  id: string;
  name: string;
  detail: string;
}

/** Event fields arrive in kebab-case, e.g. `screen-x`. */
export interface WireEvent {
  type: "event";
  node: number;
  name: string;
  [field: string]: WireValue;
}

export type ServerMessage =
  | {
      type: "welcome";
      protocol: number;
      display: string;
      outputs: WireOutput[];
      windows: WireWindow[];
      cameras: WireCamera[];
      focus: WireFocus[];
    }
  | { type: "window"; window: WireWindow }
  | { type: "window-removed"; id: number }
  | { type: "output"; output: WireOutput }
  | { type: "output-removed"; name: string }
  | ({ type: "focus" } & WireFocus)
  | ({ type: "camera" } & WireCamera)
  | { type: "applications"; applications: WireApplication[] }
  | { type: "clipboard"; text: string }
  | WireEvent
  | { type: "error"; message: string; fatal?: boolean };

/** Scene mutation. `reset` removes every top-level node within the commit. */
export type Op =
  | { op: "reset" }
  | { op: "create"; id: number; type: string; props: WireProps }
  | { op: "set"; id: number; props: WireProps }
  | { op: "insert"; parent: number; id: number; before: number | null }
  | { op: "remove"; parent: number; id: number };

export type ClientMessage =
  | { type: "hello"; protocol: number; client: string }
  | { type: "commit"; ops: Op[] }
  | { type: "focus"; window: number | null }
  | { type: "close"; window: number }
  | { type: "applications" }
  | { type: "launch-application"; id: string }
  | { type: "set-clipboard"; text: string }
  | { type: "camera"; output: string | null; x?: number; y?: number; zoom?: number;
      rotation?: number; transition?: WireValue };
