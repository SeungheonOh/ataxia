// An infinite canvas: windows float on a dotted plane under a spring camera.
//
//   Drag or scroll empty canvas, three-finger swipe   pan (with momentum)
//   Super+wheel, pinch                                zoom around the pointer
//   Super+drag, or a client's title bar               move a window
//   Super+right-drag, or a client's edges             resize a window
//   Super+arrows                                      focus the nearest window that way and fly to it
//   Super+O                                           overview of every window; click one to dive in
//   Super+C                                           center the focused window at 100%
//   Super+Return / Super+Q                            open a terminal / close the focused window
//
// Pans, zooms, moves and resizes run inside the compositor in the same frame
// as the input; this file only stores where things ended up. Edit it while it
// runs: the runtime reloads it and every window glides to its new place.

import { useEffect, useState } from "react";
import { accent, Bar, BarLabel, ink, paper } from "./bar.js";
import {
  Background, Camera, close, focus, GestureBinding, launch, moveCamera, PointerBinding, Rect,
  Screen, Shortcut, spring, useCamera, useFocusedWindow, useOutputs, usePersistentState,
  useWindows, WheelBinding, Window, type CameraInfo,
} from "@ataxia/stage";

interface Place { x: number; y: number; width: number; height: number }

const glide = spring({ duration: 0.45, bounce: 0.08 });
const settle = spring({ duration: 0.3 });

function bounds(places: Iterable<Place>) {
  let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
  for (const place of places) {
    left = Math.min(left, place.x);
    top = Math.min(top, place.y);
    right = Math.max(right, place.x + place.width);
    bottom = Math.max(bottom, place.y + place.height);
  }
  return left <= right ? { left, top, right, bottom } : null;
}

/** The closest window whose center lies in direction (DX, DY) from FROM's. */
function neighbor(places: Map<number, Place>, from: number, dx: number, dy: number) {
  const origin = places.get(from);
  if (!origin) return null;
  let best: number | null = null;
  let bestScore = Infinity;
  for (const [id, place] of places) {
    const ax = place.x + place.width / 2 - (origin.x + origin.width / 2);
    const ay = place.y + place.height / 2 - (origin.y + origin.height / 2);
    const along = ax * dx + ay * dy;
    const score = along + 2 * Math.abs(ax * dy - ay * dx);
    if (id !== from && along > 0 && score < bestScore) [best, bestScore] = [id, score];
  }
  return best;
}

export default function Canvas() {
  const windows = useWindows();
  const outputs = useOutputs();
  const focused = useFocusedWindow();
  const camera = useCamera();
  const [stored, setStored] = usePersistentState<Record<number, Place>>("canvas.places", {});
  // Stacking order, bottom to top: focusing a window raises it.
  const [stack, setStack] = usePersistentState<number[]>("canvas.stack", []);
  const [overview, setOverview] = usePersistentState<CameraInfo | null>("canvas.overview", null);
  const [lifted, setLifted] = useState<number | null>(null);
  const output = outputs[0];

  // New windows open where the camera looks, cascading so none hides another.
  const places = new Map<number, Place>();
  windows.forEach((window, index) => {
    const size = { width: Math.max(window.width, 960), height: Math.max(window.height, 620) };
    const center = camera ?? { x: 0, y: 0 };
    places.set(window.id, stored[window.id] ?? {
      ...size, x: center.x - size.width / 2 + 36 * (index % 6), y: center.y - size.height / 2 + 36 * (index % 6),
    });
  });
  useEffect(() => {
    if (windows.some((window) => !stored[window.id])) setStored(Object.fromEntries(places));
  });

  const place = (id: number, next: Partial<Place>) =>
    setStored((all) => ({ ...all, [id]: { ...places.get(id)!, ...next } }));

  function flyTo(id: number, zoom = Math.max(camera?.zoom ?? 1, 0.6)) {
    const target = places.get(id);
    if (!target) return;
    setOverview(null);
    moveCamera({ x: target.x + target.width / 2, y: target.y + target.height / 2, zoom });
  }

  useEffect(() => {
    if (focused === null) return;
    setStack((order) => order.at(-1) === focused ? order : [...order.filter((id) => id !== focused), focused]);
    // Clicking a window while in the overview dives into it.
    if (overview) flyTo(focused, overview.zoom);
  }, [focused]);
  const stacked = [...windows].sort((left, right) => stack.indexOf(left.id) - stack.indexOf(right.id));

  function toggleOverview() {
    const box = bounds(places.values());
    if (overview) {
      moveCamera(overview);
      setOverview(null);
    } else if (box && camera && output) {
      setOverview(camera);
      const fit = 0.85 * Math.min(output.width / (box.right - box.left),
                                  output.height / (box.bottom - box.top));
      moveCamera({ x: (box.left + box.right) / 2, y: (box.top + box.bottom) / 2, zoom: Math.min(fit, 1) });
    }
  }

  return (
    <>
      <Camera minZoom={0.08} maxZoom={4} transition={glide} />
      <Background fill={paper} grid={{ kind: "dots", color: "#00000033", spacing: 28, size: 1.1 }} pan />

      {stacked.map((window) => {
        const { x, y, width, height } = places.get(window.id)!;
        const isFocused = window.id === focused;
        const isLifted = window.id === lifted;
        return (
          <Window key={window.id} window={window.id} x={x} y={y} width={width} height={height}
                  radius={10} tiled movable resizable scale={isLifted ? 1.012 : 1}
                  border={{ width: isFocused ? 2 : 1, color: isFocused ? accent : "#00000022" }}
                  shadow={{ color: isFocused ? "#0000004d" : "#00000026", blur: isLifted ? 64 : 36,
                            y: isLifted ? 26 : 12 }}
                  initial={{ opacity: 0, scale: 0.94 }} exit={{ opacity: 0, scale: 0.94 }}
                  transition={settle}
                  onDragStart={() => setLifted(window.id)}
                  onDragEnd={({ x, y }) => { setLifted(null); place(window.id, { x, y }); }}
                  onResizeEnd={(box) => place(window.id, box)} />
        );
      })}

      {output && camera && (
        <Minimap output={output.name} width={output.width} height={output.height} places={places}
                 focused={focused}
                 visible={{ x: camera.x - output.width / 2 / camera.zoom,
                            y: camera.y - output.height / 2 / camera.zoom,
                            width: output.width / camera.zoom, height: output.height / camera.zoom }} />
      )}

      <Bar left={() => <BarLabel>{`Canvas · ${Math.round((camera?.zoom ?? 1) * 100)}%`}</BarLabel>} />

      <PointerBinding button="left" modifiers="super" action="move" />
      <PointerBinding button="right" modifiers="super" action="resize" />
      <PointerBinding button="middle" action="pan" />
      <WheelBinding modifiers="super" action="zoom" />
      <GestureBinding gesture="pinch" fingers={2} action="zoom" />
      <GestureBinding gesture="swipe" fingers={3} action="pan" />

      <Shortcut keys="Super+Return" onPress={() => launch("foot")} />
      <Shortcut keys="Super+Q" onPress={() => focused !== null && close(focused)} />
      <Shortcut keys="Super+O" onPress={toggleOverview} />
      <Shortcut keys="Super+C" onPress={() => focused !== null && flyTo(focused, 1)} />
      {([["Left", -1, 0], ["Right", 1, 0], ["Up", 0, -1], ["Down", 0, 1]] as const).map(([key, dx, dy]) => (
        <Shortcut key={key} keys={`Super+${key}`} onPress={() => {
          const next = focused === null ? windows[0]?.id : neighbor(places, focused, dx, dy);
          if (next != null) {
            focus(next);
            flyTo(next);
          }
        }} />
      ))}
    </>
  );
}

/** Screen-space map of the canvas and the visible region, drawn with rectangles. */
function Minimap({ output, width, height, places, focused, visible }: {
  output: string; width: number; height: number; places: Map<number, Place>;
  focused: number | null; visible: Place;
}) {
  const box = bounds([...places.values(), visible])!;
  const size = { width: 200, height: 128 };
  const scale = Math.min((size.width - 16) / (box.right - box.left),
                         (size.height - 16) / (box.bottom - box.top));
  const toMap = (place: Place) => ({
    x: 8 + (place.x - box.left) * scale, y: 8 + (place.y - box.top) * scale,
    width: Math.max(2, place.width * scale), height: Math.max(2, place.height * scale),
  });
  return (
    <Screen output={output} x={width - size.width - 20} y={height - size.height - 20}
            opacity={places.size > 0 ? 1 : 0} transition={settle}>
      <Rect {...size} radius={8} fill="#ffffffcc" border={{ width: 1, color: "#00000018" }}
            shadow={{ color: "#0000001f", blur: 18, y: 6 }} />
      {[...places].map(([id, place]) => (
        <Rect key={id} {...toMap(place)} radius={1.5} originX={0} originY={0} transition={glide}
              fill={id === focused ? accent : ink} opacity={id === focused ? 0.9 : 0.35} />
      ))}
      <Rect {...toMap(visible)} radius={2} originX={0} originY={0} transition={glide}
            border={{ width: 1.5, color: accent }} />
    </Screen>
  );
}
