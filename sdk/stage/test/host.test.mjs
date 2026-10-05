// Reconciler host: what a React tree sends to the compositor.
import assert from "node:assert/strict";
import test from "node:test";
import { createElement as h } from "react";
import { Background, Group, Rect, Shortcut, Window } from "../dist/components.js";
import { Container, createRoot, reconciler } from "../dist/host.js";
import { spring } from "../dist/motion.js";

function mount() {
  const commits = [];
  const container = new Container((ops) => commits.push(ops));
  const root = createRoot(container, (error) => { throw error; });
  const render = (element) => {
    reconciler.updateContainerSync(element, root, null, null);
    reconciler.flushSyncWork();
    return commits.at(-1);
  };
  return { container, commits, render };
}

test("a first commit resets the scene and sends canonical props", () => {
  const { render } = mount();
  const ops = render(h(Group, { x: 10, rotation: 90 },
    h(Rect, { width: 20, height: 10, fill: "#ff000080", shadow: { blur: 8, y: 2 },
              transition: { default: spring(), fill: { type: "instant" } },
              onPointerDown: () => {} })));
  assert.deepEqual(ops.map((op) => op.op), ["reset", "create", "create", "insert", "insert"]);
  const [, group, rect] = ops;
  assert.equal(group.type, "group");
  assert.equal(group.props.rotation, Math.PI / 2);
  assert.deepEqual(rect.props.color, [1, 0, 0, 128 / 255]);
  assert.equal(rect.props.shadowBlur, 8);
  assert.equal(rect.props.shadowY, 2);
  assert.deepEqual(rect.props.handlers, ["pointerdown"]);
  assert.deepEqual(rect.props.transition.color, { type: "instant" });
  assert.equal(rect.props.transition.default.type, "spring");
  assert.deepEqual(ops.slice(3), [
    { op: "insert", parent: group.id, id: rect.id, before: null },
    { op: "insert", parent: 0, id: group.id, before: null },
  ]);
});

test("updates send only changes, and removed props restore their defaults", () => {
  const { render } = mount();
  render(h(Window, { window: 7, x: 1, y: 2, radius: 4 }));
  const ops = render(h(Window, { window: 7, x: 5, y: 2 }));
  assert.equal(ops.length, 1);
  assert.equal(ops[0].op, "set");
  assert.deepEqual(ops[0].props, { x: 5, radius: null });
});

test("keyed reordering moves nodes without recreating them", () => {
  const { container, render } = mount();
  const rects = (keys) => h(Group, null, keys.map((key) => h(Rect, { key, width: key })));
  render(rects([1, 2, 3]));
  const ops = render(rects([3, 1, 2]));
  assert.ok(ops.length > 0 && ops.every((op) => op.op === "insert"));
  assert.deepEqual(container.children[0].children.map((rect) => rect.wire.width), [3, 1, 2]);
});

test("events reach the latest handler, and a reconnect replays the tree", () => {
  const { container, commits, render } = mount();
  const seen = [];
  render(h(Background, { onPointerDown: () => seen.push("old") }));
  const sent = commits.length;
  render(h(Background, { onPointerDown: (event) => seen.push(event.worldX) }));
  assert.equal(commits.length, sent, "a changed handler function is not a scene change");
  container.dispatch({ type: "event", node: 1, name: "pointerdown", "world-x": 42 });
  assert.deepEqual(seen, [42]);

  render(h(Shortcut, { keys: "Super+Shift+Enter", onPress: () => seen.push("press") }));
  container.dispatch({ type: "event", node: 1, name: "pointerdown", "world-x": 0 });
  assert.deepEqual(seen, [42], "removed nodes receive nothing");

  container.requestResync();
  container.flush();
  const [reset, create, insert] = commits.at(-1);
  assert.deepEqual(reset, { op: "reset" });
  assert.deepEqual(create, { op: "create", id: 2, type: "shortcut",
                             props: { key: "Return", modifiers: ["logo", "shift"], handlers: ["press"] } });
  assert.deepEqual(insert, { op: "insert", parent: 0, id: 2, before: null });
});
