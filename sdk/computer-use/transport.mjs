import net from 'node:net';
import path from 'node:path';
import { CuaError, SerialQueue, requireThat } from './common.mjs';

export function defaultSocket() { return path.join(process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid()}`, 'ataxia-computer-use.sock'); }
export function request(socketPath, data, { timeout = 35_000 } = {}) {
  const bytes = Buffer.from(JSON.stringify(data) + '\n');
  requireThat(bytes.length <= 65536, 'request-too-large', 'Request exceeds the 64 KiB transport limit; split the input.');
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath); let chunks = [], size = 0, done = false;
    const end = (err, reply) => { if (done) return; done = true; socket.destroy(); err ? reject(err) : resolve(reply); };
    socket.setTimeout(timeout, () => end(new CuaError('transport-timeout', 'The result is unknown. Inspect current state before retrying any action.')));
    socket.on('error', e => end(new CuaError('transport-unavailable', `Cannot reach the Ataxia computer-use socket: ${e.message}`)));
    socket.on('connect', () => socket.write(bytes));
    socket.on('data', bytes => {
      chunks.push(bytes); size += bytes.length;
      if (size > 8 * 1024 * 1024) return end(new CuaError('response-too-large', 'Computer-use response exceeded its limit.'));
      if (bytes.includes(10)) {
        try { end(null, JSON.parse(Buffer.concat(chunks).toString('utf8').split('\n')[0])); }
        catch { end(new CuaError('invalid-response', 'The computer-use server returned invalid JSON.')); }
      }
    });
    socket.on('end', () => { if (!done) end(new CuaError('connection-closed', 'The server disconnected before returning a result; do not replay input.')); });
  });
}
export class ComputerTransport {
  constructor({ socket = defaultSocket(), token, name = 'Codex', purpose = 'Operate the requested applications', _onNativeSession } = {}) {
    this.onSession = _onNativeSession;
    this.socket = socket; this.token = token; this.name = name; this.purpose = purpose; this.sequence = null; this.queue = new SerialQueue(); this.requests = 0;
  }
  async raw(data) { this.requests++; return request(this.socket, data); }
  accept(reply) {
    if (reply.session) { this.sequence = reply.session.sequence; this.session = reply.session; }
    if (!reply.ok) throw new CuaError(reply.error || 'request-failed', reply.message || 'Computer-use request failed.', reply);
    return reply;
  }
  async connect(options = {}) {
    if (!this.token) {
      const reply = this.accept(await this.raw({ op: 'connect', name: this.name, purpose: this.purpose, ...options })); this.token = reply.token;
      this.onSession?.({ socket: this.socket, token: this.token });
    }
    return this.status();
  }
  async status() {
    if (!this.token) return this.connect();
    return this.accept(await this.raw({ op: 'status', token: this.token }));
  }
  async active() {
    if (!this.token || this.sequence === null || this.session?.state !== 'active') await this.status();
    const paused = this.session?.state === 'paused';
    requireThat(this.session?.state === 'active', paused ? 'session-paused' : 'session-closed',
      paused ? 'This session is paused. Resume it in Ataxia’s Agent sessions panel.' : 'This session is closed.');
  }
  async read(op, fields = {}) { await this.active(); return this.accept(await this.raw({ op, token: this.token, ...fields })); }
  async send(op, fields = {}) {
    await this.active();
    if (this.sequence === null) await this.status();
    try { return this.accept(await this.raw({ op, token: this.token, sequence: this.sequence + 1, ...fields })); }
    catch (error) {
      // Reconcile a possibly consumed sequence; never replay a consequential request.
      try { await this.status(); } catch { this.sequence = null; }
      throw error;
    }
  }
  async batch(actions, { capture = false, settle = .15 } = {}) { return this.send('batch', { actions, capture, settle }); }
  async disconnect() {
    if (!this.token) return;
    try {
      await this.status();
      this.accept(await this.raw({ op: 'disconnect', token: this.token, sequence: this.sequence + 1 }));
    } finally { this.token = undefined; this.sequence = null; this.session = null; }
  }
}
