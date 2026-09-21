import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createCua } from '../sdk/computer-use/index.mjs';

export async function exerciseDesktop(cua, directory, mark, until, id) {
  const win = state => state.windows.find(w => w.id === id);
  const observe = () => cua.ataxia.getWorld({ emit: false });
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

  // Camera controls explicitly target either monitor, even one without a human seat.
  await cua.ataxia.windowAction(id, 'minimize');
  state = await observe();
  const firstOutput = state.outputs[0], secondOutput = state.outputs[1];
  const frameBefore = state.outputs;
  await assert.rejects(cua.ataxia.frameWindow(secondOutput.id, id), error => error.code === 'invalid-navigation');
  assert.deepEqual((await observe()).outputs, frameBefore, 'Minimized windows cannot be revealed by a camera command');
  await cua.ataxia.windowAction(id, 'restore');
  const positions = (await observe()).windows.map(w => [w.id, w.geometry]);
  result = await cua.ataxia.setViewport(secondOutput.id, { x: -4200, y: 1800, zoom: .5, rotation: .3 });
  assert.deepEqual(result.desktop.outputs.find(o => o.id === secondOutput.id).camera, [-4200, 1800, .5, .3]);
  assert.deepEqual(result.desktop.outputs.find(o => o.id === firstOutput.id), firstOutput);
  assert.deepEqual(result.desktop.windows.map(w => [w.id, w.geometry]), positions);
  result = await cua.ataxia.panViewport(secondOutput.id, { dx: 75, dy: -90 });
  assert.deepEqual(result.desktop.outputs.find(o => o.id === secondOutput.id).camera, [-4125, 1710, .5, .3]);
  const beforeBad = result.desktop.outputs;
  await assert.rejects(cua.ataxia.setViewport(secondOutput.id, { zoom: 0 }), error => error.code === 'invalid-navigation');
  await assert.rejects(cua.ataxia.panViewport(999999, { dx: 1, dy: 1 }), error => error.code === 'invalid-output');
  assert.deepEqual((await observe()).outputs, beforeBad);
  const staleCamera = (await observe()).revision;
  await cua.ataxia.frameRegion(secondOutput.id, { x: -700, y: 900, width: 600, height: 400 }, { rotation: Math.PI / 3, padding: 24 });
  await assert.rejects(cua.ataxia.panViewport(secondOutput.id, { dx: 1, dy: 0 }, { revision: staleCamera }), error => error.code === 'desktop-changed');
  await observe();
  // Membership changes remain layout operations, not camera navigation.
  await cua.ataxia.moveWindow(id, { workspace: 1 });
  await until(async () => win(await observe()).available);
  result = await cua.ataxia.frameWindow(secondOutput.id, id, { rotation: 0 });
  assert.equal(result.desktop.groups.find(g => g.id === group).workspace, 1);
  assert.deepEqual(result.desktop.outputs.find(o => o.id === firstOutput.id), firstOutput);
  result = await cua.ataxia.windowAction(id, 'minimize'); assert.equal(win(result.desktop).minimized, true);
  assert.equal(win(result.desktop).available, false);
  assert.equal((await cua.ataxia.listWindows({ emit: false })).find(w => w.id === id).available, false);
  await assert.rejects(cua.ataxia.getWindow(id), error => error.code === 'window-unavailable');
  await assert.rejects(cua.getApp('ataxia.cua-test'), error => error.code === 'window-unavailable');
  result = await cua.ataxia.windowAction(id, 'restore'); assert.equal(win(result.desktop).minimized, false);
  result = await cua.ataxia.windowAction(id, 'maximize'); assert.equal(win(result.desktop).fullscreen, true);
  result = await cua.ataxia.windowAction(id, 'restore'); assert.equal(win(result.desktop).fullscreen, false);
  result = await cua.ataxia.windowAction(id, 'fullscreen'); assert.equal(win(result.desktop).fullscreen, true);
  await cua.ataxia.windowAction(id, 'restore');
  result = await cua.ataxia.frameWindow(secondOutput.id, id);
  assert.equal(result.desktop.outputs.find(o => o.id === secondOutput.id).group, null);
  console.log('PASS: World layouts and controls, explicit per-output pan/zoom/rotation/framing, unchanged other camera and window placement, hidden-window rejection, revisions and Undo.');
}
