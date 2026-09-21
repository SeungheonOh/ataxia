import fs from 'node:fs/promises';
import path from 'node:path';
import { AXState } from './ax-state.mjs';
import { AccessibilityHelper } from './helper.mjs';
import { ComputerTransport } from './transport.mjs';
import { nativeGuidance } from './guidance.mjs';
import { CuaError, clickOptions, direction, observationOptions, options, pages, parseKey, point, requireThat, selectionOptions, text, sleep } from './common.mjs';

const normalize = value => value.toLowerCase().replace(/\.desktop$/, '');
export class NativeProvider {
  constructor(configuration, emitter) {
    this.transport = configuration.transport ?? new ComputerTransport(configuration);
    this.helper = configuration.helper ?? new AccessibilityHelper(configuration._onChild); this.emitter = emitter; this.targets = new Map(); this.usage = new Map();
  }
  run(fn) { return this.transport.queue.run(fn); }
  documentation() {
    if (!this.documented) {
      this.documented = true;
      this.emitter.write(nativeGuidance);
    }
  }
  async inventory() { return this.run(() => this.transport.read('observe', { mode: 'window' })); }
  appRecords(inventory) {
    const apps = new Map();
    for (const a of inventory.applications ?? []) apps.set(normalize(a.id), { id: a.id, displayName: a.name, isRunning: false });
    for (const w of inventory.windows ?? []) {
      const id = w['app-id'] || `window:${w.id}`, key = normalize(id);
      const entry = apps.get(key) ?? { id, displayName: id };
      entry.isRunning = true; (entry.windowIds ??= []).push(w.id); apps.set(key, entry);
    }
    for (const app of apps.values()) Object.assign(app, this.usage.get(normalize(app.id)));
    return [...apps.values()];
  }
  async listApps(opts = {}) {
    observationOptions(opts); const result = this.appRecords(await this.inventory());
    if (opts.emit !== false) this.emitter.write(result); return result;
  }
  async getApp(query) {
    text(query, 'app', 1024); requireThat(query.length > 0, 'invalid-app', 'Supply an app ID, display name or installed desktop-file path.');
    return this.run(async () => {
      let inventory = await this.transport.read('observe', { mode: 'window' });
      const apps = this.appRecords(inventory);
      let metadata = [];
      try { metadata = await this.helper.call('desktop-info', { ids: (inventory.applications ?? []).map(a => a.id) }); }
      catch (error) { if (path.isAbsolute(query) && !query.endsWith('.desktop')) throw error; }
      const resolvedPath = path.isAbsolute(query) ? await fs.realpath(query).catch(() => query) : null;
      const exact = apps.filter(a => normalize(a.id) === normalize(query) || metadata.some(m => m.id === a.id && (m.filename === query || (resolvedPath && m.executable === resolvedPath))));
      const matches = exact.length ? exact : apps.filter(a => a.displayName?.toLowerCase() === query.toLowerCase());
      requireThat(matches.length === 1, matches.length ? 'ambiguous-app' : 'app-not-found', 'Choose an app ID from cua.listApps().');
      const app = matches[0];
      const runtimeIds = (metadata.find(m => m.id === app.id)?.runtimeIds ?? [app.id]).map(normalize);
      const matchesWindow = w => runtimeIds.includes(normalize(w['app-id'])) || app.id === `window:${w.id}`;
      let windows = inventory.windows.filter(matchesWindow);
      if (!windows.length) {
        const before = new Set(inventory.windows.map(w => w.id));
        await this.transport.batch([{ op: 'launch', application: app.id }]);
        // Installed desktop metadata supplies runtime aliases. Never choose an
        // unrelated newly opened window when its app identity does not match.
        const deadline = Date.now() + 10_000;
        do {
          inventory = await this.transport.read('observe', { mode: 'window' }); windows = inventory.windows.filter(matchesWindow);
          if (!windows.length) await sleep(100);
        } while (!windows.length && Date.now() < deadline);
        const fresh = windows.filter(w => !before.has(w.id)); if (fresh.length) windows = fresh;
      }
      requireThat(windows.length, 'app-window-unavailable', 'The app has no eligible window. Use cua.ataxia.listWindows() to inspect its runtime app ID.');
      if (windows.length > 1) throw new CuaError('ambiguous-window', 'This app has multiple windows. Choose a stable ID with cua.ataxia.getWindow(id).',
        { windows: windows.map(w => ({ id: w.id, title: w.title, available: w.available, 'on-output': w['on-output'] })) });
      const window = windows[0];
      this.requireAvailable(window);
      const target = this.binding(window, app.id);
      this.documentation();
      const old = this.usage.get(normalize(app.id)); this.usage.set(normalize(app.id), { useCount: (old?.useCount ?? 0) + 1, lastUsedDate: new Date().toISOString() });
      await target._getAXState({}); return target;
    });
  }
  binding(window, appId = window['app-id']) {
    let target = this.targets.get(window.id);
    if (!target) { target = new NativeTarget(this, window.id, appId); this.targets.set(window.id, target); }
    return target;
  }
  requireAvailable(window) {
    if (window.available === false) throw new CuaError('window-unavailable',
      'This window is minimized or hidden by World policy. Inspect getWorld(); restore or navigate only when the task calls for it.', { window });
  }
  async getWindow(id) {
    requireThat(Number.isSafeInteger(id), 'invalid-window', 'Use a window ID from cua.ataxia.listWindows().');
    return this.run(async () => {
      const inventory = await this.transport.read('observe', { mode: 'window' }), window = inventory.windows.find(w => w.id === id);
      requireThat(window, 'window-not-found', 'That window is not available in the active session.');
      this.requireAvailable(window);
      this.documentation();
      const target = this.binding(window); await target._getAXState({}); return target;
    });
  }
  async close() { this.helper.close(); await this.run(() => this.transport.disconnect()); }
}

export class NativeTarget {
  constructor(provider, windowId, appId) { this.provider = provider; this.windowId = windowId; this.appId = appId; this.ax = new AXState(); this.image = null; }
  _run(fn) { return this.provider.run(fn); }
  _fields() { return { token: this.provider.transport.token, socket: this.provider.transport.socket, window: this.windowId }; }
  async _select(settle = false, capture = false, actions = []) {
    const reply = await this.provider.transport.batch([
      { op: 'view', mode: 'window', window: this.windowId }, ...actions,
      ...(settle && !capture ? [{ op: 'wait-stable', window: this.windowId, timeout: 2, settle: .15 }] : []),
    ], { capture });
    this.window = reply.windows?.find(w => w.id === this.windowId) ?? this.window;
    if (reply.image) {
      requireThat(reply.image.view === 'window' && reply.image.window === this.windowId,
        'capture-target-mismatch', 'The capture did not belong to this window. Observe again.');
      this.image = reply.image; this.imageStale = false;
    }
    else if (this.image && this.window &&
      (this.image['coordinate-width'] !== this.window.width || this.image['coordinate-height'] !== this.window.height ||
       this.image['origin-x'] !== this.window['origin-x'] || this.image['origin-y'] !== this.window['origin-y'])) this.imageStale = true;
    return reply;
  }
  async _snapshot(disableDiffing = false) {
    let snapshot;
    try { snapshot = await this.provider.helper.call('snapshot', this._fields()); }
    catch (error) {
      if (!['accessibility-unavailable'].includes(error.code)) throw error;
      snapshot = { nodes: [], unavailable: error.message };
    }
    return this.ax.update(snapshot.nodes, { ...snapshot, disableDiffing,
      header: `App ${JSON.stringify(this.appId)} · window ${this.windowId} · ${JSON.stringify(this.window?.title ?? '')}` });
  }
  async _getAXState(opts) {
    observationOptions(opts, true);
    let updating = false;
    try { await this._select(true); }
    catch (error) {
      // Acquisition/observation may see a video or continuously repainting app.
      // The focus already completed; read current state without replaying input.
      if (error.code !== 'wait-timeout' || error.details?.completed !== 1) throw error;
      const inventory = await this.provider.transport.read('observe', { mode: 'window' });
      this.window = inventory.windows.find(window => window.id === this.windowId);
      requireThat(this.window, 'window-not-found', 'The observed window disappeared while updating.');
      updating = true;
    }
    const state = (updating ? 'Application is updating; this is a current snapshot.\n' : '') + await this._snapshot(opts.disableDiffing);
    if (opts.emit !== false) this.provider.emitter.write(state); return state;
  }
  getAXState(opts = {}) { return this._run(() => this._getAXState(opts)); }
  async _imageBytes(image) {
    requireThat(image?.path, 'capture-failed', 'No screenshot was returned.');
    requireThat(image.view === 'window' && image.window === this.windowId, 'capture-target-mismatch', 'The capture did not belong to this window. Observe again.');
    const stat = await fs.stat(image.path);
    requireThat(stat.isFile() && stat.size <= 24 * 1024 * 1024, 'invalid-image', 'Screenshot exceeds its size limit.');
    return new Uint8Array(await fs.readFile(image.path));
  }
  getScreenshot(opts = {}) {
    observationOptions(opts);
    return this._run(async () => {
      const reply = await this._select(true, true), bytes = await this._imageBytes(reply.image);
      this.ax.invalidate();
      if (opts.emit !== false) {
        this.provider.emitter.write(`Window ${this.windowId} · ${JSON.stringify(this.window?.title ?? '')} · ${reply.image.width}×${reply.image.height} screenshot pixels (window content and popups)`);
        this.provider.emitter.emitImage({ bytes, mimeType: 'image/png' });
      }
      return bytes;
    });
  }
  getAXStateAndScreenshot(opts = {}) {
    observationOptions(opts, true);
    return this._run(async () => {
      const reply = await this._select(true, true), state = await this._snapshot(opts.disableDiffing), screenshot = await this._imageBytes(reply.image);
      if (opts.emit !== false) { this.provider.emitter.write(state); this.provider.emitter.emitImage({ bytes: screenshot, mimeType: 'image/png' }); }
      return { state, screenshot };
    });
  }
  async _coordinate(target) {
    if (typeof target === 'number') {
      const element = this.ax.get(target);
      const p = await this.provider.helper.call('point', { ...this._fields(), element: element.key }); return [p.x, p.y];
    }
    const [x, y] = point(target);
    requireThat(!this.imageStale, 'stale-screenshot', 'Window geometry changed. Capture this window again before using screenshot coordinates.');
    // Screenshot coordinates are pixels in the most recent image. Before any
    // screenshot, coordinates are window-local logical pixels.
    if (this.image) return [x * this.image['coordinate-width'] / this.image.width, y * this.image['coordinate-height'] / this.image.height];
    return [x, y];
  }
  click(target, opts = {}) {
    const { mouseButton, clickCount } = clickOptions(opts);
    return this._run(async () => {
      await this._select();
      if (typeof target === 'number' && mouseButton === 'left' && clickCount === 1) {
        const element = this.ax.get(target);
        try { await this.provider.helper.call('click', { ...this._fields(), element: element.key }); return; }
        catch (error) { if (error.code !== 'coordinate-required') throw error; }
      }
      const [x, y] = await this._coordinate(target);
      await this._select(false, false, [{ op: 'move', x, y, duration: .016 },
        ...Array.from({ length: clickCount }, () => ({ op: 'button', button: mouseButton }))]);
    });
  }
  drag(from, to) {
    point(from); point(to);
    return this._run(async () => {
      await this._select(); const [x0, y0] = await this._coordinate(from), [x, y] = await this._coordinate(to);
      await this._select(false, false, [{ op: 'move', x: x0, y: y0, duration: .016 }, { op: 'button', state: 'down' },
        { op: 'move', x, y, duration: .2 }, { op: 'button', state: 'up' }]);
    });
  }
  pressKey(key) {
    const chord = parseKey(key);
    return this._run(async () => { await this._select(false, false, [{ op: 'key', ...chord }]); });
  }
  typeText(value) {
    text(value); if (!value) return Promise.resolve();
    // Split by Unicode scalar, never in the middle of a surrogate pair.
    const chars = Array.from(value), chunks = [];
    for (let i = 0; i < chars.length; i += 200) chunks.push(chars.slice(i, i + 200).join(''));
    return this._run(async () => {
      for (let i = 0; i < chunks.length; i += 14) await this._select(false, false, chunks.slice(i, i + 14).map(text => ({ op: 'type', text })));
    });
  }
  paste(value, opts = {}) {
    text(value, 'text', 16000); options(opts, ['format']); const format = opts.format ?? 'text';
    requireThat(['text', 'md', 'html'].includes(format), 'invalid-format', 'Use text, md or html.');
    return this._run(async () => { await this._select(false, false, [{ op: 'paste', text: value, format }]); });
  }
  scroll(target, dir, count = 1) {
    dir = direction(dir); count = pages(count);
    return this._run(async () => {
      await this._select(); const [x, y] = await this._coordinate(target), vertical = dir === 'up' || dir === 'down';
      let remaining = (vertical ? this.window.height : this.window.width) * .8 * count;
      const sign = dir === 'up' || dir === 'left' ? -1 : 1;
      const actions = [{ op: 'move', x, y, duration: .016 }];
      while (remaining > 0) { const amount = Math.min(1000, remaining); actions.push({ op: 'scroll', [vertical ? 'y' : 'x']: sign * amount }); remaining -= amount; }
      for (let i = 0; i < actions.length; i += 14) await this._select(false, false, actions.slice(i, i + 14));
    });
  }
  selectText(index, value, opts = {}) {
    text(value); opts = selectionOptions(opts);
    return this._run(async () => {
      const element = this.ax.get(index); await this._select();
      await this.provider.helper.call('select-text', { ...this._fields(), element: element.key, text: value, options: opts });
    });
  }
  setValue(index, value) {
    text(value);
    return this._run(async () => {
      const element = this.ax.get(index); await this._select();
      await this.provider.helper.call('set-value', { ...this._fields(), element: element.key, value });
    });
  }
  performSecondaryAction(index, action) {
    text(action, 'action', 100);
    return this._run(async () => {
      const element = this.ax.get(index); requireThat(element.actions.includes(action), 'unsupported-action', 'Use an action exposed for this element.');
      await this._select(); await this.provider.helper.call('secondary', { ...this._fields(), element: element.key, action });
    });
  }
}
