import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { CuaError } from './common.mjs';

export class AccessibilityHelper {
  #process; #pending = new Map(); #next = 1;
  constructor(onChild) { this.onChild = onChild; }
  start() {
    if (this.#process) return;
    const child = spawn(process.env.ATAXIA_CUA_PYTHON ?? 'python3', ['-u', fileURLToPath(new URL('./atspi.py', import.meta.url))], { stdio: ['pipe', 'pipe', 'pipe'] });
    this.#process = child; let diagnostic = '';
    this.onChild?.(child.pid);
    child.stderr.on('data', bytes => { diagnostic = (diagnostic + bytes.toString()).slice(-2000); });
    createInterface({ input: child.stdout }).on('line', line => {
      let reply; try { reply = JSON.parse(line); } catch { return; }
      const call = this.#pending.get(reply.id); if (!call) return;
      clearTimeout(call.timer); this.#pending.delete(reply.id);
      reply.ok ? call.resolve(reply.result) : call.reject(new CuaError(reply.error ?? 'accessibility-error', reply.message));
    });
    const failed = error => {
      if (this.#process === child) this.#process = undefined;
      for (const call of this.#pending.values()) { clearTimeout(call.timer); call.reject(new CuaError('accessibility-unavailable', error?.message ?? (diagnostic || 'AT-SPI helper stopped.'))); }
      this.#pending.clear();
    };
    child.on('error', failed); child.on('exit', () => { this.onChild?.(-child.pid); failed(); });
    child.stdin.on('error', failed);
  }
  call(op, fields = {}) {
    this.start(); const id = this.#next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id); this.#process?.kill();
        reject(new CuaError('accessibility-timeout', 'The accessibility provider did not reply. Inspect state before retrying an action.'));
      }, 12_000);
      this.#pending.set(id, { resolve, reject, timer });
      this.#process.stdin.write(JSON.stringify({ id, op, ...fields }) + '\n');
    });
  }
  close() { this.#process?.kill(); }
}
