export class CuaError extends Error {
  constructor(code, message, details) { super(message); this.name = 'CuaError'; this.code = code; if (details) this.details = details; }
}
export function requireThat(ok, code, message) { if (!ok) throw new CuaError(code, message); }
export function options(value, allowed) {
  requireThat(value && typeof value === 'object' && !Array.isArray(value), 'invalid-options', 'Options must be an object.');
  for (const key of Object.keys(value)) requireThat(allowed.includes(key), 'unsupported-option', `Unsupported option: ${key}`);
  return value;
}
export function text(value, name = 'text', max = 1_000_000) {
  requireThat(typeof value === 'string' && value.length <= max, 'invalid-argument', `${name} must be a string of at most ${max} characters.`);
  return value;
}
export function point(value) {
  requireThat(Array.isArray(value) && value.length === 2 && value.every(n => Number.isFinite(n) && n >= 0), 'invalid-coordinate', 'Use a finite nonnegative [x, y] coordinate.');
  return value;
}
export function button(value = 'left') {
  const b = { l: 'left', r: 'right', m: 'middle', left: 'left', right: 'right', middle: 'middle' }[value];
  requireThat(b, 'invalid-button', 'Use left, right, middle, l, r or m.'); return b;
}
export function direction(value) {
  const d = { u: 'up', d: 'down', l: 'left', r: 'right', up: 'up', down: 'down', left: 'left', right: 'right' }[value];
  requireThat(d, 'invalid-direction', 'Use up, down, left or right.'); return d;
}
export function pages(value = 1) {
  requireThat(Number.isFinite(value) && value > 0 && value <= 100, 'invalid-argument', 'pages must be positive and at most 100.'); return value;
}
export function clickOptions(value = {}) {
  options(value, ['mouseButton', 'clickCount']); const mouseButton = button(value.mouseButton), clickCount = value.clickCount ?? 1;
  requireThat(Number.isInteger(clickCount) && clickCount >= 1 && clickCount <= 3, 'invalid-click-count', 'clickCount must be 1, 2 or 3.');
  return { mouseButton, clickCount };
}
export function selectionOptions(value = {}) {
  options(value, ['prefix', 'suffix', 'selectionType']);
  for (const key of ['prefix', 'suffix']) if (value[key] !== undefined) text(value[key], key);
  const selectionType = value.selectionType ?? 'text';
  requireThat(['text', 'cursor_before', 'cursor_after'].includes(selectionType), 'invalid-selection', 'Use text, cursor_before or cursor_after.');
  return { ...value, selectionType };
}
export function selectionRange(content, needle, opts = {}) {
  text(needle); requireThat(needle.length > 0, 'invalid-selection', 'Select nonempty text.');
  const { prefix, suffix, selectionType } = selectionOptions(opts), matches = [];
  for (let at = content.indexOf(needle); at !== -1; at = content.indexOf(needle, at + 1)) {
    if ((prefix === undefined || content.slice(0, at).endsWith(prefix)) &&
        (suffix === undefined || content.slice(at + needle.length).startsWith(suffix))) matches.push(at);
  }
  requireThat(matches.length === 1, matches.length ? 'ambiguous-text' : 'text-not-found', 'Text must match exactly once; use prefix and suffix to disambiguate.');
  const start = matches[0], end = start + needle.length;
  return selectionType === 'cursor_before' ? [start, start] : selectionType === 'cursor_after' ? [end, end] : [start, end];
}
export function parseKey(value) {
  text(value, 'key', 120);
  const pieces = value.split('+'), key = pieces.pop();
  requireThat(key.length > 0, 'invalid-key', 'Use an XKB/xdotool key name; use plus for the + key.');
  const aliases = { ctrl: 'Control_L', control: 'Control_L', control_l: 'Control_L', shift: 'Shift_L', shift_l: 'Shift_L', alt: 'Alt_L', alt_l: 'Alt_L', super: 'Super_L', super_l: 'Super_L', meta: 'Super_L', cmd: 'Super_L' };
  const modifiers = [...new Set(pieces.map(p => {
    const m = aliases[p.toLowerCase()]; requireThat(m, 'invalid-key', `Unknown key modifier: ${p}`); return m;
  }))];
  return { key: ({ Enter: 'Return', Esc: 'Escape', Backspace: 'BackSpace', Space: 'space', ctrl: 'Control_L', control: 'Control_L', shift: 'Shift_L', alt: 'Alt_L', super: 'Super_L', meta: 'Super_L' })[key] ?? key, modifiers };
}
export class SerialQueue {
  #tail = Promise.resolve();
  run(fn) { const result = this.#tail.then(fn); this.#tail = result.catch(() => {}); return result; }
}
export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
export function observationOptions(value = {}, state = false) {
  options(value, state ? ['emit', 'disableDiffing'] : ['emit']);
  for (const key of Object.keys(value)) requireThat(typeof value[key] === 'boolean', 'invalid-options', `${key} must be a boolean.`);
  return value;
}
export function makeEmitter(nodeRepl = {}) {
  return { write: nodeRepl.write?.bind(nodeRepl) ?? (() => {}), emitImage: nodeRepl.emitImage?.bind(nodeRepl) ?? (() => {}) };
}
