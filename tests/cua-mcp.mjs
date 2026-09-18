import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const cli = fileURLToPath(new URL('../sdk/computer-use/cli.mjs', import.meta.url));
const runtime = await fs.mkdtemp(path.join(os.tmpdir(), 'ataxia-cua-mcp-test-'));
const env = { ...process.env, XDG_RUNTIME_DIR: runtime }, session = 'mcp-test';
let server;
function connect() {
  const child = spawn(process.execPath, [cli, '--stdio', '--session', session], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  const pending = new Map(); let next = 1, diagnostic = '';
  child.stderr.on('data', bytes => { diagnostic += bytes; });
  createInterface({ input: child.stdout }).on('line', line => {
    const reply = JSON.parse(line), call = pending.get(reply.id); if (!call) return;
    pending.delete(reply.id); clearTimeout(call.timer); call.resolve(reply);
  });
  const send = value => child.stdin.write(JSON.stringify(value) + '\n');
  return {
    child, send,
    call(method, params) { const id = next++; return new Promise((resolve, reject) => { const timer = setTimeout(() => reject(Error(`MCP timeout: ${method} ${diagnostic}`)), 12_000); pending.set(id, { resolve, timer }); send({ jsonrpc: '2.0', id, method, params }); }); },
    async close() { child.stdin.end(); await new Promise(resolve => child.once('exit', resolve)); assert.equal(child.exitCode, 0, diagnostic); },
  };
}
try {
  server = connect();
  let reply = await server.call('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'ataxia-test', version: '1' } });
  assert.equal(reply.result.protocolVersion, '2025-11-25'); server.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
  reply = await server.call('tools/list', {}); assert.equal(reply.result.tools[0].name, 'cua_repl');
  reply = await server.call('tools/call', { name: 'cua_repl', arguments: { code: 'var answer = 41; nodeRepl.write(++answer);' } }); assert.equal(reply.result.content[0].text, '42');
  await server.close();
  server = connect(); await server.call('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'ataxia-test', version: '1' } });
  reply = await server.call('tools/call', { name: 'cua_repl', arguments: { code: 'nodeRepl.write(answer);' } }); assert.equal(reply.result.content[0].text, '42');
  // Cancel while code is running: the reader must still process notifications.
  server.send({ jsonrpc: '2.0', id: 'cancel-me', method: 'tools/call', params: { name: 'cua_repl', arguments: { code: 'while(true) {}', timeout_ms: 60000 } } });
  await new Promise(resolve => setTimeout(resolve, 250));
  server.send({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: 'cancel-me' } });
  reply = await server.call('tools/call', { name: 'cua_repl', arguments: { code: 'nodeRepl.write(typeof answer);' } }); assert.equal(reply.result.content[0].text, 'undefined');
  reply = await server.call('tools/call', { name: 'cua_repl', arguments: { code: 'nodeRepl.emitImage(Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9XcAAAAASUVORK5CYII=", "base64"));' } });
  assert.equal(reply.result.content[0].type, 'image'); assert.equal(reply.result.content[0].mimeType, 'image/png');
  const stat = await fs.stat(path.join(runtime, 'ataxia-cua', `${session}.sock`)); assert.equal(stat.mode & 0o777, 0o600);
  await server.close(); server = null;
  console.log('PASS: MCP negotiation, discovery, persistent state across client reconnect, cancellation, image output, and private socket permissions.');
} finally {
  if (server) server.child.kill();
  const stop = spawn(process.execPath, [cli, '--session', session, '--stop'], { env, stdio: 'ignore' });
  await new Promise(resolve => stop.once('exit', resolve));
  await fs.rm(runtime, { recursive: true, force: true });
}
