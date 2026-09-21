import assert from 'node:assert/strict';
import { desktopMethods } from '../sdk/computer-use/desktop.mjs';

// An unrelated host advertises a different layout language and implements explicit output cameras.
let state = {
  revision: 1, windows: [{ id: 42 }],
  capabilities: { layout: true, navigation: true },
  'layout-schema': { properties: { op: { enum: ['position'] } } },
};
const calls = [];
const native = {
  targets: new Map(), run: operation => operation(),
  transport: {
    token: 'fixture',
    async read(op) { assert.equal(op, 'desktop'); return { desktop: structuredClone(state) }; },
    async send(op, request) {
      calls.push({ op, request });
      if (op === 'layout-preview') return { plan: 'p'.repeat(64), revision: state.revision, operations: request.operations };
      state = { ...state, revision: state.revision + 1 };
      return { desktop: structuredClone(state) };
    },
  },
};
const desktop = desktopMethods(native, { write() {} });

await desktop.arrange([{ op: 'position', value: 75 }]);
assert.deepEqual(calls[0], {
  op: 'layout-preview', request: { revision: 1, operations: [{ op: 'position', value: 75 }] },
});
assert.equal(calls[1].op, 'layout-apply');
const beforeUnsupported = calls.length;
await assert.rejects(desktop.moveWindow(42, { x: 10 }), error => error.code === 'unsupported-operation');
await assert.rejects(desktop.setFloating(42, true), error => error.code === 'unsupported-operation');
assert.equal(calls.length, beforeUnsupported);
await desktop.setViewport(7, { x: -4200, zoom: .5 });
assert.deepEqual(calls.at(-1), {
  op: 'viewport', request: { action: 'set', output: 7, x: -4200, zoom: .5, revision: 2 },
});
const image = { width: 320, height: 200 };
native.targets.set(42, { image, ax: { invalidate() { throw Error('Camera moves must preserve window-local AX'); } } });
await desktop.panViewport(8, { dx: -25, dy: 60 });
assert.deepEqual(calls.at(-1).request, { action: 'pan', output: 8, dx: -25, dy: 60, revision: 3 });
assert.equal(native.targets.get(42).image, image);
await desktop.frameWindow(7, 42, { padding: 20 });
assert.deepEqual(calls.at(-1).request, { action: 'frame-window', output: 7, window: 42, padding: 20, revision: 4 });
await desktop.frameRegion(8, { x: -10, y: 50, width: 600, height: 500 }, { rotation: .5 });
const beforeInvalid = calls.length;
await assert.rejects(desktop.setViewport(null, { x: 0 }));
await assert.rejects(desktop.setViewport(7, { zoom: NaN }));
await assert.rejects(desktop.setViewport(7, {}));
await assert.rejects(desktop.frameRegion(7, { width: 100 }));
assert.equal(calls.length, beforeInvalid);
assert.equal(desktop.switchWorkspace, undefined);
console.log('PASS: host-defined layouts, explicit output camera commands, preserved window-local observations, and invalid commands rejected before mutation.');
