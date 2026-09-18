import { Worker } from 'node:worker_threads';
import fs from 'node:fs/promises';
import { SerialQueue, requireThat, text } from './common.mjs';
import { request } from './transport.mjs';

/** Persistent JavaScript, with a separate thread so infinite loops are cancellable. */
export class CuaRepl {
  constructor(configuration = {}) { this.configuration = configuration; this.queue = new SerialQueue(); this.next = 1; this.children = new Set(); this.profiles = new Set(); this.pending = new Set(); this.cancelled = new Set(); }
  async start() {
    if (this.worker) return;
    const worker = new Worker(new URL('./repl-worker.mjs', import.meta.url), { workerData: this.configuration });
    this.worker = worker;
    await new Promise((resolve, reject) => {
      worker.on('message', message => {
        if (message.ready) resolve();
        if (message.session) this.session = message.session;
        if (message.child > 0) this.children.add(message.child);
        if (message.child < 0) this.children.delete(-message.child);
        if (message.profile) this.profiles.add(message.profile);
      });
      worker.once('error', reject); worker.once('exit', code => { if (code) reject(Error(`REPL worker exited (${code}).`)); });
    });
  }
  evaluate(code, { timeout_ms = 30_000, requestId = Symbol() } = {}) {
    text(code, 'code', 1_000_000);
    requireThat(Number.isInteger(timeout_ms) && timeout_ms >= 100 && timeout_ms <= 60_000, 'invalid-timeout', 'timeout_ms must be between 100 and 60000.');
    this.pending.add(requestId);
    return this.queue.run(async () => {
      this.pending.delete(requestId);
      if (this.cancelled.delete(requestId)) return { isError: true, content: [{ type: 'text', text: 'Request cancelled before execution.' }] };
      await this.start(); const worker = this.worker, id = this.next++;
      return new Promise(resolve => {
        let done = false, cleaning = false;
        const finish = value => { if (done) return; done = true; this.active = null; clearTimeout(timer); worker.off('message', message); worker.off('error', failed); worker.off('exit', exited); resolve(value); };
        const message = reply => { if (reply.id === id) finish(reply); };
        const failed = async error => {
          if (done || cleaning) return; cleaning = true; worker.off('exit', exited);
          await this.reset(); finish({ content: [{ type: 'text', text: `REPL reset: ${error.message}. Native control disconnected; managed child processes stopped. Bindings were reset. Inspect state before retrying actions.` }], isError: true });
        };
        const exited = code => { if (!done) void failed(Error(`worker exited (${code})`)); };
        const timer = setTimeout(() => void failed(Error('execution timed out; action results may be unknown')), timeout_ms);
        this.active = { requestId, cancel: () => failed(Error('request cancelled; action results may be unknown')) };
        worker.on('message', message); worker.once('error', failed); worker.once('exit', exited);
        worker.postMessage({ id, code });
      });
    });
  }
  async cancel(requestId) {
    if (this.active?.requestId === requestId) await this.active.cancel();
    else if (this.pending.has(requestId)) this.cancelled.add(requestId);
  }
  async reset() {
    const worker = this.worker; this.worker = null;
    await worker?.terminate();
    if (this.session) {
      const { socket, token } = this.session; this.session = null;
      try {
        const status = await request(socket, { op: 'status', token }, { timeout: 3000 });
        if (status.session) await request(socket, { op: 'disconnect', token, sequence: status.session.sequence + 1 }, { timeout: 3000 });
      } catch { /* The compositor also releases input on session expiry. */ }
    }
    for (const pid of this.children) try { process.kill(pid, 'SIGTERM'); } catch {}
    this.children.clear();
    await Promise.all([...this.profiles].map(p => fs.rm(p, { recursive: true, force: true }).catch(() => {}))); this.profiles.clear();
  }
  async close() { await this.queue.run(() => this.reset()); }
}
