import { useCallback, useEffect, useMemo, useSyncExternalStore } from "react";
import { currentSession } from "./session.js";
import type { ApplicationInfo, CameraInfo, OutputInfo, WindowInfo } from "./store.js";

/** Mapped windows in creation order. */
export function useWindows(): readonly WindowInfo[] {
  const store = currentSession().store;
  const all = useSyncExternalStore(store.subscribe, store.windows);
  return useMemo(() => all.filter((window) => window.mapped), [all]);
}

export function useWindow(id: number): WindowInfo | undefined {
  const store = currentSession().store;
  return useSyncExternalStore(store.subscribe, () => store.window(id));
}

/** Outputs left to right, in logical pixels. */
export function useOutputs(): readonly OutputInfo[] {
  const store = currentSession().store;
  return useSyncExternalStore(store.subscribe, store.outputs);
}

/**
 * Where OUTPUT's camera (or the first output's) is headed, updated as pans and
 * zooms happen. Read-only: move the camera with moveCamera(), not by feeding
 * this back into <Camera> props.
 */
export function useCamera(output?: string): CameraInfo | undefined {
  const store = currentSession().store;
  return useSyncExternalStore(store.subscribe, () => store.camera(output));
}

/** Installed applications, sorted by name; empty until the compositor answers. */
export function useApplications(): readonly ApplicationInfo[] {
  const session = currentSession();
  const applications = useSyncExternalStore(session.store.subscribe, session.store.applications);
  useEffect(() => {
    if (session.store.applications() === null) session.requestApplications();
  }, [session]);
  return applications ?? [];
}

/** Text copied this session, newest first, and actions on it. */
export function useClipboard(): { history: readonly string[]; copy: (text: string) => void;
                                  clear: () => void } {
  const session = currentSession();
  const history = useSyncExternalStore(session.store.subscribe, session.store.clipboard);
  return useMemo(() => ({ history, copy: (text: string) => session.copy(text),
                          clear: () => session.store.clearClipboard() }), [history, session]);
}

/** Window with keyboard focus on SEAT, or on the first seat. */
export function useFocusedWindow(seat?: string): number | null {
  const store = currentSession().store;
  return useSyncExternalStore(store.subscribe, () => store.focus(seat));
}

type SetState<T> = (next: T | ((previous: T) => T)) => void;

/**
 * Like useState, but kept across hot reloads, remounts and restarts: values
 * are saved as JSON next to the runtime's state, so they must be serializable.
 * Use it for layout and camera state an edited or restarted world should keep.
 */
export function usePersistentState<T>(key: string, initial: T | (() => T)): [T, SetState<T>] {
  const store = currentSession().store;
  const init = typeof initial === "function" ? initial as () => T : () => initial;
  const subscribe = useCallback((listener: () => void) => store.subscribePersistent(key, listener),
                                [store, key]);
  const value = useSyncExternalStore(subscribe, () => store.getPersistent(key, init));
  const set = useCallback<SetState<T>>((next) => {
    const previous = store.getPersistent(key, init);
    store.setPersistent(key, typeof next === "function" ? (next as (value: T) => T)(previous) : next);
  }, [store, key]);
  return [value, set];
}
