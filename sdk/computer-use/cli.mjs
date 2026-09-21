#!/usr/bin/env node
import net from 'node:net';
import fs from 'node:fs/promises';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline';
import { CuaRepl } from './repl.mjs';
import { toolDescription } from './guidance.mjs';
import { sleep, requireThat } from './common.mjs';

const args = process.argv.slice(2), sessionAt = args.indexOf('--session');
const defaultSession = args.includes('--stdio') ? `codex-${process.env.CODEX_THREAD_ID ?? process.ppid}`.slice(0, 48) : 'default';
const session = sessionAt >= 0 ? args[sessionAt + 1] : (process.env.ATAXIA_CUA_SESSION ?? defaultSession);
requireThat(typeof session === 'string' && /^[a-zA-Z0-9_-]{1,48}$/.test(session), 'invalid-session', 'Use a session name of 1–48 letters, digits, hyphens or underscores.');
const directory = path.join(process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid()}`, 'ataxia-cua');
const socketPath = path.join(directory, `${session}.sock`);
async function privateDirectory() {
  await fs.mkdir(directory, { mode: 0o700, recursive: true });
  const stat = await fs.lstat(directory);
  requireThat(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid() && (stat.mode & 0o077) === 0, 'unsafe-runtime-directory', 'The CUA runtime directory must be owned by you and mode 0700.');
}
async function rpc(message, timeout = 75_000) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath); let data = '', done = false;
    const finish = (error, value) => { if (done) return; done = true; socket.destroy(); error ? reject(error) : resolve(value); };
    socket.setTimeout(timeout, () => finish(Error('REPL connection timed out; do not replay uncertain UI actions.')));
    socket.on('error', e => finish(e)); socket.on('end', () => { if (!done) finish(Error('REPL disconnected before returning a result. Inspect state before retrying.')); });
    socket.on('connect', () => socket.write(JSON.stringify(message) + '\n'));
    socket.on('data', bytes => {
      data += bytes.toString(); if (data.length > 48 * 1024 * 1024) return finish(Error('REPL response exceeds its limit.'));
      if (data.includes('\n')) try { finish(null, JSON.parse(data.split('\n')[0])); } catch (error) { finish(error); }
    });
  });
}
async function ensureDaemon() {
  await privateDirectory();
  try { await rpc({ ping: true }, 1000); return; } catch (error) { if (!['ENOENT', 'ECONNREFUSED'].includes(error.code)) throw error; }
  const lockPath = `${socketPath}.lock`; let lock;
  try { lock = await fs.open(lockPath, 'wx', 0o600); } catch (error) { if (error.code !== 'EEXIST') throw error; }
  if (lock) {
    try {
      await fs.unlink(socketPath).catch(error => { if (error.code !== 'ENOENT') throw error; });
      const log = await fs.open(path.join(directory, `${session}.log`), 'a', 0o600);
      const child = spawn(process.execPath, [fileURLToPath(import.meta.url), '--daemon', '--session', session], { detached: true, stdio: ['ignore', log.fd, log.fd] });
      child.unref(); await log.close();
      child.on('error', () => {});
      for (let i = 0; i < 100; i++) { try { await rpc({ ping: true }, 100); return; } catch { await sleep(50); } }
      throw Error(`Could not start cua_repl. Inspect ${path.join(directory, `${session}.log`)}.`);
    } finally { await lock.close(); await fs.unlink(lockPath).catch(() => {}); }
  }
  for (let i = 0; i < 100; i++) { try { await rpc({ ping: true }, 100); return; } catch { await sleep(50); } }
  throw Error(`Another REPL launch did not finish. Inspect the private session log and lock: ${lockPath}`);
}
async function daemon() {
  await privateDirectory(); process.umask(0o077);
  const repl = new CuaRepl({ socket: process.env.ATAXIA_COMPUTER_USE_SOCKET, name: `Codex (${session.slice(0, 32)})` });
  const server = net.createServer(socket => {
    let buffer = '', handled = false; socket.setTimeout(80_000, () => socket.destroy()); socket.on('error', () => {});
    socket.on('data', async bytes => {
      if (handled) return; buffer += bytes.toString();
      if (buffer.length > 1_100_000) { handled = true; socket.end(JSON.stringify({ isError: true, content: [{ type: 'text', text: 'Request too large.' }] }) + '\n'); return; }
      if (!buffer.includes('\n')) return; handled = true;
      let reply;
      try {
        const request = JSON.parse(buffer.split('\n')[0]);
        if (request.ping) reply = { ready: true, session };
        else if (request.stop) { if (repl.active) await repl.cancel(repl.active.requestId); await repl.close(); reply = { stopped: true }; }
        else if (request.cancel) { await repl.cancel(request.cancel); reply = { cancelled: true }; }
        else reply = await repl.evaluate(request.code, { timeout_ms: request.timeout_ms, requestId: request.requestId });
        socket.end(JSON.stringify(reply) + '\n');
        if (request.stop) { server.close(); await fs.unlink(socketPath).catch(() => {}); }
      } catch (error) { socket.end(JSON.stringify({ isError: true, content: [{ type: 'text', text: `${error.code ?? error.name}: ${error.message}` }] }) + '\n'); }
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
  await fs.chmod(socketPath, 0o600);
  const stop = async () => { await repl.close(); server.close(); await fs.unlink(socketPath).catch(() => {}); process.exit(0); };
  process.once('SIGTERM', stop); process.once('SIGINT', stop);
}
const tool = {
  name: 'cua_repl', description: toolDescription,
  inputSchema: { type: 'object', properties: { code: { type: 'string' }, timeout_ms: { type: 'integer', minimum: 100, maximum: 60000, default: 30000 } }, required: ['code'], additionalProperties: false },
};
async function mcp() {
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  const pending = new Map(), running = new Set();
  const handle = async request => {
    let result, error;
    const state = { requestId: randomUUID(), cancelled: false, started: false };
    try {
      if (request.method === 'initialize') result = { protocolVersion: ['2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25'].includes(request.params?.protocolVersion) ? request.params.protocolVersion : '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'ataxia-computer-use', version: 'unreleased' }, instructions: tool.description };
      else if (request.method === 'ping') result = {};
      else if (request.method === 'tools/list') result = { tools: [tool] };
      else if (request.method === 'tools/call') {
        if (request.params?.name !== 'cua_repl') throw Error('Unknown tool');
        pending.set(request.id, state);
        await ensureDaemon(); if (state.cancelled) return;
        state.started = true;
        const response = await rpc({ ...request.params.arguments, requestId: state.requestId });
        result = { content: response.content ?? [], ...(response.isError ? { isError: true } : {}) };
      } else error = { code: -32601, message: 'Method not found' };
    } catch (failure) { result = { isError: true, content: [{ type: 'text', text: failure.message }] }; }
    pending.delete(request.id);
    if (!state.cancelled) process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, ...(error ? { error } : { result }) }) + '\n');
  };
  const cancel = async state => { state.cancelled = true; if (state.started) await rpc({ cancel: state.requestId }).catch(() => {}); };
  for await (const line of lines) {
    let request;
    try { requireThat(line.length <= 1_100_000, 'request-too-large', 'Request too large.'); request = JSON.parse(line); }
    catch { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }) + '\n'); continue; }
    if (request.id === undefined) {
      if (request.method === 'notifications/cancelled') { const state = pending.get(request.params?.requestId); if (state) void cancel(state); }
      continue;
    }
    const task = handle(request); running.add(task); task.finally(() => running.delete(task));
  }
  await Promise.all([...pending.values()].map(cancel));
  await Promise.all(running);
}
async function main() {
  if (args.includes('--help')) { console.log('cua_repl [--session NAME] [--code JAVASCRIPT | --stdio | --stop]\nWithout --code, reads JavaScript from stdin. --stdio serves the MCP cua_repl tool.\nA private daemon preserves bindings and marked tabs between calls. --stop ends it.'); return; }
  if (args.includes('--daemon')) return daemon();
  if (args.includes('--stdio')) return mcp();
  if (args.includes('--stop')) { await privateDirectory(); console.log(JSON.stringify(await rpc({ stop: true }))); return; }
  const codeAt = args.indexOf('--code'); let code = codeAt >= 0 ? args[codeAt + 1] : '';
  if (codeAt < 0) for await (const chunk of process.stdin) { code += chunk; if (code.length > 1_000_000) throw Error('Code exceeds its limit.'); }
  await ensureDaemon(); const result = await rpc({ code });
  for (const item of result.content ?? []) {
    if (item.type === 'text') console.log(item.text);
    else if (item.type === 'image') {
      const extension = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp' }[item.mimeType];
      const filename = path.join(directory, `${session}-${randomUUID()}.${extension}`);
      await fs.writeFile(filename, Buffer.from(item.data, 'base64'), { mode: 0o600 }); console.log(`[image] ${filename}`);
    }
  }
  if (result.isError) process.exitCode = 1;
}
main().catch(error => { console.error(`${error.code ?? error.name}: ${error.message}`); process.exitCode = 1; });
