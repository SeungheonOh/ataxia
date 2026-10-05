// Reconciler host: what a React tree sends to the compositor.
import assert from "node:assert/strict";
import test from "node:test";
import { createElement as h } from "react";
import { Background, Box, Group, Rect, Shortcut, Text, Window } from "../dist/components.js";
import { Container, createRoot, reconciler } from "../dist/host.js";
import { ease, spring, tween } from "../dist/motion.js";

function mount(measure) {
  const commits = [];
  const container = new Container({ send: (ops) => commits.push(ops), measure });
  const root = createRoot(container, (error) => { throw error; });
  const render = (element) => {
    reconciler.updateContainerSync(element, root, null, null);
    reconciler.flushSyncWork();
    container.flush();
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

test("a Box lays out its children once their text is measured", () => {
  const requests = [];
  const { container, commits, render } = mount((batch) => requests.push(...batch));
  const layouts = [];
  render(h(Box, { x: 50, width: 200, style: [{ padding: 8 }, false, { gap: 4 }], alignItems: "center" },
    h(Text, { size: 12 }, "Hello"),
    h(Rect, { flexGrow: 1, height: 10, onLayout: (box) => layouts.push(box) }),
    h(Rect, { width: 20, height: 20, display: "none" })));
  assert.equal(commits.length, 0, "the commit waits for its text");
  assert.deepEqual(requests.map((request) => request.props), [{ text: "Hello", fontSize: 12 }]);

  container.receiveMeasurements([{ key: requests[0].key, width: 30, height: 16 }]);
  const [, box, text, , rect, , hidden] = commits[0];
  assert.deepEqual(box.props, { x: 50, width: 200, height: 32 });
  assert.deepEqual(text.props, { text: "Hello", fontSize: 12, x: 8, y: 8, width: 30 });
  assert.deepEqual(rect.props, { x: 42, y: 11, width: 150, height: 10 });
  assert.equal(hidden.props.visible, false);
  assert.deepEqual(layouts, [{ x: 42, y: 11, width: 150, height: 10 }]);
});

test("pointer events bubble, and enter and leave reach only the nodes crossed", () => {
  const { container, render } = mount();
  const seen = [];
  const handlers = (name, stop) => ({
    onPointerDown: (event) => {
      seen.push(`${name} down ${event.target.id}->${event.currentTarget.id}`);
      if (stop) event.stopPropagation();
    },
    onPointerEnter: (event) => seen.push(`${name} enter from ${event.relatedTarget?.id ?? "-"}`),
    onPointerLeave: () => seen.push(`${name} leave`),
  });
  render(h(Group, handlers("outer"),
    h(Rect, { width: 10, height: 10, ...handlers("inner", true) }, h(Rect, { width: 5, height: 5 })),
    h(Rect, { width: 10, height: 10 })));
  // Ids follow creation order: leaf 1, inner 2, sibling 3, outer 4.
  container.dispatch({ type: "event", node: 1, name: "pointerdown" });
  assert.deepEqual(seen.splice(0), ["inner down 1->2"]);
  container.dispatch({ type: "event", node: 3, name: "pointerdown" });
  assert.deepEqual(seen.splice(0), ["outer down 3->4"]);
  container.dispatch({ type: "event", node: 1, name: "pointerenter", from: null });
  assert.deepEqual(seen.splice(0), ["outer enter from -", "inner enter from -"]);
  container.dispatch({ type: "event", node: 1, name: "pointerleave", to: 3 });
  container.dispatch({ type: "event", node: 3, name: "pointerenter", from: 1 });
  assert.deepEqual(seen.splice(0), ["inner leave"]);
});

test("nested Texts style their part of the text as Pango markup", () => {
  const { render } = mount();
  const Count = ({ n }) => h(Text, { weight: "bold", color: "#ff8800" }, n);
  const [, text] = render(h(Text, { size: 14 }, "Saved ", h(Count, { n: 3 }), " files & <more>"));
  assert.deepEqual(text.props, {
    fontSize: 14, markup: true,
    text: 'Saved <span weight="700" foreground="#ff8800">3</span> files &amp; &lt;more&gt;',
  });
  const [update] = render(h(Text, { size: 14 }, "Saved ", h(Count, { n: 4 }), " files & <more>"));
  assert.match(update.props.text, />4</);
  const [plain] = render(h(Text, { size: 14 }, "Saved ", false, 4));
  assert.deepEqual(plain.props, { text: "Saved 4", markup: null });
});

test("keyframes, easing functions and effects reach the wire in canonical form", () => {
  const { render } = mount();
  const tree = (n) => h(Group, {
    effect: { shader: "vec4 effect(vec2 p) { return content(p) * tint; }", margin: 4,
              uniforms: { tint: "#ff000080", center: [1, 2] } },
    initial: { effect: { amount: 0, uniforms: { center: [0, 0] } } },
    transition: { effect: tween(0.5, ease.back()) },
  }, h(Rect, { width: n, animate: [{ rotation: [0, 90], key: "spin" }, { x: (t) => t * 10, ease: ease.bounce }] }));
  const [, group, rect] = render(tree(10));
  assert.deepEqual(group.props.uniforms, { tint: [1, 0, 0, 128 / 255], center: [1, 2] });
  assert.equal(group.props.margin, 4);
  assert.deepEqual(group.props.initial, { amount: 0, uniforms: { center: [0, 0] } });
  assert.equal(group.props.transition.amount.type, "curve");
  assert.equal(group.props.transition.uniforms.type, "curve");
  const [spin, slide] = rect.props.animate;
  assert.deepEqual(spin, { property: "rotation", keyframes: [0, Math.PI / 2], duration: 0.5, id: "spin/rotation" });
  assert.equal(slide.property, "x");
  assert.equal(slide.ease, undefined, "an easing function is baked into the keyframes");
  assert.equal(slide.keyframes.at(-1), 10);
  // The same animations keep their ids, so a re-render does not restart them.
  const [update] = render(tree(20));
  assert.deepEqual(update.props, { width: 20 });
});
