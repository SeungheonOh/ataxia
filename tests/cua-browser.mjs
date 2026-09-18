import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import { createCua } from '../sdk/computer-use/index.mjs';
import { findChromium } from '../sdk/computer-use/browser.mjs';
import { CuaRepl } from '../sdk/computer-use/repl.mjs';

const observations = [], images = [], states = {};
const server = http.createServer(async (req, res) => {
  if (req.url === '/state') { let body = ''; for await (const chunk of req) body += chunk; Object.assign(states, JSON.parse(body)); res.end('ok'); return; }
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  if (req.url === '/second') { res.end('<title>Second page</title><h1>Second page loaded</h1>'); return; }
  if (req.url?.startsWith('/frame')) { res.end('<button onclick="this.textContent=\'Frame clicked\'">Frame action</button><label>Frame entry<input oninput="fetch(\'/state\',{method:\'POST\',body:JSON.stringify({frame:this.value})})"></label>'); return; }
  res.end(`<!doctype html><title>CUA fixture</title><style>body{font:16px sans-serif}label{display:block;margin:12px}iframe{display:block;margin:20px;width:450px;height:150px}#rich{border:1px solid;padding:12px}#space{height:1400px}</style>
    <h1>Browser fixture</h1><label>Name<input id="name" value="Initial"></label>
    <label>Notes<textarea id="notes">first hello · λ🙂\nsecond hello end</textarea></label>
    <label>Amount<input type="number" id="amount" value="0"></label>
    <label>Choice<select id="choice"><option value="a">Alpha</option><option value="b">Beta</option></select></label>
    <button id="apply" onclick="status.textContent='Applied: '+nameInput.value">Apply</button><p id="status" role="status">Waiting</p>
    <details><summary>Details</summary><p>Expanded content</p></details>
    <div id="rich" contenteditable="true" role="textbox" aria-label="Rich">Rich initial</div>
    <iframe title="Same origin frame" src="/frame"></iframe>
    <iframe title="Cross origin frame" src="http://127.0.0.1:${server.address().port}/frame-cross"></iframe>
    <div id="space"></div><button onclick="this.textContent='Bottom clicked'">Bottom action</button>
    <script>const nameInput=document.getElementById('name'),status=document.getElementById('status');
    function report(){fetch('/state',{method:'POST',body:JSON.stringify({name:nameInput.value,notes:document.getElementById('notes').value,amount:document.getElementById('amount').value,choice:document.getElementById('choice').value,rich:document.getElementById('rich').innerHTML,scrollY})})}
    document.addEventListener('input',report);document.addEventListener('change',report);addEventListener('scroll',report);</script>`);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://localhost:${server.address().port}/`, executable = await findChromium();
// This launch is exclusively a disposable local fixture on hosts where AppArmor
// blocks downloaded Chromium user namespaces. Production defaults keep sandboxing.
const browsers = [{ id: 'fixture', executable, headless: true, args: ['--no-sandbox', '--disable-background-networking', '--site-per-process'] }];
const cua = createCua({ browsers, socket: '/tmp/ataxia-cua-deliberately-absent.sock', nodeRepl: { write: v => observations.push(v), emitImage: v => images.push(v) } });
function index(state, role, name, occurrence = 0) {
  const line = state.split('\n').filter(line => line.includes(`] ${role}`) && line.includes(JSON.stringify(name)))[occurrence];
  assert(line, `Missing ${role} ${name}:\n${state}`); return Number(/\[(\d+)\]/.exec(line)[1]);
}
let repl;
try {
  const browser = await cua.getBrowser(); assert.equal(observations.length, 1); assert.equal((await cua.listTabs({ emit: false })).length, 0);
  const tab = await cua.createBrowserTab(browser.browserId, url, { visible: false, sessionName: 'fixture' });
  assert.match(observations.at(-1), /Browser fixture/);
  let state = await tab.getAXState({ disableDiffing: true, emit: false });
  const fullBytes = state.length;
  await tab.setValue(index(state, 'textbox', 'Name'), 'Codex λ🙂'); await tab.click(index(state, 'button', 'Apply'));
  state = await tab.getAXState({ emit: false }); assert.match(state, /Applied: Codex λ🙂/); const diffBytes = state.length;
  assert.match(await tab.getAXState({ emit: false }), /No accessibility-tree change/);
  state = await tab.getAXState({ disableDiffing: true, emit: false });
  const notes = index(state, 'textbox', 'Notes');
  await assert.rejects(tab.selectText(notes, 'hello'), e => e.code === 'ambiguous-text');
  await tab.selectText(notes, 'hello', { prefix: 'second ' }); await tab.typeText('world');
  state = await tab.getAXState({ emit: false }); assert.match(state, /second world end/);
  state = await tab.getAXState({ disableDiffing: true, emit: false });
  await tab.setValue(index(state, 'spinbutton', 'Amount'), '42'); await tab.setValue(index(state, 'combobox', 'Choice'), 'b');
  await tab.performSecondaryAction(index(state, 'DisclosureTriangle', 'Details'), 'Expand');
  state = await tab.getAXState({ emit: false }); assert.match(state, /Expanded content/);
  state = await tab.getAXState({ disableDiffing: true, emit: false });
  const rich = index(state, 'textbox', 'Rich'); await tab.click(rich); await tab.pressKey('ctrl+a'); await tab.paste('<b>Bold λ🙂</b><br>second', { format: 'html' });
  state = await tab.getAXState({ emit: false }); assert.match(state, /Bold λ🙂/); assert.match(states.rich, /<b>Bold λ🙂<\/b>/);
  state = await tab.getAXState({ disableDiffing: true, emit: false });
  await tab.click(index(state, 'textbox', 'Name')); await tab.pressKey('ctrl+a'); await tab.paste('**markdown**', { format: 'md' });
  state = await tab.getAXState({ emit: false }); assert.match(state, /\*\*markdown\*\*/);
  state = await tab.getAXState({ disableDiffing: true, emit: false });
  assert.equal(state.split('\n').filter(l => l.includes('] button "Frame action"')).length, 2);
  await tab.click(index(state, 'button', 'Frame action')); state = await tab.getAXState({ emit: false }); assert.match(state, /Frame clicked/);
  state = await tab.getAXState({ disableDiffing: true, emit: false });
  await tab.click(index(state, 'button', 'Frame action')); state = await tab.getAXState({ emit: false }); assert.match(state, /Frame clicked/);
  state = await tab.getAXState({ disableDiffing: true, emit: false });
  assert.equal(state.split('\n').filter(l => l.includes('] button "Frame clicked"')).length, 2, 'Both frame buttons must have changed');
  await tab.setValue(index(state, 'textbox', 'Frame entry', 1), 'Cross frame λ🙂'); await tab.getAXState({ emit: false }); assert.equal(states.frame, 'Cross frame λ🙂');
  const image = await tab.getScreenshot({ emit: false }); assert.equal(Buffer.from(image).subarray(1, 4).toString(), 'PNG'); await fs.writeFile('build/cua-browser.png', image);
  await assert.rejects(tab.click(rich), e => e.code === 'stale-element');
  const both = await tab.getAXStateAndScreenshot({ emit: false }); assert.match(both.state, /Accessibility tree/); assert(both.screenshot.length);
  await tab.scroll([400, 500], 'down'); await tab.getAXState({ emit: false }); assert(states.scrollY > 0);
  await tab.goto(`${url}second`); state = await tab.getAXState({ emit: false }); assert.match(state, /Second page loaded/);
  await tab.back(); assert.match(await tab.getAXState({ emit: false }), /Browser fixture/);
  await tab.forward(); assert.match(await tab.getAXState({ emit: false }), /Second page loaded/);
  await tab.reload(); assert.match(await tab.getAXState({ emit: false }), /Second page loaded/);
  await tab.markDeliverable(); assert.equal(cua.ataxia.tabMarks()[0].mark, 'deliverable'); await tab.markHandoff(); assert.equal(cua.ataxia.tabMarks()[0].mark, 'handoff');
  const inventory = await cua.getState({ emit: false }); assert(inventory.errors?.some(e => e.startsWith('Apps:'))); assert(inventory.browsers[0].tabs.length);
  await assert.rejects(cua.createBrowserTab(browser.browserId, url, { unsupported: true }), e => e.code === 'unsupported-option');
  await assert.rejects(cua.createBrowserTab(browser.browserId, url, { visible: true }), e => e.code === 'unsupported-option');
  await tab.close(); await assert.rejects(tab.getAXState(), e => e.code === 'tab-closed');
  assert.equal(images.length, 0); // emit:false really suppresses images.
  repl = new CuaRepl({ browsers });
  let reply = await repl.evaluate(`var b = await cua.getBrowser(); var t = await cua.createBrowserTab(b.browserId, ${JSON.stringify(url)});`);
  assert(!reply.isError, JSON.stringify(reply)); assert.equal(reply.content.length, 2);
  reply = await repl.evaluate('await t.getAXState({emit:false});'); assert.deepEqual(reply.content, []);
  reply = await repl.evaluate('await t.getAXStateAndScreenshot();'); assert.equal(reply.content.filter(c => c.type === 'text').length, 1); assert.equal(reply.content.filter(c => c.type === 'image').length, 1);
  reply = await repl.evaluate('var count = 41;'); assert.deepEqual(reply.content, []);
  reply = await repl.evaluate('nodeRepl.write(++count);'); assert.equal(reply.content[0].text, '42');
  reply = await repl.evaluate('throw new Error("fixture error");'); assert(reply.isError); assert.match(reply.content[0].text, /fixture error/);
  reply = await repl.evaluate('while (true) {}', { timeout_ms: 200 }); assert(reply.isError); assert.match(reply.content[0].text, /timed out/);
  reply = await repl.evaluate('nodeRepl.write(typeof count)'); assert.equal(reply.content[0].text, 'undefined');
  assert.equal(states.amount, '42'); assert.equal(states.choice, 'b'); assert.match(states.notes, /second world end/);
  console.log(JSON.stringify({ passed: 'real Chromium and persistent REPL', fullStateBytes: fullBytes, changedStateBytes: diffBytes, ...cua.ataxia.metrics() }));
} finally { await repl?.close(); await cua[Symbol.asyncDispose](); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
