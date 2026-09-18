import assert from 'node:assert/strict';
import { desktopMethods } from '../sdk/computer-use/desktop.mjs';

// An unrelated host advertises a different layout language and 100 workspaces.
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
await desktop.switchWorkspace(null, 42);
assert.deepEqual(calls.at(-1), {
  op: 'navigate', request: { action: 'workspace', group: null, workspace: 42, revision: 2 },
});
console.log('PASS: JavaScript forwards host-defined layout and workspace 42; incompatible placement helpers send no mutation.');
