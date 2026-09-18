import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { CDP } from './cdp.mjs';
import { BrowserTarget, navigationURL } from './browser-target.mjs';
import { CuaError, SerialQueue, observationOptions, options, requireThat, text } from './common.mjs';

export async function findChromium() {
  if (process.env.ATAXIA_CUA_BROWSER) return process.env.ATAXIA_CUA_BROWSER;
  for (const name of ['chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable']) {
    for (const directory of (process.env.PATH ?? '').split(path.delimiter)) {
      const candidate = path.join(directory, name); try { await fs.access(candidate, fs.constants.X_OK); return candidate; } catch {}
    }
  }
  const cache = path.join(os.homedir(), '.cache/ms-playwright');
  for (const directory of (await fs.readdir(cache).catch(() => [])).filter(p => /^chromium-\d+$/.test(p)).sort().reverse()) {
    for (const subdir of ['chrome-linux64', 'chrome-linux']) {
      const candidate = path.join(cache, directory, subdir, 'chrome'); try { await fs.access(candidate, fs.constants.X_OK); return candidate; } catch {}
    }
  }
  return null;
}

export class BrowserProvider {
  constructor({ browsers, browserConfigFile = process.env.ATAXIA_CUA_BROWSERS, headless = process.env.ATAXIA_CUA_HEADLESS === '1', _onChild } = {}, emitter) {
    this.onChild = _onChild;
    this.configured = browsers; this.configFile = browserConfigFile; this.headless = headless; this.emitter = emitter; this.instances = new Map();
  }
  async configurations() {
    if (this.configured) return this.configured;
    if (this.configFile) {
      const stat = await fs.stat(this.configFile); requireThat(stat.size < 65536, 'invalid-browser-config', 'Browser configuration is too large.');
      const entries = JSON.parse(await fs.readFile(this.configFile, 'utf8')); requireThat(Array.isArray(entries), 'invalid-browser-config', 'Browser configuration must be an array.');
      this.configured = entries; return entries;
    }
    const executable = await findChromium();
    return executable ? [{ id: 'ataxia', name: 'Ataxia browser', family: 'chromium', type: 'cdp', executable, headless: this.headless, profileName: 'Isolated Ataxia profile' }] : [];
  }
  async list(opts = {}) {
    observationOptions(opts); const configurations = await this.configurations(), ids = new Set();
    const result = configurations.map(config => {
      text(config.id, 'browser id', 80); requireThat(config.id && !config.id.includes(':') && !ids.has(config.id), 'invalid-browser-config', 'Browser IDs must be unique, nonempty and contain no colon.'); ids.add(config.id);
      requireThat(!config.type || config.type === 'cdp', 'unsupported-browser-provider', 'This adapter supports CDP browser providers. Native Firefox remains available through getApp.');
      return { id: config.id, name: config.name ?? config.id, family: config.family ?? 'chromium', type: 'cdp', ...(config.profileName ? { profileName: config.profileName } : {}), ...(config.metadata ? { metadata: config.metadata } : {}) };
    });
    if (opts.emit !== false) this.emitter.write(result); return result;
  }
  async get(id) {
    const configurations = await this.configurations(), config = configurations.find(c => c.id === id);
    requireThat(config, 'browser-not-found', 'Choose a browser ID from cua.listBrowsers().');
    requireThat(!config.type || config.type === 'cdp', 'unsupported-browser-provider', 'Only the CDP provider is implemented.');
    let browser = this.instances.get(id);
    if (!browser) { browser = new Browser({ ...config, onChild: this.onChild }, this.emitter); this.instances.set(id, browser); }
    return browser;
  }
  async select(opts = {}) {
    options(opts, ['id', 'url']); const browsers = await this.list({ emit: false });
    let id = opts.id;
    if (!id && opts.url) {
      const url = navigationURL(opts.url), matches = [];
      for (const entry of browsers) {
        const browser = await this.get(entry.id); if ((await browser.tabs()).some(t => t.url === url)) matches.push(entry.id);
      }
      requireThat(matches.length <= 1, 'ambiguous-browser', 'The URL exists in multiple browsers; specify id.'); id = matches[0];
      requireThat(id, 'browser-not-found', 'No configured browser has a tab with this URL.');
    }
    if (!id) { requireThat(browsers.length === 1, browsers.length ? 'ambiguous-browser' : 'browser-unavailable', 'Configure or install a Chromium browser, then choose an ID from cua.listBrowsers().'); id = browsers[0].id; }
    const browser = await this.get(id); browser.emitDocumentation(); return browser;
  }
  async listTabs(opts = {}) {
    options(opts, ['browser', 'emit']);
    const browsers = await this.list({ emit: false }), selected = opts.browser ? browsers.filter(b => b.id === opts.browser) : browsers;
    requireThat(!opts.browser || selected.length, 'browser-not-found', 'That browser is not configured.');
    const result = [];
    for (const entry of selected) result.push(...await (await this.get(entry.id)).tabs());
    if (opts.emit !== false) this.emitter.write(result); return result;
  }
  async getTab(id, opts = {}) {
    text(id, 'tab id', 200); options(opts, ['browser']);
    const matches = (await this.listTabs({ ...opts, emit: false })).filter(t => t.id === id || t.providerTabId === id);
    requireThat(matches.length === 1, matches.length ? 'ambiguous-tab' : 'tab-not-found', 'Choose a tab ID from cua.listTabs().');
    const info = matches[0], browser = await this.get(info.browserId); browser.emitDocumentation();
    const target = browser.binding(info.providerTabId); await target.getAXState(); return target;
  }
  async close() { for (const browser of this.instances.values()) await browser.dispose(); }
}

const DOCUMENTATION = `Ataxia CDP browser: use cua.listTabs(), cua.getTab(id), or cua.createBrowserTab(browser.browserId, url, options).\nElement indices come from getAXState(); screenshot-only observations invalidate them. Coordinates use the latest screenshot's pixels, or CSS pixels before a screenshot. Actions do not emit state; batch known actions, then observe. getBrowser selects without opening a tab. visible:false creates a background tab; it does not hide an existing browser window. sessionName chooses an isolated browser context before creation. markDeliverable/markHandoff retain the tab during adapter cleanup while the REPL stays running. Use cua.ataxia.tabMarks() to inspect retained tabs. HTML paste requires a focused rich-text editor; Markdown is inserted as source. No browser permissions or certificate checks are changed.`;

export class Browser {
  constructor(config, emitter) {
    this.config = config; this.browserId = config.id; this.emitter = emitter; this.targets = new Map(); this.marks = new Map(); this.contexts = new Map(); this.queue = new SerialQueue(); this.created = new Set();
  }
  async documentation() { return DOCUMENTATION; }
  emitDocumentation() { if (!this.documented) { this.documented = true; this.emitter.write(DOCUMENTATION); } }
  async connect() {
    if (this.connection && !this.connection.closed) return this.connection;
    if (this.connecting) return this.connecting;
    this.connecting = this.start();
    try { return await this.connecting; } finally { this.connecting = null; }
  }
  async start() {
    if (this.config.endpoint) this.connection = await CDP.websocket(this.config.endpoint);
    else {
      requireThat(this.config.executable, 'browser-unavailable', 'No browser executable is configured.');
      this.profile = await fs.mkdtemp(path.join(os.tmpdir(), 'ataxia-cua-browser-'));
      const args = ['--remote-debugging-pipe', `--user-data-dir=${this.profile}`, '--no-first-run', '--no-default-browser-check', '--no-startup-window', '--window-size=1280,900', '--force-device-scale-factor=1'];
      if (this.config.headless) args.push('--headless=new');
      else if (process.env.WAYLAND_DISPLAY) args.push('--ozone-platform=wayland');
      // Extra flags come only from trusted host configuration, never from page content.
      if (this.config.args) { requireThat(Array.isArray(this.config.args) && this.config.args.every(a => typeof a === 'string'), 'invalid-browser-config', 'args must be a host-configured string array.'); args.push(...this.config.args); }
      const child = spawn(this.config.executable, args, { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'] });
      this.process = child; let diagnostic = '';
      this.config.onChild?.(child.pid, this.profile);
      child.once('exit', () => this.config.onChild?.(-child.pid));
      child.stderr.on('data', bytes => { diagnostic = (diagnostic + bytes.toString()).slice(-4000); });
      this.connection = CDP.pipe(child);
      try { await this.connection.call('Browser.getVersion', {}, undefined, 12_000); }
      catch (error) { child.kill(); this.connection.close(); await fs.rm(this.profile, { recursive: true, force: true }); throw new CuaError('browser-launch-failed', `${error.message}\n${diagnostic}`); }
    }
    await this.connection.call('Target.setDiscoverTargets', { discover: true });
    return this.connection;
  }
  binding(id) {
    let target = this.targets.get(id);
    if (!target) { target = new BrowserTarget(this, id); this.targets.set(id, target); }
    return target;
  }
  async tabs() {
    // Inventory never starts an unopened managed browser.
    if (!this.connection && !this.config.endpoint) return [];
    const connection = await this.connect(), { targetInfos } = await connection.call('Target.getTargets');
    return targetInfos.filter(t => t.type === 'page' && !t.url.startsWith('devtools:')).map(t => ({ id: `${this.browserId}:${t.targetId}`, providerTabId: t.targetId, browserId: this.browserId, title: t.title, url: t.url }));
  }
  async tabInfo(id) {
    const { targetInfo } = await this.connection.call('Target.getTargetInfo', { targetId: id }); return { title: targetInfo.title, url: targetInfo.url };
  }
  async create(url = 'about:blank', opts = {}) {
    options(opts, ['visible', 'sessionName']);
    if (opts.visible !== undefined) requireThat(typeof opts.visible === 'boolean', 'invalid-options', 'visible must be a boolean.');
    requireThat(!(this.config.headless && opts.visible === true), 'unsupported-option', 'A headless provider cannot create a visible tab.');
    if (opts.sessionName !== undefined) { text(opts.sessionName, 'sessionName', 100); requireThat(opts.sessionName.length > 0, 'invalid-options', 'sessionName must be nonempty.'); }
    url = navigationURL(url); this.emitDocumentation();
    return this.queue.run(async () => {
      const connection = await this.connect(); let browserContextId;
      if (opts.sessionName) {
        browserContextId = this.contexts.get(opts.sessionName);
        if (!browserContextId) { browserContextId = (await connection.call('Target.createBrowserContext', { disposeOnDetach: false })).browserContextId; this.contexts.set(opts.sessionName, browserContextId); }
      }
      const { targetId } = await connection.call('Target.createTarget', { url, ...(browserContextId ? { browserContextId } : {}), ...(opts.visible !== undefined ? { background: !opts.visible } : {}) });
      this.created.add(targetId); const target = this.binding(targetId);
      await target.getAXState(); return target;
    });
  }
  async dispose({ force = false } = {}) {
    if (!this.connection || this.connection.closed) return;
    for (const targetId of this.created) if (force || !this.marks.has(targetId)) await this.connection.call('Target.closeTarget', { targetId }).catch(() => {});
    // Retained tabs stay in the persistent REPL's browser until explicit close.
    if (!force && this.marks.size) return;
    if (this.process) { await this.connection.call('Browser.close').catch(() => {}); this.process.kill(); }
    this.connection.close();
    if (this.profile) await fs.rm(this.profile, { recursive: true, force: true });
  }
}
