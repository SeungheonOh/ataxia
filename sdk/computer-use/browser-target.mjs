import { AXState } from './ax-state.mjs';
import { CuaError, SerialQueue, clickOptions, direction, observationOptions, options, pages, parseKey, point, requireThat, selectionOptions, text } from './common.mjs';

function checkResult(reply) {
  if (reply.exceptionDetails) throw new CuaError('browser-action-failed', reply.exceptionDetails.exception?.description ?? reply.exceptionDetails.text);
  return reply.result?.value;
}
// This executes in the page; all arguments remain data, never interpolated code.
function elementAction(operation, args) {
  if (!this.isConnected) throw new Error('stale-element: element is detached');
  if (operation === 'point') {
    this.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
    const r = this.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) throw new Error('element-not-visible');
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  }
  if (operation === 'set-value') {
    const value = args[0]; this.focus({ preventScroll: true });
    if (this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement || this instanceof HTMLSelectElement) {
      if (this.disabled || this.readOnly || this.type === 'file') throw new Error('unsupported-action: control is not editable');
      Object.getOwnPropertyDescriptor(Object.getPrototypeOf(this), 'value').set.call(this, value);
      this.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: value }));
      this.dispatchEvent(new Event('change', { bubbles: true }));
      if (this.value !== value) throw new Error('invalid-value: control did not accept the requested value');
    } else if (this.isContentEditable) {
      this.textContent = value;
      this.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertReplacementText', data: value }));
    } else throw new Error('unsupported-action: element has no editable value');
    return;
  }
  if (operation === 'select-text') {
    const [needle, options] = args;
    const input = this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement;
    if (!(input || this.isContentEditable) || this.type === 'password') throw new Error('unsupported-action: select text in an editable, unprotected element');
    const content = input ? this.value : this.textContent, matches = [];
    for (let at = content.indexOf(needle); at !== -1; at = content.indexOf(needle, at + 1))
      if ((options.prefix === undefined || content.slice(0, at).endsWith(options.prefix)) &&
          (options.suffix === undefined || content.slice(at + needle.length).startsWith(options.suffix))) matches.push(at);
    if (matches.length !== 1) throw new Error(matches.length ? 'ambiguous-text: use prefix and suffix' : 'text-not-found');
    let start = matches[0], end = start + needle.length;
    if (options.selectionType === 'cursor_before') end = start;
    if (options.selectionType === 'cursor_after') start = end;
    this.focus({ preventScroll: true });
    if (input) this.setSelectionRange(start, end);
    else {
      const walker = this.ownerDocument.createTreeWalker(this, NodeFilter.SHOW_TEXT);
      let current, offset = 0, first, last;
      while ((current = walker.nextNode())) {
        const next = offset + current.textContent.length;
        if (!first && start <= next) first = [current, start - offset];
        if (end <= next) { last = [current, end - offset]; break; }
        offset = next;
      }
      if (!first || !last) throw new Error('text-not-found');
      const range = this.ownerDocument.createRange(); range.setStart(...first); range.setEnd(...last);
      const selection = this.ownerDocument.getSelection(); selection.removeAllRanges(); selection.addRange(range);
    }
    return;
  }
  throw new Error('unsupported-action');
}

function keyEvent(chord) {
  const modifiers = chord.modifiers.reduce((value, m) => value | ({ Alt_L: 1, Control_L: 2, Super_L: 4, Shift_L: 8 }[m] ?? 0), 0);
  const specials = { Return: ['Enter', 'Enter', 13], Tab: ['Tab', 'Tab', 9], BackSpace: ['Backspace', 'Backspace', 8], Escape: ['Escape', 'Escape', 27],
    Control_L: ['Control', 'ControlLeft', 17], Control_R: ['Control', 'ControlRight', 17], Shift_L: ['Shift', 'ShiftLeft', 16], Shift_R: ['Shift', 'ShiftRight', 16],
    Alt_L: ['Alt', 'AltLeft', 18], Alt_R: ['Alt', 'AltRight', 18], Super_L: ['Meta', 'MetaLeft', 91], Super_R: ['Meta', 'MetaRight', 92], Menu: ['ContextMenu', 'ContextMenu', 93], Caps_Lock: ['CapsLock', 'CapsLock', 20],
    Delete: ['Delete', 'Delete', 46], Insert: ['Insert', 'Insert', 45], Up: ['ArrowUp', 'ArrowUp', 38], Down: ['ArrowDown', 'ArrowDown', 40],
    Left: ['ArrowLeft', 'ArrowLeft', 37], Right: ['ArrowRight', 'ArrowRight', 39], Home: ['Home', 'Home', 36], End: ['End', 'End', 35],
    Prior: ['PageUp', 'PageUp', 33], Next: ['PageDown', 'PageDown', 34], Page_Up: ['PageUp', 'PageUp', 33], Page_Down: ['PageDown', 'PageDown', 34],
    KP_Enter: ['Enter', 'NumpadEnter', 13], KP_Add: ['+', 'NumpadAdd', 107], KP_Subtract: ['-', 'NumpadSubtract', 109], KP_Multiply: ['*', 'NumpadMultiply', 106], KP_Divide: ['/', 'NumpadDivide', 111], KP_Decimal: ['.', 'NumpadDecimal', 110] };
  let item = specials[chord.key], isKeypad = chord.key.startsWith('KP_');
  if (/^F([1-9]|1[0-9]|2[0-4])$/.test(chord.key)) item = [chord.key, chord.key, 111 + Number(chord.key.slice(1))];
  if (/^KP_[0-9]$/.test(chord.key)) item = [chord.key.at(-1), `Numpad${chord.key.at(-1)}`, 96 + Number(chord.key.at(-1))];
  if (!item) {
    let key = ({ space: ' ', plus: '+', minus: '-', equal: '=', comma: ',', period: '.', slash: '/', backslash: '\\', semicolon: ';', apostrophe: "'", bracketleft: '[', bracketright: ']', grave: '`' })[chord.key] ?? chord.key;
    requireThat([...key].length === 1, 'unsupported-key', `Unsupported browser key ${chord.key}; use typeText for text.`);
    if (modifiers & 8) key = key.toUpperCase();
    const punctuation = { ' ': ['Space', 32], '+': ['Equal', 187], '=': ['Equal', 187], '-': ['Minus', 189], ',': ['Comma', 188], '.': ['Period', 190], '/': ['Slash', 191], '\\': ['Backslash', 220], ';': ['Semicolon', 186], "'": ['Quote', 222], '[': ['BracketLeft', 219], ']': ['BracketRight', 221], '`': ['Backquote', 192] };
    const info = /[a-z]/i.test(key) ? [`Key${key.toUpperCase()}`, key.toUpperCase().charCodeAt(0)] : /[0-9]/.test(key) ? [`Digit${key}`, key.charCodeAt(0)] : punctuation[key] ?? ['', 0];
    item = [key, ...info];
  }
  const [key, code, windowsVirtualKeyCode] = item;
  const typed = !(modifiers & 7) ? (key === 'Enter' ? '\r' : [...key].length === 1 ? key : '') : '';
  return { key, code, windowsVirtualKeyCode, nativeVirtualKeyCode: windowsVirtualKeyCode, modifiers, isKeypad, ...(isKeypad ? { location: 3 } : {}), ...(typed ? { text: typed, unmodifiedText: typed } : {}) };
}

export class BrowserTarget {
  constructor(browser, targetId) {
    this.browser = browser; this.providerTabId = targetId; this.id = `${browser.browserId}:${targetId}`;
    this.ax = new AXState(); this.queue = new SerialQueue(); this.childSessions = new Set(); this.closed = false; this.image = null;
  }
  run(fn) { return this.queue.run(async () => { requireThat(!this.closed, 'tab-closed', 'This tab was closed. Acquire another tab.'); await this.attach(); return fn(); }); }
  async attach() {
    if (this.sessionId && !this.browser.connection?.closed) return;
    const connection = await this.browser.connect();
    this.sessionId = (await connection.call('Target.attachToTarget', { targetId: this.providerTabId, flatten: true })).sessionId;
    connection.on('event', event => {
      if (event.method === 'Target.targetDestroyed' && event.params.targetId === this.providerTabId) { this.closed = true; this.ax.invalidate(); }
      if (event.sessionId !== this.sessionId) return;
      if (event.method === 'Page.frameNavigated' && !event.params.frame.parentId) this.ax.reset();
      if (event.method === 'DOM.documentUpdated') this.ax.invalidate();
      if (event.method === 'Target.attachedToTarget' && event.params.targetInfo.type === 'iframe') this.childSessions.add(event.params.sessionId);
      if (event.method === 'Target.detachedFromTarget') this.childSessions.delete(event.params.sessionId);
    });
    await Promise.all([this.call('Page.enable'), this.call('Runtime.enable'), this.call('DOM.enable'), this.call('Accessibility.enable'),
      this.call('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true })]);
  }
  call(method, params = {}, sessionId = this.sessionId) { return this.browser.connection.call(method, params, sessionId); }
  async evaluate(fn, args = [], sessionId = this.sessionId) {
    return checkResult(await this.call('Runtime.evaluate', { expression: `(${fn.toString()})(...${JSON.stringify(args)})`, awaitPromise: true, returnByValue: true }, sessionId));
  }
  async settle() {
    // One renderer-side wait: no model polling, and no arbitrary sleep before observation.
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        await this.evaluate(() => new Promise(resolve => {
          let quiet, finished = false;
          const end = () => { if (finished) return; finished = true; observer.disconnect(); clearTimeout(quiet); clearTimeout(limit); resolve(); };
          const changed = () => { clearTimeout(quiet); quiet = setTimeout(() => { if (document.readyState !== 'loading') end(); else changed(); }, 120); };
          const observer = new MutationObserver(changed); observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
          const limit = setTimeout(end, 2000); changed();
        })); return;
      } catch (error) { if (attempt === 2 || !/context|navigat|Cannot find/i.test(error.message)) throw error; }
    }
  }
  async snapshot(opts = {}) {
    const nodes = [], sessions = [this.sessionId, ...this.childSessions]; let truncated = false;
    for (const sid of sessions) {
      let tree = [];
      try {
        const { frameTree } = await this.call('Page.getFrameTree', {}, sid), stack = [frameTree];
        while (stack.length) {
          const frame = stack.shift(); stack.push(...(frame.childFrames ?? []));
          try { tree.push(...(await this.call('Accessibility.getFullAXTree', { frameId: frame.frame.id }, sid)).nodes); }
          catch (error) { if (frame === frameTree) throw error; /* OOPIF is read through its own session. */ }
        }
      }
      catch (error) { if (sid === this.sessionId) throw error; continue; }
      const byId = new Map(tree.map(n => [n.nodeId, n])), depths = new Map();
      const depth = n => {
        if (depths.has(n.nodeId)) return depths.get(n.nodeId);
        const d = n.parentId && byId.has(n.parentId) ? Math.min(40, depth(byId.get(n.parentId)) + (byId.get(n.parentId).ignored ? 0 : 1)) : 0;
        depths.set(n.nodeId, d); return d;
      };
      const ordered = [], visited = new Set();
      const visit = node => { if (visited.has(node.nodeId)) return; visited.add(node.nodeId); ordered.push(node); for (const id of node.childIds ?? []) if (byId.has(id)) visit(byId.get(id)); };
      for (const node of tree) if (!node.parentId || !byId.has(node.parentId)) visit(node);
      for (const node of tree) visit(node);
      for (const node of ordered) {
        if (nodes.length >= 4000) { truncated = true; break; }
        if (node.ignored) continue;
        const properties = Object.fromEntries((node.properties ?? []).map(p => [p.name, p.value?.value]));
        const role = node.role?.value ?? 'element';
        if (['InlineTextBox', 'generic', 'none'].includes(role) && !node.name?.value && !node.value?.value) continue;
        const actions = properties.expanded !== undefined ? [properties.expanded ? 'Collapse' : 'Expand'] : [];
        const states = Object.entries(properties).filter(([key, value]) => ['focused', 'disabled', 'checked', 'selected', 'expanded', 'required', 'readonly', 'multiline', 'editable'].includes(key) && value !== false).map(([key, value]) => value === true ? key : `${key}=${value}`);
        nodes.push({ key: `${sid}:${node.backendDOMNodeId ?? node.nodeId}`, role, name: String(node.name?.value ?? '').slice(0, 4096),
          value: properties.protected ? '<protected>' : node.value?.value === undefined ? undefined : String(node.value.value).slice(0, 4096),
          depth: depth(node), states, actions, backendNodeId: node.backendDOMNodeId, sessionId: sid });
      }
    }
    const info = await this.browser.tabInfo(this.providerTabId);
    return this.ax.update(nodes, { ...opts, truncated, header: `Tab ${this.id} · ${JSON.stringify(info.title)} · ${info.url}` });
  }
  async screenshot() {
    const metrics = await this.call('Page.getLayoutMetrics');
    const viewport = metrics.cssVisualViewport ?? metrics.visualViewport;
    const reply = await this.call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    const bytes = Buffer.from(reply.data, 'base64');
    requireThat(bytes.length <= 24 * 1024 * 1024, 'image-too-large', 'Screenshot exceeded its size limit.');
    this.image = { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20), coordinateWidth: viewport.clientWidth, coordinateHeight: viewport.clientHeight };
    return new Uint8Array(bytes);
  }
  getAXState(opts = {}) {
    observationOptions(opts, true);
    return this.run(async () => { await this.settle(); const state = await this.snapshot(opts); if (opts.emit !== false) this.browser.emitter.write(state); return state; });
  }
  getScreenshot(opts = {}) {
    observationOptions(opts);
    return this.run(async () => { await this.settle(); const bytes = await this.screenshot(); this.ax.invalidate(); if (opts.emit !== false) this.browser.emitter.emitImage({ bytes, mimeType: 'image/png' }); return bytes; });
  }
  getAXStateAndScreenshot(opts = {}) {
    observationOptions(opts, true);
    return this.run(async () => {
      await this.settle(); const state = await this.snapshot(opts), screenshot = await this.screenshot();
      if (opts.emit !== false) { this.browser.emitter.write(state); this.browser.emitter.emitImage({ bytes: screenshot, mimeType: 'image/png' }); }
      return { state, screenshot };
    });
  }
  async withElement(index, operation, args = []) {
    const node = this.ax.get(index); requireThat(node.backendNodeId, 'unsupported-action', 'This accessibility node has no DOM element. Choose its interactive parent.');
    let objectId;
    try {
      objectId = (await this.call('DOM.resolveNode', { backendNodeId: node.backendNodeId }, node.sessionId)).object.objectId;
      const result = await this.call('Runtime.callFunctionOn', { objectId, functionDeclaration: elementAction.toString(), arguments: [{ value: operation }, { value: args }], returnByValue: true, awaitPromise: true }, node.sessionId);
      return checkResult(result);
    } catch (error) {
      const known = /\b(stale-element|element-not-visible|unsupported-action|invalid-value|ambiguous-text|text-not-found)\b/.exec(error.message)?.[1];
      if (known) throw new CuaError(known, error.message);
      if (/Could not find|No node|Cannot find object/.test(error.message)) throw new CuaError('stale-element', 'The element disappeared; get fresh accessibility state.');
      throw error;
    } finally { if (objectId) await this.call('Runtime.releaseObject', { objectId }, node.sessionId).catch(() => {}); }
  }
  async coordinate(target) {
    if (typeof target === 'number') {
      const node = this.ax.get(target); await this.withElement(target, 'point');
      // Quads account for transforms in this renderer's viewport. OOPIF input
      // must use the same session, because its coordinates are frame-local.
      const { quads } = await this.call('DOM.getContentQuads', { backendNodeId: node.backendNodeId }, node.sessionId);
      requireThat(quads?.length, 'element-not-visible', 'The element has no visible content quad.');
      const q = quads[0]; return [q.filter((_, i) => !(i % 2)).reduce((a, b) => a + b) / 4, q.filter((_, i) => i % 2).reduce((a, b) => a + b) / 4];
    }
    const [x, y] = point(target);
    return this.image ? [x * this.image.coordinateWidth / this.image.width, y * this.image.coordinateHeight / this.image.height] : [x, y];
  }
  async clickAt(target, opts) {
    const [x, y] = await this.coordinate(target), { mouseButton: button, clickCount } = opts;
    const session = typeof target === 'number' ? this.ax.get(target).sessionId : this.sessionId;
    await this.call('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y }, session);
    for (let count = 1; count <= clickCount; count++) {
      try { await this.call('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button, clickCount: count }, session); }
      finally { await this.call('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button, clickCount: count }, session); }
    }
  }
  click(target, opts = {}) { opts = clickOptions(opts); return this.run(() => this.clickAt(target, opts)); }
  drag(from, to) {
    point(from); point(to);
    return this.run(async () => {
      const [x0, y0] = await this.coordinate(from), [x1, y1] = await this.coordinate(to);
      await this.call('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x0, y: y0 });
      try {
        await this.call('Input.dispatchMouseEvent', { type: 'mousePressed', button: 'left', buttons: 1, clickCount: 1, x: x0, y: y0 });
        for (let i = 1; i <= 8; i++) await this.call('Input.dispatchMouseEvent', { type: 'mouseMoved', button: 'left', buttons: 1, x: x0 + (x1 - x0) * i / 8, y: y0 + (y1 - y0) * i / 8 });
      } finally { await this.call('Input.dispatchMouseEvent', { type: 'mouseReleased', button: 'left', buttons: 0, clickCount: 1, x: x1, y: y1 }); }
    });
  }
  pressKey(value) {
    const event = keyEvent(parseKey(value));
    return this.run(async () => {
      try { await this.call('Input.dispatchKeyEvent', { type: event.text ? 'keyDown' : 'rawKeyDown', ...event }); }
      finally { const { text, unmodifiedText, ...released } = event; await this.call('Input.dispatchKeyEvent', { type: 'keyUp', ...released }); }
    });
  }
  typeText(value) { text(value); return this.run(async () => { if (value) await this.call('Input.insertText', { text: value }); }); }
  paste(value, opts = {}) {
    text(value); options(opts, ['format']); const format = opts.format ?? 'text'; requireThat(['text', 'md', 'html'].includes(format), 'invalid-format', 'Use text, md or html.');
    return this.run(async () => {
      if (format !== 'html') return this.call('Input.insertText', { text: value }).then(() => {});
      await this.evaluate(html => {
        const target = document.activeElement;
        if (!target?.isContentEditable) throw new Error('HTML paste needs a focused rich-text editor.');
        const clipboardData = new DataTransfer(); clipboardData.setData('text/html', html);
        if (target.dispatchEvent(new ClipboardEvent('paste', { clipboardData, bubbles: true, cancelable: true })) && !document.execCommand('insertHTML', false, html)) throw new Error('The editor rejected formatted paste.');
      }, [value]);
    });
  }
  scroll(target, dir, count = 1) {
    dir = direction(dir); count = pages(count);
    return this.run(async () => {
      const [x, y] = await this.coordinate(target), metrics = await this.call('Page.getLayoutMetrics'), view = metrics.cssVisualViewport ?? metrics.visualViewport;
      const vertical = dir === 'up' || dir === 'down', delta = .8 * count * (vertical ? view.clientHeight : view.clientWidth) * (dir === 'up' || dir === 'left' ? -1 : 1);
      await this.call('Input.dispatchMouseEvent', { type: 'mouseWheel', x, y, deltaX: vertical ? 0 : delta, deltaY: vertical ? delta : 0 }, typeof target === 'number' ? this.ax.get(target).sessionId : this.sessionId);
    });
  }
  setValue(index, value) { text(value); return this.run(() => this.withElement(index, 'set-value', [value])); }
  selectText(index, value, opts = {}) {
    text(value); requireThat(value.length > 0, 'invalid-selection', 'Select nonempty text.'); opts = selectionOptions(opts);
    return this.run(() => this.withElement(index, 'select-text', [value, opts]));
  }
  performSecondaryAction(index, action) {
    text(action, 'action', 100);
    return this.run(async () => { const node = this.ax.get(index); requireThat(node.actions.includes(action), 'unsupported-action', 'Use a secondary action exposed in this tree.'); await this.clickAt(index, { mouseButton: 'left', clickCount: 1 }); });
  }
  goto(url) {
    url = navigationURL(url);
    return this.run(async () => {
      const reply = await this.call('Page.navigate', { url });
      requireThat(!reply.errorText, 'navigation-failed', reply.errorText); this.ax.reset(); await this.settle();
    });
  }
  back() { return this.history(-1); }
  forward() { return this.history(1); }
  history(offset) {
    return this.run(async () => { const history = await this.call('Page.getNavigationHistory'), entry = history.entries[history.currentIndex + offset]; if (entry) { await this.call('Page.navigateToHistoryEntry', { entryId: entry.id }); this.ax.reset(); await this.settle(); } });
  }
  reload() { return this.run(async () => { await this.call('Page.reload'); this.ax.reset(); await this.settle(); }); }
  close() { return this.run(async () => { await this.browser.connection.call('Target.closeTarget', { targetId: this.providerTabId }); this.closed = true; this.ax.invalidate(); this.browser.marks.delete(this.providerTabId); }); }
  markDeliverable() { return this.run(async () => { this.browser.marks.set(this.providerTabId, 'deliverable'); }); }
  markHandoff() { return this.run(async () => { this.browser.marks.set(this.providerTabId, 'handoff'); }); }
}
export function navigationURL(value) {
  text(value, 'url', 16384); let url;
  try { url = new URL(value); } catch { throw new CuaError('invalid-url', 'Use an absolute URL.'); }
  requireThat(['http:', 'https:', 'file:', 'about:', 'data:'].includes(url.protocol), 'unsupported-url', 'Use an http, https, file, about or data URL.');
  return url.href;
}
