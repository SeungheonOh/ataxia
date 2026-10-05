import { Rect, Screen, useCamera, type OutputInfo, type Rectangle } from "@ataxia/stage";
import { union } from "../lib/geometry.js";
import { colors, motion } from "../lib/theme.js";

const size = { width: 200, height: 128 };
const padding = 8;

interface MinimapProps {
  output: OutputInfo;
  places: ReadonlyMap<number, Rectangle>;
  focused: number | null;
}

/** A map of the canvas in the output's corner: every window, and what the camera shows. */
export function Minimap({ output, places, focused }: MinimapProps) {
  const camera = useCamera(output.name);
  if (!camera) return null;

  const view = {
    x: camera.x - output.width / 2 / camera.zoom,
    y: camera.y - output.height / 2 / camera.zoom,
    width: output.width / camera.zoom,
    height: output.height / camera.zoom,
  };
  const bounds = union([...places.values(), view])!;
  const scale = Math.min(
    (size.width - 2 * padding) / bounds.width,
    (size.height - 2 * padding) / bounds.height,
  );
  const toMap = (box: Rectangle) => ({
    x: padding + (box.x - bounds.x) * scale,
    y: padding + (box.y - bounds.y) * scale,
    width: Math.max(2, box.width * scale),
    height: Math.max(2, box.height * scale),
  });

  return (
    <Screen
      output={output.name}
      x={output.width - size.width - 20}
      y={output.height - size.height - 20}
      opacity={places.size > 0 ? 1 : 0}
      transition={motion.glide}
    >
      <Rect
        {...size}
        radius={8}
        fill="#ffffffcc"
        border={{ width: 1, color: "#00000018" }}
        shadow={{ color: "#0000001f", blur: 18, y: 6 }}
      />
      {[...places].map(([id, box]) => (
        <Rect
          key={id}
          {...toMap(box)}
          radius={1.5}
          fill={id === focused ? colors.accent : colors.ink}
          opacity={id === focused ? 0.9 : 0.35}
          transition={motion.glide}
        />
      ))}
      <Rect
        {...toMap(view)}
        radius={2}
        border={{ width: 1.5, color: colors.accent }}
        transition={motion.glide}
      />
    </Screen>
  );
}
