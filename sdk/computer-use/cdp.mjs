import { EventEmitter } from 'node:events';
import { CuaError, requireThat } from './common.mjs';

export class CDP extends EventEmitter {
  #send; #close; #next = 1; #pending = new Map(); closed = false; requests = 0;
  constructor(send, close) { super(); this.#send = send; this.#close = close; }
  receive(message) {
    let value; try { value = JSON.parse(message); } catch { return this.fail('Browser returned malformed protocol data.'); }
    if (value.id) {
      const pending = this.#pending.get(value.id); if (!pending) return;
      this.#pending.delete(value.id); clearTimeout(pending.timer);
      value.error ? pending.reject(new CuaError('browser-protocol-error', value.error.message, value.error)) : pending.resolve(value.result ?? {});
    } else this.emit('event', value);
  }
  fail(message) {
    if (this.closed) return; this.closed = true;
    for (const pending of this.#pending.values()) { clearTimeout(pending.timer); pending.reject(new CuaError('browser-disconnected', message)); }
    this.#pending.clear(); this.emit('closed');
  }
  call(method, params = {}, sessionId, timeout = 12_000) {
    requireThat(!this.closed, 'browser-disconnected', 'The browser connection has closed. Reacquire the browser before continuing.');
    const id = this.#next++; this.requests++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.#pending.delete(id); reject(new CuaError('browser-timeout', `${method} timed out. Inspect state before retrying an action.`)); }, timeout);
      this.#pending.set(id, { resolve, reject, timer });
      try { this.#send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) })); }
      catch (error) { clearTimeout(timer); this.#pending.delete(id); reject(error); }
    });
  }
  close() { this.#close(); this.fail('Browser connection closed.'); }
  static pipe(child) {
    const connection = new CDP(message => child.stdio[3].write(message + '\0'), () => { child.stdio[3].end(); child.stdio[4].destroy(); });
    let buffer = Buffer.alloc(0);
    child.stdio[4].on('data', bytes => {
      buffer = Buffer.concat([buffer, bytes]);
      if (buffer.length > 48 * 1024 * 1024) return connection.close();
      let at; while ((at = buffer.indexOf(0)) >= 0) { connection.receive(buffer.subarray(0, at).toString()); buffer = buffer.subarray(at + 1); }
    });
    child.stdio[3].on('error', error => connection.fail(error.message)); child.stdio[4].on('error', error => connection.fail(error.message));
    child.on('exit', () => connection.fail('Managed browser exited.')); child.on('error', error => connection.fail(error.message));
    return connection;
  }
  static async websocket(endpoint) {
    let url = new URL(endpoint);
    requireThat(['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) && ['ws:', 'http:'].includes(url.protocol), 'invalid-browser-endpoint', 'Use a configured loopback CDP endpoint. Remote providers need a separate explicit integration.');
    if (url.protocol === 'http:') {
      const response = await fetch(new URL('/json/version', url), { signal: AbortSignal.timeout(5000), redirect: 'error' });
      requireThat(response.ok, 'browser-unavailable', 'The CDP version endpoint did not respond.');
      url = new URL((await response.json()).webSocketDebuggerUrl);
      requireThat(['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) && url.protocol === 'ws:', 'invalid-browser-endpoint', 'The debugger endpoint must remain on loopback.');
    }
    const socket = new WebSocket(url);
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { socket.close(); reject(new CuaError('browser-unavailable', 'Timed out connecting to CDP.')); }, 5000);
      socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
      socket.addEventListener('error', () => { clearTimeout(timer); reject(new CuaError('browser-unavailable', 'Could not connect to CDP.')); }, { once: true });
    });
    const connection = new CDP(message => socket.send(message), () => socket.close());
    socket.addEventListener('message', event => connection.receive(event.data));
    socket.addEventListener('close', () => connection.fail('CDP disconnected.'));
    socket.addEventListener('error', () => connection.fail('CDP connection failed.'));
    return connection;
  }
}
