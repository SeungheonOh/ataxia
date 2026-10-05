import {
  focus,
  spring,
  tween,
  Window,
  type Rectangle,
  type StageDragEvent,
  type StageResizeEvent,
} from "@ataxia/stage";
import { bump } from "../lib/animations.js";
import { dissolve } from "../lib/effects.js";
import { useHypr } from "./HyprProvider.js";

export const windowMotion = spring({ duration: 0.38, bounce: 0.12 });

// The focused border turns once as focus arrives; a forever loop would keep the display awake.
const borderTurn = tween(1.2, "ease-out");
// Windows burn in as they open and away as they close; at rest the effect is skipped.
const materialize = tween(0.5, "ease-out");
const activeBorder = { from: "#33ccff", to: "#00ff99", angle: 360 };
const inactiveBorder = { from: "#59595988", to: "#59595988", angle: 0 };

interface HyprWindowProps {
  id: number;
  box: Rectangle;
  floating: boolean;
  /** Where a native drag left the window, in its workspace's coordinates. */
  onDrop?: (event: StageDragEvent) => void;
  onResize?: (event: StageResizeEvent) => void;
}

/** A tiled or floating window with a gradient border; focus follows the mouse. */
export function HyprWindow({ id, box, floating, onDrop, onResize }: HyprWindowProps) {
  const { focused, dispatch, bumped, reveal } = useHypr();
  const isFocused = id === focused;

  return (
    <Window
      window={id}
      {...box}
      radius={10}
      tiled={!floating}
      movable
      resizable={floating}
      dim={isFocused ? 0 : 0.12}
      border={{ width: 2, color: isFocused ? activeBorder : inactiveBorder }}
      shadow={{ color: floating ? "#000000aa" : "#00000055", blur: floating ? 36 : 18, y: 6 }}
      effect={{ shader: dissolve, amount: 0, margin: 48 }}
      initial={{ scale: 0.94, border: { color: { angle: 0 } }, effect: { amount: 1 } }}
      exit={{ scale: 0.94, effect: { amount: 1 } }}
      transition={{ default: windowMotion, borderAngle: borderTurn, effect: materialize }}
      animate={bumped?.window === id ? bump(bumped.direction, bumped.count) : null}
      onPointerEnter={() => focus(id)}
      onDragEnd={onDrop}
      onResizeEnd={onResize}
      onFullscreenRequest={({ value }) =>
        dispatch({ type: "fullscreen", window: value ? id : null })
      }
      // A client asking to be shown, e.g. for a link it opened, brings its workspace along.
      onActivateRequest={() => reveal(id)}
    />
  );
}
