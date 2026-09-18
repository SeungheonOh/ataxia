import { CuaError, requireThat } from './common.mjs';

// Indices belong to one target, are monotonic, and are never recycled for another element.
export class AXState {
  #ids = new Map(); #next = 1; #nodes = new Map(); #previous = null; #needsFull = true;
  invalidate() { this.#needsFull = true; this.#nodes.clear(); }
  reset() { this.#ids.clear(); this.#previous = null; this.invalidate(); }
  get(index) {
    requireThat(Number.isSafeInteger(index), 'invalid-index', 'Use an element index from this target’s latest accessibility state.');
    if (this.#needsFull || !this.#nodes.has(index)) throw new CuaError('stale-element', 'Get a fresh full accessibility state before using this element index.');
    return this.#nodes.get(index);
  }
  update(nodes, { disableDiffing = false, header = '', unavailable = '', truncated = false } = {}) {
    const current = new Map(), nextNodes = new Map();
    for (const node of nodes) {
      let index = this.#ids.get(node.key);
      if (index === undefined) { index = this.#next++; this.#ids.set(node.key, index); }
      const fields = [];
      if (node.name) fields.push(JSON.stringify(node.name));
      if (node.value !== undefined && node.value !== '') fields.push(`value=${JSON.stringify(node.value)}`);
      if (node.states?.length) fields.push(`[${node.states.join(', ')}]`);
      if (node.actions?.length) fields.push(`actions=${JSON.stringify(node.actions)}`);
      const line = `${'  '.repeat(Math.min(node.depth ?? 0, 24))}[${index}] ${node.role || 'element'}${fields.length ? ' ' + fields.join(' ') : ''}`;
      current.set(index, line); nextNodes.set(index, { ...node, index });
    }
    const full = disableDiffing || this.#needsFull || !this.#previous;
    const lines = full ? [...current.values()] : [
      ...[...this.#previous].filter(([id]) => !current.has(id)).map(([id]) => `- [${id}] removed`),
      ...[...current].filter(([id, line]) => this.#previous.get(id) !== line).map(([id, line]) => `${this.#previous.has(id) ? '~' : '+'} ${line}`),
    ];
    this.#previous = current; this.#nodes = nextNodes; this.#needsFull = false;
    const representation = full ? 'Accessibility tree' : lines.length ? 'Accessibility changes' : 'No accessibility-tree change';
    return [header, representation, ...lines, unavailable && `Accessibility unavailable: ${unavailable}. Use a screenshot and coordinate actions.`,
      truncated && 'Tree truncated at the configured node/text limit; refine with a visible target or screenshot.'].filter(Boolean).join('\n');
  }
}
