import { parentPort, workerData } from 'node:worker_threads';
import repl from 'node:repl';
import { PassThrough, Writable } from 'node:stream';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { inspect } from 'node:util';
import { createCua } from './index.mjs';

let content = [], outputBytes = 0, accepting = false;
function append(item) {
  if (!accepting) return;
  outputBytes += Buffer.byteLength(JSON.stringify(item));
  if (outputBytes > 32 * 1024 * 1024) throw Error('REPL output exceeds 32 MiB. Emit fewer images or less text.');
  content.push(item);
}
const nodeRepl = {
  write(value) { append({ type: 'text', text: typeof value === 'string' ? value : inspect(value, { depth: 8, maxArrayLength: 3000, colors: false }) }); },
  emitImage(value) {
    let bytes, mimeType;
    if (typeof value === 'string' && value.startsWith('file:')) bytes = fs.readFileSync(fileURLToPath(value));
    else if (typeof value === 'string' && value.startsWith('data:')) {
      const match = /^data:(image\/(?:png|jpeg|webp));base64,(.*)$/s.exec(value);
      if (!match) throw Error('Use a base64 PNG, JPEG or WebP data URL.');
      mimeType = match[1]; bytes = Buffer.from(match[2], 'base64');
    } else { bytes = Buffer.from(value?.bytes ?? value); mimeType = value?.mimeType; }
    if (!mimeType) mimeType = bytes.subarray(1, 4).toString() === 'PNG' ? 'image/png' : bytes[0] === 255 && bytes[1] === 216 ? 'image/jpeg' : bytes.subarray(8, 12).toString() === 'WEBP' ? 'image/webp' : null;
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(mimeType)) throw Error('Use PNG, JPEG or WebP image data.');
    append({ type: 'image', data: bytes.toString('base64'), mimeType });
  },
};
const cua = createCua({ ...workerData,
  nodeRepl, _onNativeSession: session => parentPort.postMessage({ session }),
  _onChild: (pid, profile) => { if (pid) parentPort.postMessage({ child: pid, profile }); },
});
const input = new PassThrough(), output = new Writable({ write(_chunk, _encoding, done) { done(); } });
const server = repl.start({ input, output, terminal: false, prompt: '', useGlobal: false, ignoreUndefined: true });
Object.assign(server.context, { cua, nodeRepl, console: { log: (...v) => nodeRepl.write(v.length === 1 ? v[0] : v), error: (...v) => nodeRepl.write(v), warn: (...v) => nodeRepl.write(v) } });
parentPort.on('message', async ({ id, code, dispose }) => {
  if (dispose) { await cua[Symbol.asyncDispose](); parentPort.postMessage({ id, content: [] }); return; }
  content = []; outputBytes = 0; accepting = true;
  const finish = error => {
    if (!accepting) return; accepting = false;
    if (error) content.push({ type: 'text', text: `${error.code ?? error.name ?? 'Error'}: ${error.message ?? error}` });
    parentPort.postMessage({ id, content, ...(error ? { isError: true } : {}) });
  };
  // REPL's domain routes synchronous exceptions to its output stream. Capture
  // them too so an ordinary throw completes immediately instead of timing out.
  const onError = error => finish(error);
  server._domain?.once('error', onError);
  try { server.eval(`${code}\n`, server.context, 'cua_repl', error => { server._domain?.removeListener('error', onError); finish(error); }); }
  catch (error) { server._domain?.removeListener('error', onError); finish(error); }
});
parentPort.postMessage({ ready: true });
