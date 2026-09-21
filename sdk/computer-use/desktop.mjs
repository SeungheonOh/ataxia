import { options, requireThat, observationOptions } from './common.mjs';

// All desktop changes use the same native token, serial queue, and revocation gate.
export function desktopMethods(native, emitter) {
  let last, lastToken;
  const remember = (reply, invalidate = true) => {
    if (reply.desktop) { last = structuredClone(reply.desktop); lastToken = native.transport.token; }
    if (invalidate) for (const target of native.targets.values()) { target.ax.invalidate(); target.imageStale = Boolean(target.image) || target.imageStale; target.image = null; }
    return reply;
  };
  const snapshot = async () => {
    const state = (await native.transport.read('desktop')).desktop;
    last = structuredClone(state); lastToken = native.transport.token;
    return state;
  };
  const basis = async opts => {
    options(opts, ['revision']);
    if (!last || lastToken !== native.transport.token) await snapshot();
    const revision = opts.revision ?? last.revision;
    requireThat(Number.isSafeInteger(revision) && revision > 0, 'invalid-revision', 'Use a revision from getWorld().');
    return revision;
  };
  const actions = operations => {
    requireThat(Array.isArray(operations) && operations.length >= 1 && operations.length <= 64, 'invalid-layout', 'Use one to 64 layout operations.');
    return operations;
  };
  const preview = async (operations, opts) => {
    const revision = await basis(opts);
    return native.transport.send('layout-preview', { revision, operations: actions(operations) });
  };
  const arrange = async (operations, opts) => {
    const { plan } = await preview(operations, opts);
    return remember(await native.transport.send('layout-apply', { plan }));
  };
  const windowRecord = async (id, opts) => {
    const revision = await basis(opts);
    requireThat(last.capabilities.layout && last['layout-schema']?.properties?.op?.enum?.includes('place-window'),
      'unsupported-operation', 'This World does not implement place-window. Use its advertised layout schema.');
    requireThat(revision === last.revision, 'desktop-changed', 'Read getWorld() before deriving window placement for that revision.');
    const window = last.windows.find(w => w.id === id);
    requireThat(window, 'window-not-found', 'Choose a window ID from getWorld().');
    return { window, revision };
  };
  const getWorld = async (opts = {}) => {
    observationOptions(opts);
    return native.run(async () => { const state = await snapshot(); if (opts.emit !== false) emitter.write(state); return state; });
  };
  const viewport = (output, action, fields, opts) => {
    requireThat(Number.isSafeInteger(output) && output > 0, 'invalid-output', 'Choose an output ID from getWorld().');
    for (const [key, value] of Object.entries(fields)) requireThat(Number.isFinite(value), 'invalid-viewport', `${key} must be a finite number.`);
    return native.run(async () => remember(await native.transport.send('viewport', {
      action, output, ...fields, revision: await basis(opts),
    }), false));
  };
  return {
    getWorld,
    getDesktop: getWorld,
    async previewLayout(operations, opts = {}) {
      return native.run(async () => { const { plan, revision, operations: validated } = await preview(operations, opts); return { plan, revision, operations: validated }; });
    },
    async applyLayout(plan) {
      requireThat(typeof plan === 'string' && plan.length === 64, 'invalid-plan', 'Use the plan returned by previewLayout().');
      return native.run(() => native.transport.send('layout-apply', { plan }).then(remember));
    },
    async arrange(operations, opts = {}) { return native.run(() => arrange(operations, opts)); },
    async undoLayout(undo) {
      requireThat(typeof undo === 'string' && undo.length === 64, 'invalid-undo', 'Use the Undo token returned by arrange() or applyLayout().');
      return native.run(() => native.transport.send('layout-undo', { undo }).then(remember));
    },
    async moveWindow(id, placement, opts = {}) {
      options(placement, ['group', 'workspace', 'floating', 'x', 'y', 'width', 'height']);
      return native.run(async () => {
        const { window, revision } = await windowRecord(id, opts);
        const group = placement.group === undefined ? window.group : placement.group;
        const workspace = placement.workspace === undefined && group === window.group ? window.workspace : placement.workspace;
        return arrange([{ op: 'place-window', window: id, ...placement, group: group ?? null,
          ...(workspace == null ? {} : { workspace }) }], { revision });
      });
    },
    async setFloating(id, floating, opts = {}) {
      requireThat(typeof floating === 'boolean', 'invalid-floating', 'Supply true to float or false to tile.');
      return native.run(async () => {
        const { window, revision } = await windowRecord(id, opts);
        requireThat(window.group != null, 'group-required', 'This window is on the canvas. Move it into a group before setting floating or tiled placement.');
        return arrange([{ op: 'place-window', window: id, group: window.group, workspace: window.workspace, floating }], { revision });
      });
    },
    async windowAction(id, action, opts = {}) {
      requireThat(['close', 'minimize', 'restore', 'maximize', 'fullscreen'].includes(action), 'invalid-action', 'Use close, minimize, restore, maximize or fullscreen.');
      return native.run(async () => remember(await native.transport.send('window', { window: id, action, revision: await basis(opts) })));
    },
    async setViewport(output, camera, opts = {}) {
      options(camera, ['x', 'y', 'zoom', 'rotation']);
      requireThat(Object.keys(camera).length > 0, 'invalid-viewport', 'Supply x, y, zoom or rotation.');
      return viewport(output, 'set', camera, opts);
    },
    async panViewport(output, delta, opts = {}) {
      options(delta, ['dx', 'dy']);
      requireThat(Number.isFinite(delta.dx) && Number.isFinite(delta.dy), 'invalid-viewport', 'Supply dx and dy in world units.');
      return viewport(output, 'pan', delta, opts);
    },
    async frameWindow(output, window, opts = {}) {
      options(opts, ['revision', 'padding', 'rotation']);
      requireThat(Number.isSafeInteger(window) && window > 0, 'invalid-window', 'Choose a window ID from getWorld().');
      const { revision, ...framing } = opts;
      return viewport(output, 'frame-window', { window, ...framing }, { revision });
    },
    async frameRegion(output, region, opts = {}) {
      options(region, ['x', 'y', 'width', 'height']); options(opts, ['revision', 'padding', 'rotation']);
      requireThat(['x', 'y', 'width', 'height'].every(key => Number.isFinite(region[key])), 'invalid-viewport', 'Supply a world rectangle: x, y, width, height.');
      const { revision, ...framing } = opts;
      return viewport(output, 'frame-region', { ...region, ...framing }, { revision });
    },
  };
}
