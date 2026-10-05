// React host configuration for Stage scene nodes.
//
// Instances exist locally from render time but reach the compositor only when
// a commit attaches them, so work React abandons is never sent. Each commit
// becomes exactly one `commit` message. After a reconnect the container
// replays its whole tree as one commit beginning with `reset`, letting the
// compositor hand on-screen motion from the old scene to the new one.

import createReconciler from "react-reconciler";
import { ConcurrentRoot, DefaultEventPriority, NoEventPriority } from "react-reconciler/constants.js";
import { createContext, version } from "react";
import { type EventHandler, type HostType, diffWire, isTextContent, normalizeProps } from "./props.js";
import type { Op, WireEvent, WireProps } from "./protocol.js";
import { toStageEvent } from "./events.js";

export interface Instance {
  id: number;
  type: HostType;
  container: Container;
  wire: WireProps;
  handlers: Map<string, EventHandler>;
  children: Instance[];
  /** Hidden by Suspense: shown as invisible without forgetting its props. */
  hidden: boolean;
  attached: boolean;
}

type Parent = Instance | Container;

export class Container {
  readonly id = 0;
  readonly children: Instance[] = [];
  private readonly instances = new Map<number, Instance>();
  private nextId = 1;
  private ops: Op[] = [];
  private resync = true;

  /** Receives each commit's ops; the session forwards them to the compositor. */
  constructor(private readonly send: (ops: Op[]) => void) {}

  create(type: HostType, props: Record<string, unknown>): Instance {
    const { wire, handlers } = normalizeProps(type, props);
    return { id: this.nextId++, type, container: this, wire, handlers, children: [],
             hidden: false, attached: false };
  }

  /** True once React has committed into this container. */
  committed = false;

  /** Replace the next flush with a replay of the whole tree, e.g. after connecting. */
  requestResync(): void {
    this.resync = true;
  }

  commit(): void {
    this.committed = true;
    this.flush();
  }

  flush(): void {
    if (this.resync) {
      this.resync = false;
      this.ops = [{ op: "reset" }];
      for (const child of this.children) {
        this.emitCreate(child);
        this.ops.push({ op: "insert", parent: this.id, id: child.id, before: null });
      }
    }
    if (this.ops.length === 0) return;
    const ops = this.ops;
    this.ops = [];
    this.send(ops);
  }

  dispatch(message: WireEvent): void {
    const instance = this.instances.get(message.node);
    const handler = instance?.handlers.get(message.name);
    const declared = instance && settledKeys(message.name) ? placement(instance) : null;
    // Input is discrete: its updates render synchronously at the end of this
    // task, like a DOM click, instead of waiting for the scheduler.
    if (handler) reconciler.discreteUpdates(() => handler(toStageEvent(message)), 0, 0, 0, 0);
    // A native drag or resize leaves the node where the pointer did. Once the
    // handler's render has committed, any place it did not change is declared
    // again, so the node returns to it instead of staying stranded.
    if (instance && declared) queueMicrotask(() => this.redeclare(instance, declared));
  }

  private redeclare(instance: Instance, declared: WireProps): void {
    if (!instance.attached) return;
    const current = placement(instance);
    const unchanged: WireProps = {};
    for (const [key, value] of Object.entries(declared)) {
      if (current[key] === value) unchanged[key] = value;
    }
    if (Object.keys(unchanged).length === 0) return;
    this.ops.push({ op: "set", id: instance.id, props: unchanged });
    this.flush();
  }

  insert(parent: Parent, child: Instance, before: Instance | null): void {
    const siblings = parent.children;
    const existing = siblings.indexOf(child);
    if (existing >= 0) siblings.splice(existing, 1);
    if (before) siblings.splice(siblings.indexOf(before), 0, child);
    else siblings.push(child);
    if (parent === this || (parent as Instance).attached) {
      if (!child.attached) this.emitCreate(child);
      this.ops.push({ op: "insert", parent: parent.id, id: child.id, before: before?.id ?? null });
    }
  }

  remove(parent: Parent, child: Instance): void {
    parent.children.splice(parent.children.indexOf(child), 1);
    if (child.attached) {
      this.ops.push({ op: "remove", parent: parent.id, id: child.id });
      this.detach(child);
    }
  }

  update(instance: Instance, props: Record<string, unknown>): void {
    const previous = sent(instance);
    const { wire, handlers } = normalizeProps(instance.type, props);
    instance.wire = wire;
    instance.handlers = handlers;
    this.sendChanges(instance, previous);
  }

  setHidden(instance: Instance, hidden: boolean): void {
    const previous = sent(instance);
    instance.hidden = hidden;
    this.sendChanges(instance, previous);
  }

  private sendChanges(instance: Instance, previous: WireProps): void {
    const changes = diffWire(previous, sent(instance));
    if (changes && instance.attached) this.ops.push({ op: "set", id: instance.id, props: changes });
  }

  private emitCreate(instance: Instance): void {
    instance.attached = true;
    this.instances.set(instance.id, instance);
    this.ops.push({ op: "create", id: instance.id, type: instance.type, props: sent(instance) });
    for (const child of instance.children) {
      this.emitCreate(child);
      this.ops.push({ op: "insert", parent: instance.id, id: child.id, before: null });
    }
  }

  private detach(instance: Instance): void {
    instance.attached = false;
    this.instances.delete(instance.id);
    for (const child of instance.children) this.detach(child);
  }
}

const placementKeys = ["x", "y", "width", "height"] as const;

function settledKeys(event: string): boolean {
  return event === "dragend" || event === "resizeend";
}

/** The declared x, y, width and height of INSTANCE. */
function placement(instance: Instance): WireProps {
  const wire = sent(instance);
  const out: WireProps = {};
  for (const key of placementKeys) if (wire[key] !== undefined) out[key] = wire[key];
  return out;
}

function sent(instance: Instance): WireProps {
  return instance.hidden ? { ...instance.wire, visible: false } : instance.wire;
}

let updatePriority: number = NoEventPriority;
const hostContext = {};

// The published typings trail react-reconciler 0.34, so the configuration is
// checked against the methods React actually calls rather than those types.
const hostConfig = {
  rendererPackageName: "@ataxia/stage",
  rendererVersion: version,
  isPrimaryRenderer: true,
  supportsMutation: true,
  supportsPersistence: false,
  supportsHydration: false,
  supportsMicrotasks: true,
  scheduleMicrotask: queueMicrotask,
  scheduleTimeout: setTimeout,
  cancelTimeout: clearTimeout,
  noTimeout: -1,
  NotPendingTransition: null,
  HostTransitionContext: createContext(null),

  // React treats a null host context as missing; Stage needs no per-subtree context.
  getRootHostContext: () => hostContext,
  getChildHostContext: () => hostContext,
  getPublicInstance: (instance: Instance) => instance,
  prepareForCommit: () => null,
  resetAfterCommit: (container: Container) => container.commit(),
  preparePortalMount: () => undefined,
  // A Text node's string children are its content, not child nodes.
  shouldSetTextContent: (type: HostType, props: Record<string, unknown>) =>
    type === "text" && isTextContent(props.children),
  createTextInstance(text: string): never {
    throw new TypeError(`Stage has no text nodes; remove the string ${JSON.stringify(text)}`);
  },

  createInstance(type: HostType, props: Record<string, unknown>, container: Container) {
    return container.create(type, props);
  },
  appendInitialChild(parent: Instance, child: Instance) {
    parent.children.push(child);
  },
  finalizeInitialChildren: () => false,

  appendChild(parent: Instance, child: Instance) {
    parent.container.insert(parent, child, null);
  },
  appendChildToContainer(container: Container, child: Instance) {
    container.insert(container, child, null);
  },
  insertBefore(parent: Instance, child: Instance, before: Instance) {
    parent.container.insert(parent, child, before);
  },
  insertInContainerBefore(container: Container, child: Instance, before: Instance) {
    container.insert(container, child, before);
  },
  removeChild(parent: Instance, child: Instance) {
    parent.container.remove(parent, child);
  },
  removeChildFromContainer(container: Container, child: Instance) {
    container.remove(container, child);
  },
  clearContainer(container: Container) {
    for (const child of [...container.children]) container.remove(container, child);
  },
  commitUpdate(instance: Instance, _type: HostType, _previous: unknown, next: Record<string, unknown>) {
    instance.container.update(instance, next);
  },
  hideInstance(instance: Instance) {
    instance.container.setHidden(instance, true);
  },
  unhideInstance(instance: Instance) {
    instance.container.setHidden(instance, false);
  },
  detachDeletedInstance: () => undefined,

  setCurrentUpdatePriority(priority: number) {
    updatePriority = priority;
  },
  getCurrentUpdatePriority: () => updatePriority,
  resolveUpdatePriority: () => (updatePriority === NoEventPriority ? DefaultEventPriority : updatePriority),
  resolveEventType: () => null,
  resolveEventTimeStamp: () => -1.1,
  trackSchedulerEvent: () => undefined,
  shouldAttemptEagerTransition: () => false,
  requestPostPaintCallback: () => undefined,
  maySuspendCommit: () => false,
  maySuspendCommitOnUpdate: () => false,
  maySuspendCommitInSyncRender: () => false,
  preloadInstance: () => true,
  startSuspendingCommit: () => undefined,
  suspendInstance: () => undefined,
  suspendOnActiveViewTransition: () => undefined,
  waitForCommitToBeReady: () => null,
  getSuspendedCommitReason: () => null,
  resetFormInstance: () => undefined,
  beforeActiveInstanceBlur: () => undefined,
  afterActiveInstanceBlur: () => undefined,
  getInstanceFromNode: () => null,
  getInstanceFromScope: () => null,
  prepareScopeUpdate: () => undefined,
  createFragmentInstance: () => null,
};

type Reconciler = ReturnType<typeof createReconciler>;
export const reconciler: Reconciler = createReconciler(hostConfig as never);

export function createRoot(container: Container, onError: (error: unknown) => void) {
  return reconciler.createContainer(container, ConcurrentRoot, null, false, null, "stage",
    onError, onError, onError, () => undefined, null);
}
