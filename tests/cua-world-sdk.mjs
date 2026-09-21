import assert from 'node:assert/strict';
import { NativeProvider } from '../sdk/computer-use/native.mjs';

// Exercise target selection and coordinate guards independently of AX support.
const windows = [
  { id: 10, 'app-id': 'editor', title: 'First document', available: true, selected: true },
  { id: 20, 'app-id': 'editor', title: 'Other document', available: true, 'on-output': false },
  { id: 30, 'app-id': 'minimized', title: 'Keep minimized', available: false },
].map(w => ({ ...w, width: 600, height: 400, 'origin-x': 0, 'origin-y': 0 }));
const calls = [], emitted = [];
let mode = 'desktop';
const transport = {
  queue: { run: fn => fn() }, token: 'fixture', socket: 'fixture',
  async read(op, fields) {
    assert.equal(op, 'observe'); assert.equal(fields.mode, 'window');
    calls.push({ op, fields });
    return { windows: structuredClone(windows), applications: [] };
  },
  async batch(actions) {
    calls.push({ actions });
    const select = actions[0];
    assert.equal(select.op, 'view'); assert.equal(select.mode, 'window');
    mode = select.mode;
    return { windows: structuredClone(windows) };
  },
};
const provider = new NativeProvider({ transport, helper: { async call(op) {
  if (op === 'desktop-info') return [];
  assert.equal(op, 'snapshot'); return { nodes: [] };
} } }, { write: value => emitted.push(value) });

await assert.rejects(provider.getApp('editor'), error => error.code === 'ambiguous-window' && error.details.windows.length === 2);
assert(!calls.some(call => call.actions), 'Ambiguous names must not select or launch a window');
await assert.rejects(provider.getApp('minimized'), error => error.code === 'window-unavailable');
assert(!calls.some(call => call.actions), 'An existing unavailable app must not be relaunched');
const app = await provider.getWindow(20);
assert.equal(mode, 'window'); assert.equal(app.windowId, 20);
assert.deepEqual((await provider.listApps({ emit: false })).find(a => a.id === 'editor').windowIds, [10, 20]);
app.image = { width: 300, height: 200, 'coordinate-width': 600, 'coordinate-height': 400, 'origin-x': 0, 'origin-y': 0 };
await app.click([25, 30]);
assert(calls.at(-1).actions.some(a => a.op === 'move' && a.x === 50 && a.y === 60));
windows[1].width = 800;
const beforeResize = calls.length;
await assert.rejects(app.click([25, 30]), error => error.code === 'stale-screenshot');
assert(!calls.slice(beforeResize).some(call => call.actions?.some(a => a.op === 'button')));
await assert.rejects(app._imageBytes({ path: '/unused', view: 'desktop', window: null }), error => error.code === 'capture-target-mismatch');
console.log('PASS: explicit multi-window selection, unavailable app discovery without launch, window view selection and stale screenshot rejection before input.');
