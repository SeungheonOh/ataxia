// A Hyprland-style tiling world.
//
//   Super+Return / Super+Q          open a terminal / close the focused window
//   Super+D                         application launcher (a React DOM page)
//   Super+1..9, Super+wheel         switch workspace; three-finger swipe slides between them
//   Super+Shift+1..9                move the focused window to a workspace
//   Super+arrows or H/J/K/L         focus the neighbour in that direction
//   Super+Shift+arrows or H/J/K/L   swap with that neighbour
//   Super+V / Super+F / Super+T     toggle floating / fullscreen / dwindle-master layout
//   Super+S, Super+Shift+S          show the scratchpad / move a window to or from it
//   Super+drag, Super+right-drag    move (tiled windows swap) / resize floating windows
//
// Focus follows the mouse; the focused window's gradient border turns once. The status bar shows the workspaces of the
// focused window's output; clicking one switches to it.

import { existsSync } from "node:fs";
import { useEffect, useState } from "react";
import { accent, Bar, ink } from "./bar.js";
import {
  close, dwindle, focus, GestureBinding, Group, Image, launch, launchApplication, masterStack,
  PointerBinding, Rect, Screen, Shell, Shortcut, spring, tween, useApplications,
  useFocusedWindow, useOutputs, usePersistentState, useWindows, Web, WheelBinding, Window,
  type Box, type OutputInfo,
} from "@ataxia/stage";

type Layout = "dwindle" | "master";

const workspaceNumbers = [1, 2, 3, 4, 5, 6, 7, 8, 9];
const gap = 10;
const outer = 18;
const stripGap = 80;
const wallpaper = "/usr/share/backgrounds/Resolute_Raccoon_Wallpaper_Dimmed_3840x2160.png";
const windowMotion = spring({ duration: 0.38, bounce: 0.12 });
const slide = spring({ duration: 0.42, bounce: 0.04 });
const pillMotion = spring({ duration: 0.3, bounce: 0.1 });
// The focused border turns once when focus arrives; a forever loop would keep
// the display awake.
const turn = tween(1.2, "ease-out");
const active = { from: "#33ccff", to: "#00ff99", angle: 360 };
const inactive = "#59595988";
const terminal = process.env.TERMINAL ?? "foot";

const directions = {
  Left: [-1, 0], Right: [1, 0], Up: [0, -1], Down: [0, 1], H: [-1, 0], L: [1, 0], K: [0, -1], J: [0, 1],
} as const;

/** The box nearest to FROM's center in direction (DX, DY). */
function neighbour(boxes: Map<number, Box>, from: number, dx: number, dy: number) {
  const origin = boxes.get(from);
  if (!origin) return null;
  let best: number | null = null;
  let bestScore = Infinity;
  for (const [id, box] of boxes) {
    const ax = box.x + box.width / 2 - (origin.x + origin.width / 2);
    const ay = box.y + box.height / 2 - (origin.y + origin.height / 2);
    const along = ax * dx + ay * dy;
    const score = along + 2 * Math.abs(ax * dy - ay * dx);
    if (id !== from && along > 0 && score < bestScore) [best, bestScore] = [id, score];
  }
  return best;
}

function centered(area: Box, fraction: number): Box {
  const width = area.width * fraction;
  const height = area.height * fraction;
  return { x: area.x + (area.width - width) / 2, y: area.y + (area.height - height) / 2, width, height };
}

export default function Hypr() {
  const windows = useWindows();
  const outputs = useOutputs();
  const focused = useFocusedWindow();
  const applications = useApplications();
  const [assigned, setAssigned] = usePersistentState<Record<number, number>>("hypr.workspace", {});
  const [shown, setShown] = usePersistentState<Record<string, number>>("hypr.shown", {});
  const [order, setOrder] = usePersistentState<number[]>("hypr.order", []);
  const [floating, setFloating] = usePersistentState<Record<number, Box>>("hypr.floating", {});
  const [layouts, setLayouts] = usePersistentState<Record<number, Layout>>("hypr.layouts", {});
  const [fullscreen, setFullscreen] = usePersistentState<number | null>("hypr.fullscreen", null);
  const [scratchpad, setScratchpad] = usePersistentState<number[]>("hypr.scratchpad", []);
  const [scratchpadShown, setScratchpadShown] = useState(false);
  const [launcherShown, setLauncherShown] = useState(false);
  const [swipe, setSwipe] = useState(0);

  const workspaceOf = (output: OutputInfo, index: number) => shown[output.name] ?? index + 1;
  const outputShowing = (workspace: number) =>
    outputs.find((output, index) => workspaceOf(output, index) === workspace);
  // Keyboard actions apply to the output showing the focused window.
  const focusOutput = outputs.find((output, index) =>
    focused !== null && assigned[focused] === workspaceOf(output, index)) ?? outputs[0];
  const current = focusOutput ? workspaceOf(focusOutput, outputs.indexOf(focusOutput)) : 1;

  // New windows open on the focused output's workspace, at the end of its order,
  // and closed ones are forgotten. Ids restart with the compositor, so state
  // saved by an earlier session is pruned once this session's windows arrive.
  useEffect(() => {
    if (windows.length === 0) return;
    const live = new Set(windows.map((window) => window.id));
    const fresh = windows.filter((window) => !order.includes(window.id)).map((window) => window.id);
    const stale = (id: number | string) => !live.has(Number(id));
    if (fresh.length === 0 && !order.some(stale) && !Object.keys(assigned).some(stale)) return;
    const keep = <T,>(all: Record<number, T>) =>
      Object.fromEntries(Object.entries(all).filter(([id]) => !stale(id))) as Record<number, T>;
    setOrder((ids) => [...ids.filter((id) => !stale(id)), ...fresh]);
    setAssigned((all) => ({ ...keep(all), ...Object.fromEntries(fresh.map((id) => [id, current])) }));
    setFloating((all) => keep(all));
    setScratchpad((ids) => ids.filter((id) => !stale(id)));
    setFullscreen((id) => id !== null && stale(id) ? null : id);
  });

  // Boxes of every presented window, in its output's logical pixels.
  const boxes = new Map<number, Box>();
  const present = new Set(windows.map((window) => window.id));
  for (const [index, output] of outputs.entries()) {
    const workspace = workspaceOf(output, index);
    const tiled = order.filter((id) => present.has(id) && assigned[id] === workspace
      && !floating[id] && !scratchpad.includes(id) && id !== fullscreen);
    const place = (layouts[workspace] ?? "dwindle") === "master" ? masterStack : dwindle;
    for (const box of place(tiled, output.workArea, { gap, outer })) boxes.set(box.key, box);
    for (const id of order) {
      if (present.has(id) && assigned[id] === workspace && floating[id]) boxes.set(id, floating[id]);
    }
  }

  function switchTo(workspace: number) {
    const output = focusOutput;
    if (!output || workspace < 1 || workspace > 9) return;
    setShown((all) => ({ ...all, [output.name]: workspace }));
    const first = order.find((id) => assigned[id] === workspace && present.has(id));
    focus(first ?? null);
  }

  function moveFocused(workspace: number) {
    if (focused === null) return;
    setAssigned((all) => ({ ...all, [focused]: workspace }));
    setScratchpad((ids) => ids.filter((id) => id !== focused));
  }

  function swap(first: number, second: number) {
    setOrder((ids) => ids.map((id) => id === first ? second : id === second ? first : id));
  }

  function toggleFloating(id: number) {
    setFloating(({ [id]: box, ...rest }) => {
      const area = outputShowing(assigned[id] ?? current)?.workArea;
      return box || !area ? rest : { ...rest, [id]: boxes.get(id) ?? centered(area, 0.6) };
    });
  }

  function toggleScratchpad(id: number) {
    setScratchpad((ids) => ids.includes(id) ? ids.filter((other) => other !== id) : [...ids, id]);
  }

  const windowNodes = (output: OutputInfo, workspace: number) => {
    // Floating windows stack above tiled ones; the focused one on top.
    const ids = order.filter((id) => present.has(id) && assigned[id] === workspace
      && !scratchpad.includes(id) && id !== fullscreen);
    ids.sort((left, right) => Number(Boolean(floating[left])) - Number(Boolean(floating[right]))
      || Number(left === focused) - Number(right === focused));
    return ids.map((id) => {
      const box = boxes.get(id) ?? centered(output.workArea, 0.6);
      return <HyprWindow key={id} id={id} box={box} focused={id === focused} floating={Boolean(floating[id])}
                         onDrop={(x, y) => {
                           if (floating[id]) {
                             setFloating((all) => ({ ...all, [id]: { ...box, x, y } }));
                             return;
                           }
                           const target = neighbourAt(boxes, id, x + box.width / 2, y + box.height / 2);
                           if (target !== null) swap(id, target);
                         }}
                         onResize={(next) => setFloating((all) => ({ ...all, [id]: next }))}
                         onFullscreen={(value) => setFullscreen(value ? id : null)} />;
    });
  };

  const fullscreenWindow = fullscreen !== null && present.has(fullscreen) ? fullscreen : null;

  return (
    <>
      <Shell name="Hypr" workspaces={9} selected={current}
             onNavigate={({ action, workspace }) => {
               if (workspace) switchTo(workspace);
               else if (action === "previous") switchTo(current - 1);
               else if (action === "next") switchTo(current + 1);
             }} />

      {outputs.map((output, index) => {
        const workspace = workspaceOf(output, index);
        const stride = output.width + stripGap;
        return (
          <Screen key={output.name} output={output.name}>
            {existsSync(wallpaper)
              ? <Image src={wallpaper} width={output.width} height={output.height} fit="cover"
                       originX={0} originY={0} />
              : <Rect width={output.width} height={output.height} originX={0} originY={0}
                      fill={{ from: "#1e1e2e", to: "#313244", angle: 120 }} />}
            {/* Workspaces side by side; the strip slides to the shown one. */}
            <Group x={-(workspace - 1) * stride + (output === focusOutput ? swipe : 0)}
                   transition={swipe === 0 ? slide : undefined}>
              {workspaceNumbers.map((number) => (
                (number === workspace || !outputShowing(number) && output === outputs[0]) && (
                  <Group key={number} x={(number - 1) * stride}>{windowNodes(output, number)}</Group>
                )))}
            </Group>
            {fullscreenWindow !== null && assigned[fullscreenWindow] === workspace && (
              <Window window={fullscreenWindow} x={0} y={0} width={output.width} height={output.height}
                      originX={0} originY={0} fullscreen transition={windowMotion}
                      onFullscreenRequest={({ value }) => setFullscreen(value ? fullscreenWindow : null)} />
            )}
          </Screen>
        );
      })}

      {focusOutput && (
        <Screen output={focusOutput.name}>
          <Rect width={focusOutput.width} height={focusOutput.height} originX={0} originY={0}
                fill="#00000066" blur={18} opacity={scratchpadShown ? 1 : 0} transition={slide} />
          <Group y={scratchpadShown ? 0 : -focusOutput.height} transition={slide}>
            {scratchpad.filter((id) => present.has(id)).map((id, index, all) => {
              const box = centered(focusOutput.workArea, 0.7);
              const offset = (index - (all.length - 1) / 2) * 36;
              return <HyprWindow key={id} id={id} focused={id === focused} floating
                                 box={{ ...box, x: box.x + offset, y: box.y + offset }}
                                 onDrop={() => undefined} onResize={() => undefined}
                                 onFullscreen={() => undefined} />;
            })}
          </Group>
          {/* Kept mounted so it opens instantly; hidden pages cost nothing. */}
          <Web src="./launcher.tsx" props={{ applications, shown: launcherShown }} autoFocus
               x={(focusOutput.width - 640) / 2} y={focusOutput.height * 0.22} width={640} height={420}
               radius={16} blur={28} interactive={launcherShown}
               opacity={launcherShown ? 1 : 0} scale={launcherShown ? 1 : 0.96}
               border={{ width: 1, color: "#ffffff22" }} shadow={{ color: "#00000080", blur: 48, y: 16 }}
               transition={spring({ duration: 0.22 })}
               onMessage={(name, value) => {
                 if (name === "launch") launchApplication(value as string);
                 setLauncherShown(false);
               }} />
        </Screen>
      )}

      <Bar left={(output) => {
        const shown = workspaceOf(output, outputs.indexOf(output));
        let x = 0;
        // The shown workspace is a wide accent pill; occupied ones are darker dots.
        return workspaceNumbers.map((number) => {
          const width = number === shown ? 22 : 8;
          const occupied = windows.some((window) => assigned[window.id] === number);
          const pill = (
            <Rect key={number} x={x} y={12} width={width} height={8} radius={4} originX={0} originY={0}
                  fill={number === shown ? accent : ink} opacity={number === shown ? 1 : occupied ? 0.55 : 0.18}
                  transition={pillMotion} onPointerDown={() => switchTo(number)} />
          );
          x += width + 6;
          return pill;
        });
      }} />

      <PointerBinding button="left" modifiers="super" action="move" />
      <PointerBinding button="right" modifiers="super" action="resize" />
      <WheelBinding modifiers="super" onWheel={({ delta }) => switchTo(current + Math.sign(delta))} />
      <GestureBinding gesture="swipe" fingers={3}
                      onUpdate={({ dx }) => setSwipe((offset) => offset + dx)}
                      onEnd={({ cancelled }) => {
                        setSwipe(0);
                        if (!cancelled && Math.abs(swipe) > 120) switchTo(current - Math.sign(swipe));
                      }} />

      <Shortcut keys="Super+Return" onPress={() => launch(terminal)} />
      <Shortcut keys="Super+Q" onPress={() => focused !== null && close(focused)} />
      <Shortcut keys="Super+D" onPress={() => setLauncherShown((shown) => !shown)} />
      <Shortcut keys="Super+F" onPress={() => focused !== null
        && setFullscreen((id) => id === focused ? null : focused)} />
      <Shortcut keys="Super+V" onPress={() => focused !== null && toggleFloating(focused)} />
      <Shortcut keys="Super+T" onPress={() => setLayouts((all) => ({
        ...all, [current]: (all[current] ?? "dwindle") === "dwindle" ? "master" : "dwindle" }))} />
      <Shortcut keys="Super+S" onPress={() => setScratchpadShown((shown) => !shown)} />
      <Shortcut keys="Super+Shift+S" onPress={() => focused !== null && toggleScratchpad(focused)} />
      {workspaceNumbers.map((number) => [
        <Shortcut key={`go-${number}`} keys={`Super+${number}`} onPress={() => switchTo(number)} />,
        <Shortcut key={`move-${number}`} keys={`Super+Shift+${number}`} onPress={() => moveFocused(number)} />,
      ])}
      {Object.entries(directions).map(([key, [dx, dy]]) => [
        <Shortcut key={`focus-${key}`} keys={`Super+${key}`} onPress={() => {
          const next = focused === null ? order.find((id) => boxes.has(id)) : neighbour(boxes, focused, dx, dy);
          if (next != null) focus(next);
        }} />,
        <Shortcut key={`swap-${key}`} keys={`Super+Shift+${key}`} onPress={() => {
          const next = focused === null ? null : neighbour(boxes, focused, dx, dy);
          if (focused !== null && next !== null) swap(focused, next);
        }} />,
      ])}
    </>
  );
}

/** The tiled window, other than ID, whose box contains (X, Y). */
function neighbourAt(boxes: Map<number, Box>, id: number, x: number, y: number) {
  for (const [other, box] of boxes) {
    if (other !== id && x >= box.x && x <= box.x + box.width && y >= box.y && y <= box.y + box.height) {
      return other;
    }
  }
  return null;
}

function HyprWindow({ id, box, focused, floating, onDrop, onResize, onFullscreen }: {
  id: number; box: Box; focused: boolean; floating: boolean;
  onDrop: (x: number, y: number) => void;
  onResize: (box: Box) => void;
  onFullscreen: (value: boolean) => void;
}) {
  return (
    <Window window={id} {...box} originX={0.5} originY={0.5} radius={10} tiled={!floating}
            border={{ width: 2, color: focused ? active : { from: inactive, to: inactive, angle: 0 } }}
            shadow={{ color: floating ? "#000000aa" : "#00000055", blur: floating ? 36 : 18, y: 6 }}
            dim={focused ? 0 : 0.12} movable resizable={floating}
            initial={{ opacity: 0, scale: 0.8, border: { color: { angle: 0 } } }}
            exit={{ opacity: 0, scale: 0.8 }}
            transition={{ default: windowMotion, borderAngle: turn }}
            onPointerEnter={() => focus(id)}
            onDragEnd={({ x, y }) => onDrop(x, y)}
            onResizeEnd={(next) => onResize(next)}
            onFullscreenRequest={({ value }) => onFullscreen(Boolean(value))} />
  );
}
