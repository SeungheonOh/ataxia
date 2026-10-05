import { memo, useState } from "react";
import { spring, tween, Window, type Rectangle } from "@ataxia/stage";
import { dissolve } from "../lib/effects.js";
import { colors } from "../lib/theme.js";
import type { PlaceWindow } from "./usePlaces.js";

const settle = spring({ duration: 0.3 });
const materialize = tween(0.5, "ease-out");

interface CanvasWindowProps {
  id: number;
  box: Rectangle;
  focused: boolean;
  onPlace: PlaceWindow;
}

/** A window on the canvas; it lifts while dragged and remembers where it was left. */
export const CanvasWindow = memo(function CanvasWindow({
  id,
  box,
  focused,
  onPlace,
}: CanvasWindowProps) {
  const [lifted, setLifted] = useState(false);

  return (
    <Window
      window={id}
      {...box}
      radius={10}
      tiled
      movable
      resizable
      scale={lifted ? 1.012 : 1}
      border={{ width: focused ? 2 : 1, color: focused ? colors.accent : "#00000022" }}
      shadow={{
        color: focused ? "#0000004d" : "#00000026",
        blur: lifted ? 64 : 36,
        y: lifted ? 26 : 12,
      }}
      effect={{ shader: dissolve, amount: 0, margin: 96 }}
      initial={{ scale: 0.94, effect: { amount: 1 } }}
      exit={{ scale: 0.94, effect: { amount: 1 } }}
      transition={{ default: settle, effect: materialize }}
      onDragStart={() => setLifted(true)}
      onDragEnd={({ x, y }) => {
        setLifted(false);
        onPlace(id, { x, y });
      }}
      onResizeEnd={(next) => onPlace(id, next)}
    />
  );
});
