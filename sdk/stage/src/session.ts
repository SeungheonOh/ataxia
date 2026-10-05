// One director session: the compositor connection, mirrored state, and the
// React root rendering into it. A process hosts a single session, which hooks
// and actions reach through `currentSession`.

import { spawn } from "node:child_process";
import type { ReactNode } from "react";
import { Connection } from "./connection.js";
import { Container, createRoot, reconciler } from "./host.js";
import type { ServerMessage } from "./protocol.js";
import { type Motion } from "./motion.js";
import { wireMotion } from "./props.js";
import { Store } from "./store.js";

export interface CameraMove {
  x?: number;
  y?: number;
  zoom?: number;
  /** Degrees. */
  rotation?: number;
}

export interface SessionOptions {
  socket: string;
  /** Exit once this process is no longer our parent, i.e. the compositor died. */
  parentPid?: number;
  onError?: (error: unknown) => void;
  /** The compositor refused this director for good, e.g. a newer one replaced it. */
  onRejected?: (reason: string) => void;
}

let current: Session | null = null;

export function currentSession(): Session {
  if (!current) throw new Error("No Stage session is running; start one with run().");
  return current;
}

export class Session {
  readonly store = new Store();
  private readonly container: Container;
  private readonly root: ReturnType<typeof createRoot>;
  private readonly connection: Connection;
  private readonly onError: (error: unknown) => void;
  private readonly onRejected: (reason: string) => void;
  private applicationsWanted = false;

  constructor(options: SessionOptions) {
    if (current) throw new Error("A Stage session is already running.");
    current = this;
    this.onError = options.onError ?? ((error) => console.error("[stage]", error));
    this.onRejected = options.onRejected ?? (() => undefined);
    this.container = new Container((ops) => this.connection.send({ type: "commit", ops }));
    this.root = createRoot(this.container, this.onError);
    this.connection = new Connection(options.socket, {
      message: (message) => this.receive(message),
      // Whatever is committed while disconnected is replayed on reconnect.
      closed: () => this.container.requestResync(),
    }, options.parentPid);
  }

  start(): void {
    this.connection.start();
  }

  stop(): void {
    this.connection.stop();
    reconciler.updateContainer(null, this.root, null, () => undefined);
    current = null;
  }

  render(element: ReactNode): void {
    reconciler.updateContainer(element, this.root, null, () => undefined);
  }

  focus(window: number | null): void {
    this.connection.send({ type: "focus", window });
  }

  close(window: number): void {
    this.connection.send({ type: "close", window });
  }

  /** Ask for the installed applications; they arrive in the store. */
  requestApplications(): void {
    this.applicationsWanted = true;
    this.connection.send({ type: "applications" });
  }

  launchApplication(id: string): void {
    this.connection.send({ type: "launch-application", id });
  }

  /** Put TEXT on the clipboard, as if a client had copied it. */
  copy(text: string): void {
    this.store.rememberClipboard(text);
    this.connection.send({ type: "set-clipboard", text });
  }

  moveCamera(move: CameraMove, options: { output?: string; transition?: Motion } = {}): void {
    this.connection.send({
      type: "camera", output: options.output ?? null, x: move.x, y: move.y, zoom: move.zoom,
      rotation: move.rotation === undefined ? undefined : move.rotation * Math.PI / 180,
      transition: options.transition ? wireMotion(options.transition) : undefined,
    });
  }

  /** Start a client of this compositor, detached from the director's lifetime. */
  launch(command: string | readonly string[]): void {
    const [file, ...args] = typeof command === "string" ? ["/bin/sh", "-c", command] : command;
    if (!file) throw new TypeError("launch() needs a command.");
    const child = spawn(file, args, {
      detached: true,
      stdio: "ignore",
      env: { ...process.env, WAYLAND_DISPLAY: this.store.display || process.env.WAYLAND_DISPLAY },
    });
    child.on("error", this.onError);
    child.unref();
  }

  private receive(message: ServerMessage): void {
    try {
      switch (message.type) {
        case "event":
          this.container.dispatch(message);
          break;
        case "error":
          console.error(`[stage] compositor: ${message.message}`);
          if (message.fatal) {
            this.connection.stop();
            this.onRejected(message.message);
          }
          break;
        case "welcome":
          this.store.apply(message);
          this.container.requestResync();
          // Before React's first commit there is nothing to show yet; replaying
          // an empty tree would briefly hide every window.
          if (this.container.committed) this.container.flush();
          if (this.applicationsWanted) this.requestApplications();
          break;
        default:
          this.store.apply(message);
      }
    } catch (error) {
      this.onError(error);
    }
  }
}
