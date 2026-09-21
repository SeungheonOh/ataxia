import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { createCua } from '../sdk/computer-use/index.mjs';
import { sleep } from '../sdk/computer-use/common.mjs';
import { exerciseDesktop } from './cua-desktop-client.mjs';
import { request } from '../sdk/computer-use/transport.mjs';
const directory = process.argv[2], emitted = [];
let nativeConnection;
const cua = createCua({ socket: path.join(directory, 'computer-use.sock'), name: 'CUA fixture', purpose: 'Test this disposable GTK application', browsers: [],
  _onNativeSession: value => { nativeConnection = value; },
  nodeRepl: { write: value => emitted.push(value), emitImage: value => emitted.push(value) } });
const mark = name => fs.writeFile(path.join(directory, name), '');
async function until(fn) { for (let i = 0; i < 100; i++) { const value = await fn(); if (value) return value; await sleep(30); } throw Error('fixture deadline expired'); }
function index(state, role, name) {
  const line = state.split('\n').find(line => line.includes(role) && line.includes(JSON.stringify(name)));
  assert(line, `Missing ${role} ${name} in\n${state}`); return Number(/\[(\d+)\]/.exec(line)[1]);
}
try {
  const caps = await cua.ataxia.capabilities(); assert.equal(caps.native.desktop.layout, true); assert.equal(caps.native.desktop.navigation, true);
  assert.equal((await cua.ataxia.connect()).state, 'active');
  await cua.listApps({ emit: false });
  await mark('launch');
  await until(async () => fs.stat(path.join(directory, 'offscreen-ready')).then(() => true, () => false));
  const windows = await until(async () => { const w = await cua.ataxia.listWindows({ emit: false }); return w.length ? w : false; });
  assert(windows[0].pid > 0);
  assert.equal(windows[0]['on-output'], false); assert.equal(windows[0].available, true);
  assert.equal(windows[0]['coordinate-space'], 'window-local');
  const initialWorld = await cua.ataxia.getWorld({ emit: false });
  assert.equal(initialWorld.outputs.length, 2); assert.equal(initialWorld['coordinate-space'], 'world');
  assert.deepEqual(initialWorld.windows[0]['on-outputs'], []);
  assert(initialWorld.windows[0].geometry[0] < -1000);
  // Window APIs recover their own coordinate space after an explicit viewport view.
  await cua.ataxia.batch([{ op: 'view', mode: 'desktop' }]);
  assert((await cua.ataxia.listWindows({ emit: false })).some(w => w.id === windows[0].id));
  const app = await cua.getApp('ataxia.cua-test');
  assert.equal(app.windowId, windows[0].id); assert.equal((await cua.ataxia.status()).view, 'window');
  const viewportInventory = await request(nativeConnection.socket, { op: 'observe', mode: 'desktop', token: nativeConnection.token });
  assert(!viewportInventory.windows.some(w => w.id === app.windowId));
  assert.equal((await cua.ataxia.status()).view, 'window');
  assert.equal(await cua.ataxia.getWindow(windows[0].id), app);
  const viewport = await cua.ataxia.captureViewport({ emit: false });
  assert.equal(viewport.view, 'desktop'); assert.equal(viewport['coordinate-space'], 'output-local');
  assert.equal(viewport.output, initialWorld.output);
  assert.equal((await cua.ataxia.status()).view, 'window');
  assert.deepEqual((await cua.ataxia.getWorld({ emit: false })).outputs, initialWorld.outputs);
  console.log('PASS: two independent output views, initial offscreen discovery and selection, viewport/window capture separation, unchanged human cameras.');
  let state = await app.getAXState({ disableDiffing: true, emit: false }); console.log(state);
  assert.match(state, /Name/); assert(!state.includes('Accessibility unavailable'));
  const name = index(state, 'text', 'Name');
  await app.setValue(name, 'Codex · λ🙂');
  await app.click(index(state, 'button', 'Apply'));
  state = await app.getAXState({ emit: false }); assert.match(state, /Applied: Codex · λ🙂/);
  assert.match(await app.getAXState({ emit: false }), /No accessibility-tree change/);
  state = await app.getAXState({ disableDiffing: true, emit: false });
  const note = index(state, 'text', 'Notes');
  await app.selectText(note, 'hello', { prefix: 'second ' });
  await app.typeText('world');
  state = await app.getAXState({ emit: false }); assert.match(state, /second world end/);
  state = await app.getAXState({ disableDiffing: true, emit: false });
  await app.setValue(index(state, 'spin button', 'Amount'), '42');
  await app.getAXState({ emit: false });
  state = await app.getAXState({ disableDiffing: true, emit: false });
  const expander = index(state, 'toggle button', 'Details');
  const action = JSON.parse(/actions=(\[[^\]]*\])/.exec(state.split('\n').find(line => line.includes(`[${expander}]`)))[1])[0];
  await app.performSecondaryAction(expander, action); await app.getAXState({ emit: false });
  state = await app.getAXState({ disableDiffing: true, emit: false });
  await app.click(index(state, 'text', 'Name'));
  await app.pressKey('ctrl+a'); await app.paste('Pasted · λ🙂\nsecond line', { format: 'text' });
  state = await app.getAXState({ emit: false }); assert.match(state, /Pasted/);
  const image = await app.getScreenshot({ emit: false }); assert.equal(Buffer.from(image).subarray(1, 4).toString(), 'PNG');
  assert.equal(app.image.view, 'window'); assert.equal(app.image.window, app.windowId);
  assert.equal(app.image['coordinate-space'], 'window-local');
  await fs.writeFile(path.join(directory, 'native.png'), image);
  await assert.rejects(app.click(name), error => error.code === 'stale-element');
  const both = await app.getAXStateAndScreenshot({ emit: false }); assert.match(both.state, /Accessibility tree/); assert(both.screenshot.length > 100);
  // A continuously changing title prevents stability. Acquisition must still
  // provide current AX without replaying any keyboard input.
  await mark('animate');
  await until(async () => /tick/.test((await cua.ataxia.listWindows({ emit: false }))[0].title));
  const beforeAnimation = JSON.parse(await fs.readFile(path.join(directory, 'ui.json'))).keyEvents;
  const updatingApp = await cua.ataxia.getWindow(windows[0].id);
  const updatingState = await updatingApp.getAXState({ emit: false });
  assert.match(updatingState, /Application is updating/);
  assert.equal(JSON.parse(await fs.readFile(path.join(directory, 'ui.json'))).keyEvents, beforeAnimation);
  await fs.unlink(path.join(directory, 'animate'));
  await exerciseDesktop(cua, directory, mark, until, windows[0].id);
  await mark('pause'); await until(async () => (await cua.ataxia.status()).state === 'paused');
  await assert.rejects(app.setValue(name, 'Must not happen'), error => ['session-paused', 'not-active', 'stale-element'].includes(error.code));
  await assert.rejects(cua.listApps({ emit: false }), error => error.code === 'session-paused');
  await assert.rejects(cua.ataxia.getDesktop({ emit: false }), error => error.code === 'session-paused');
  await assert.rejects(cua.ataxia.getWorld({ emit: false }), error => error.code === 'session-paused');
  await assert.rejects(cua.ataxia.captureViewport({ emit: false }), error => error.code === 'session-paused');
  await assert.rejects(cua.ataxia.panViewport(initialWorld.output, { dx: 1, dy: 1 }), error => error.code === 'session-paused');
  await assert.rejects(cua.ataxia.moveWindow(windows[0].id, { workspace: 3 }), error => error.code === 'session-paused');
  assert.equal((await request(nativeConnection.socket, { op: 'desktop', token: nativeConnection.token })).error, 'not-active');
  assert.equal((await request(nativeConnection.socket, { op: 'viewport', action: 'pan', output: initialWorld.output, dx: 1, dy: 1, revision: 1,
    token: nativeConnection.token, sequence: (await cua.ataxia.status()).sequence + 1 })).error, 'not-active');
  assert.equal((await cua.ataxia.connect()).state, 'paused');
  await mark('resume'); await until(async () => (await cua.ataxia.status()).state === 'active');
  await cua.listApps({ emit: false });
  await mark('pause-all'); await until(async () => (await cua.ataxia.status()).state === 'paused');
  await assert.rejects(cua.listApps({ emit: false }), error => error.code === 'session-paused');
  await mark('resume'); await until(async () => (await cua.ataxia.status()).state === 'active');
  await cua.ataxia.getDesktop({ emit: false });
  // Read application content while its widgets are alive; GTK disposal clears text.
  const actual = JSON.parse(await fs.readFile(path.join(directory, 'ui.json')));
  assert.match(actual.name, /Pasted/); assert.equal(actual.amount, 42); assert.equal(actual.expanded, true); assert.match(actual.notes, /second world end/);
  await cua.ataxia.windowAction(windows[0].id, 'close');
  await until(async () => !(await cua.ataxia.getDesktop({ emit: false })).windows.some(w => w.id === windows[0].id));
  await mark('stop'); await until(async () => (await cua.ataxia.status()).state === 'closed');
  await assert.rejects(cua.listApps({ emit: false }), error => error.code === 'session-closed');
  await assert.rejects(cua.ataxia.getDesktop({ emit: false }), error => error.code === 'session-closed');
  assert.equal((await cua.ataxia.connect()).state, 'closed');
  console.log('PASS: real GTK accessibility, stable indices, diffs, Unicode selection/input, values, secondary actions, seat-local paste, captures, automatic activation, pause/resume, pause all and disconnect.', cua.ataxia.metrics());
} finally { await cua[Symbol.asyncDispose](); }
