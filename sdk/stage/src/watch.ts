// Source watching shared by the world runtime and web page bundles.

import { watch, type FSWatcher } from "node:fs";
import { dirname, join, resolve } from "node:path";

/**
 * Rebuilds when a bundled source changes. esbuild's own watch mode polls; this
 * watches the sources' directories through inotify, so an unchanged world
 * costs nothing, and editors that save by renaming are still noticed.
 */
export class SourceWatcher {
  private readonly watchers = new Map<string, FSWatcher>();
  private files = new Set<string>();
  private pending: NodeJS.Timeout | null = null;

  constructor(private readonly rebuild: () => void) {}

  track(inputs: string[]): void {
    this.files = new Set(inputs.filter((input) => !input.includes("node_modules"))
                               .map((input) => resolve(input)));
    const directories = new Set([...this.files].map((file) => dirname(file)));
    for (const [directory, watcher] of this.watchers) {
      if (!directories.has(directory)) {
        watcher.close();
        this.watchers.delete(directory);
      }
    }
    for (const directory of directories) {
      if (this.watchers.has(directory)) continue;
      this.watchers.set(directory, watch(directory, (_event, name) => {
        if (name && this.files.has(join(directory, name))) this.schedule();
      }));
    }
  }

  close(): void {
    if (this.pending) clearTimeout(this.pending);
    for (const watcher of this.watchers.values()) watcher.close();
    this.watchers.clear();
  }

  private schedule(): void {
    // One save often produces several events; rebuild once they settle.
    if (this.pending) clearTimeout(this.pending);
    this.pending = setTimeout(() => {
      this.pending = null;
      this.rebuild();
    }, 40);
  }
}
