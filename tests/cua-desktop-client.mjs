import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createCua } from '../sdk/computer-use/index.mjs';

export async function exerciseDesktop(cua, directory, mark, until, id) {
  const win = state => state.windows.find(w => w.id === id);
  const observe = () => cua.ataxia.getDesktop({ emit: false });
  let state = await observe();
  assert(state.capabilities.layout); assert(state.capabilities.navigation);
  assert.equal(state.capabilities['native-shortcuts'], false);
  assert(state['layout-schema']); assert(win(state));
  const originalGroups = state.groups.map(g => g.id);
  let result = await cua.ataxia.arrange([
    { op: 'create-group', ref: 'test', name: 'CUA desktop test', policy: 'niri' },
    { op: 'place-window', window: id, group: 'test', workspace: 2 },
  ]);
  const group = win(result.desktop).group;
  assert(!originalGroups.includes(group)); assert.equal(win(result.desktop).workspace, 2);
  result = await cua.ataxia.setFloating(id, true); assert.equal(win(result.desktop).floating, true);
  result = await cua.ataxia.moveWindow(id, { workspace: 3, width: 500, height: 400 });
  assert.equal(win(result.desktop).workspace, 3); assert.equal(win(result.desktop).group, group);
  const undo = result.undo;
  result = await cua.ataxia.undoLayout(undo); assert.equal(win(result.desktop).workspace, 2);
  await assert.rejects(cua.ataxia.undoLayout(undo), error => error.code === 'undo-unavailable');
  result = await cua.ataxia.setFloating(id, false); assert.equal(win(result.desktop).floating, false);

  // An intervening change invalidates a preview; no automatic rebase/replay.
  const stale = await cua.ataxia.previewLayout([{ op: 'place-window', window: id, group, workspace: 4 }]);
  await cua.ataxia.arrange([{ op: 'configure-group', group, name: 'Changed after preview' }]);
  await assert.rejects(cua.ataxia.applyLayout(stale.plan), error => error.code === 'desktop-changed');
  assert.equal(win(await observe()).workspace, 2);

  // Plans and Undo are session-owned. Explicit window controls clear prior plans.
  const privatePlan = await cua.ataxia.previewLayout([{ op: 'place-window', window: id, group, workspace: 4 }]);
  const other = createCua({ socket: path.join(directory, 'computer-use.sock'), name: 'Other fixture', purpose: 'Verify session ownership', browsers: [] });
  try {
    await other.ataxia.getDesktop({ emit: false });
    await assert.rejects(other.ataxia.applyLayout(privatePlan.plan), error => error.code === 'plan-expired');
  } finally { await other[Symbol.asyncDispose](); }

  // Validate the whole plan before applying any operation.
  const before = await observe();
  await assert.rejects(cua.ataxia.arrange([
    { op: 'configure-group', group, name: 'Must never be applied' },
    { op: 'place-window', window: -1, group },
  ]));
  assert.deepEqual((await observe()).groups, before.groups);
  await assert.rejects(cua.ataxia.arrange([{ op: 'place-window', window: id, group: null, workspace: 2 }]), error => error.code === 'invalid-layout');
  await assert.rejects(cua.ataxia.arrange([{ op: 'configure-group', group, name: { code: 'not data' } }]), error => error.code === 'invalid-layout');

  // The fixture raises after a real placement to exercise transaction rollback.
  await mark('fail-layout');
  await until(async () => fs.stat(path.join(directory, 'fail-layout-ready')).then(() => true, () => false));
  await assert.rejects(cua.ataxia.moveWindow(id, { workspace: 5 }), error => /Injected layout failure/.test(error.message));
  assert.equal(win(await observe()).workspace, 2);

  result = await cua.ataxia.switchWorkspace(group, 2);
  assert.equal(result.desktop.outputs.find(o => o.id === result.desktop.output).group, group);
  assert.equal(result.desktop.groups.find(g => g.id === group).workspace, 2);
  result = await cua.ataxia.windowAction(id, 'minimize'); assert.equal(win(result.desktop).minimized, true);
  result = await cua.ataxia.windowAction(id, 'restore'); assert.equal(win(result.desktop).minimized, false);
  result = await cua.ataxia.windowAction(id, 'maximize'); assert.equal(win(result.desktop).fullscreen, true);
  result = await cua.ataxia.windowAction(id, 'restore'); assert.equal(win(result.desktop).fullscreen, false);
  result = await cua.ataxia.windowAction(id, 'fullscreen'); assert.equal(win(result.desktop).fullscreen, true);
  await cua.ataxia.windowAction(id, 'restore');
  result = await cua.ataxia.overview();
  assert.equal(result.desktop.outputs.find(o => o.id === result.desktop.output).group, null);

  // Keep the target visible for later application observations.
  await cua.ataxia.switchWorkspace(group, 2);
  console.log('PASS: Metaworld desktop snapshots, group creation, workspace movement, floating/tiling, revision conflicts, session-owned plans, rollback, Undo, navigation and window controls.');
}
