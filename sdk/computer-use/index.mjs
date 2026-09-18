import { NativeProvider } from './native.mjs';
import { BrowserProvider } from './browser.mjs';
import { desktopMethods } from './desktop.mjs';
import { makeEmitter, observationOptions, options, requireThat } from './common.mjs';
export { CuaError } from './common.mjs';
export { ComputerTransport } from './transport.mjs';

export function createCua(configuration = {}) {
  const emitter = makeEmitter(configuration.nodeRepl), native = new NativeProvider(configuration, emitter), browsers = new BrowserProvider(configuration, emitter);
  const cua = {
    async getState(opts = {}) {
      observationOptions(opts); const state = { apps: [], browsers: [] }, errors = [];
      const results = await Promise.allSettled([native.listApps({ emit: false }), (async () => {
        const entries = await browsers.list({ emit: false }), states = [];
        for (const entry of entries) {
          try { states.push({ ...entry, tabs: (await (await browsers.get(entry.id)).tabs()).map(({ browserId, ...tab }) => tab) }); }
          catch (error) { states.push({ ...entry, tabs: [] }); errors.push(`Browser ${entry.id}: ${error.message}`); }
        }
        return states;
      })()]);
      if (results[0].status === 'fulfilled') state.apps = results[0].value; else errors.push(`Apps: ${results[0].reason.message}`);
      if (results[1].status === 'fulfilled') state.browsers = results[1].value; else errors.push(`Browsers: ${results[1].reason.message}`);
      if (errors.length) state.errors = errors;
      if (opts.emit !== false) emitter.write(state); return state;
    },
    getApp: app => native.getApp(app), listApps: opts => native.listApps(opts),
    getBrowser: opts => browsers.select(opts), listBrowsers: opts => browsers.list(opts),
    createBrowserTab: async (id, url, opts) => (await browsers.get(id)).create(url, opts),
    getTab: (id, opts) => browsers.getTab(id, opts), listTabs: opts => browsers.listTabs(opts),
    // Separate namespace: extensions never change the supplied Codex method shapes.
    ataxia: {
      async connect(opts = {}) {
        options(opts, ['name', 'purpose', 'output']);
        if (opts.name) native.transport.name = opts.name; if (opts.purpose) native.transport.purpose = opts.purpose;
        return native.run(async () => (await native.transport.connect(opts.output === undefined ? {} : { output: opts.output })).session);
      },
      async status() { return native.run(async () => (await native.transport.status()).session); },
      async capabilities() {
        let server;
        try { server = await native.transport.raw({ op: 'capabilities' }); } catch (error) { server = { available: false, error: error.message }; }
        return { interface: 'codex-cua', native: server, browser: { providers: ['cdp'], ...{ htmlPaste: 'focused-contenteditable', markdownPaste: 'source' } },
          extensions: Object.keys(cua.ataxia) };
      },
      async listWindows(opts = {}) { observationOptions(opts); const { windows } = await native.inventory(); if (opts.emit !== false) emitter.write(windows); return windows; },
      getWindow: id => native.getWindow(id),
      ...desktopMethods(native, emitter),
      async batch(actions, opts = {}) {
        options(opts, ['capture', 'settle']); requireThat(Array.isArray(actions), 'invalid-batch', 'Use an array of Ataxia protocol actions.');
        return native.run(() => native.transport.batch(actions, opts));
      },
      async captureDesktop(opts = {}) {
        observationOptions(opts);
        return native.run(async () => {
          const previous = (await native.transport.status()).session;
          try {
            const reply = await native.transport.batch([{ op: 'view', mode: 'desktop' }], { capture: true });
            const fs = await import('node:fs/promises'), bytes = new Uint8Array(await fs.readFile(reply.image.path));
            if (opts.emit !== false) emitter.emitImage({ bytes, mimeType: 'image/png' }); return { ...reply.image, bytes };
          } finally {
            if (previous.view === 'window') await native.transport.send('view', { mode: 'window', ...(previous.window ? { window: previous.window } : {}) });
            for (const target of native.targets.values()) target.ax.invalidate();
          }
        });
      },
      tabMarks() { return [...browsers.instances.values()].flatMap(b => [...b.marks].map(([id, mark]) => ({ browserId: b.browserId, id: `${b.browserId}:${id}`, mark }))); },
      metrics() { return { nativeRequests: native.transport.requests, browserRequests: [...browsers.instances.values()].reduce((n, b) => n + (b.connection?.requests ?? 0), 0) }; },
      async disconnect() { await native.close(); },
    },
  };
  Object.defineProperty(cua, Symbol.asyncDispose, { value: async () => { await Promise.allSettled([native.close(), browsers.close()]); } });
  return cua;
}
