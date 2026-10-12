import { memo } from "react";
import {
  Rect,
  rotate,
  scale,
  spring,
  Text,
  translate,
  Window,
  type Animation,
  type Rectangle,
  type StagePointerEvent,
} from "@ataxia/stage";
import { font } from "../lib/theme.js";
import { placement, type Hover, type Pose } from "./layout.js";
import { cardFoil } from "./shaders.js";

const glow = spring({ duration: 0.3 });
const stock = "#f4efe3";

/** A pop and a wobble, as a card gives when picked up. */
function pop(key: string): Animation {
  return {
    transform: [
      [rotate(0), scale(1)],
      [rotate(-5), scale(1.1)],
      [rotate(3.5), scale(1.04)],
      [rotate(-1.5), scale(1.01)],
      [rotate(0), scale(1)],
    ],
    composite: "add",
    duration: 0.45,
    ease: "ease-out",
    key,
  };
}

/** Floating gently, each card at its own pace. */
function sway(index: number, lift: number): Animation {
  return {
    transform: [
      [translate(0, 0), rotate(-1.4)],
      [translate(0, -lift), rotate(1.4)],
    ],
    composite: "add",
    duration: 1.7 + (index % 4) * 0.23,
    ease: "ease-in-out",
    direction: "alternate",
    iterations: Infinity,
    key: "sway",
  };
}

interface CardProps {
  id: number;
  index: number;
  table: Rectangle;
  pose: Pose;
  /** In play the window is itself: it fills the table and takes input. */
  played: boolean;
  /** The pointer on this card, if it is there. */
  hover: Hover | null;
  /** What the card holds, shown above it while TITLED. */
  title: string;
  titled: boolean;
  /** Seconds this card waits while the deck is dealt. */
  delay: number;
  swaying: boolean;
  /** Changes each time the card should pop. */
  popKey: string | null;
  onHover: (hover: Hover | null) => void;
  onPick: () => void;
}

/**
 * A window as a playing card: scaled down, turned and leaning toward the pointer,
 * framed in card stock. Its client keeps the table's size, so nothing reflows as
 * it comes in and out of play.
 */
export const Card = memo(function Card({
  id,
  index,
  table,
  pose,
  played,
  hover,
  title,
  titled,
  delay,
  swaying,
  popKey,
  onHover,
  onPick,
}: CardProps) {
  // Sizes in the window's own units, which the card's scale shrinks.
  const unit = 1 / pose.scale;
  const motion = spring({ duration: 0.45, bounce: 0.22, delay });
  const animations = [
    ...(popKey ? [pop(popKey)] : []),
    ...(swaying ? [sway(index, 6 * unit)] : []),
  ];

  function lean({ localX, localY }: StagePointerEvent) {
    onHover({ window: id, x: localX / table.width - 0.5, y: localY / table.height - 0.5 });
  }

  return (
    <Window
      window={id}
      {...placement(pose, table)}
      width={table.width}
      height={table.height}
      tiled
      focusable={played}
      radius={played ? 14 : 9 * unit}
      border={{ width: played ? 2 : 5 * unit, color: stock }}
      shadow={{ color: "#0000006b", blur: (played ? 30 : 6) * unit, y: (played ? 10 : 7) * unit }}
      effect={{
        shader: cardFoil,
        amount: hover ? 1 : 0,
        margin: 40 * unit,
        local: true,
        uniforms: { light: [hover?.x ?? 0, hover?.y ?? 0], burn: 0 },
      }}
      initial={{
        y: table.y + table.height * 1.6,
        transform: placement({ ...pose, scale: 0.12, rotation: -14 }, table).transform,
      }}
      exit={{ effect: { amount: 1, uniforms: { burn: 1 } } }}
      transition={{ default: motion, effect: glow }}
      animate={animations}
    >
      {!played && (
        <Rect
          width={table.width}
          height={table.height}
          cursor="pointer"
          onPointerMove={lean}
          onPointerLeave={() => onHover(null)}
          onPointerDown={onPick}
        />
      )}
      {!played && (
        <Text
          x={0}
          y={-30 * unit}
          width={table.width}
          align="center"
          font={font}
          size={15 * unit}
          weight={700}
          color={stock}
          opacity={titled ? 1 : 0}
        >
          {title}
        </Text>
      )}
    </Window>
  );
});
