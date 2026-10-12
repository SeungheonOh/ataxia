/**
 * Where each card lies. Every window keeps the size of the table, so its client
 * never resizes; a card is the window scaled down and turned. All poses use the
 * same transform functions, so any change between them animates.
 */

import {
  perspective,
  rotate,
  rotateX,
  rotateY,
  scale,
  type Rectangle,
  type Transform,
} from "@ataxia/stage";

/** A card's center, size relative to the table, turn and tilt, in degrees. */
export interface Pose {
  x: number;
  y: number;
  scale: number;
  rotation: number;
  tiltX: number;
  tiltY: number;
}

/** Where the pointer is on a hovered card, from -0.5 to 0.5 across it. */
export interface Hover {
  window: number;
  x: number;
  y: number;
}

/** How far a hovered card leans toward the pointer. */
const lean = 22;

/** The table: the work area, less a strip at the bottom where the hand lies. */
export function tableBox(area: Rectangle, handHeight: number): Rectangle {
  const margin = 18;
  return {
    x: area.x + margin,
    y: area.y + margin,
    width: area.width - 2 * margin,
    height: area.height - handHeight - 2 * margin,
  };
}

export function playPose(table: Rectangle): Pose {
  return {
    x: table.x + table.width / 2,
    y: table.y + table.height / 2,
    scale: 1,
    rotation: 0,
    tiltX: 0,
    tiltY: 0,
  };
}

/** The card's lean toward a pointer at HOVER: the side under it presses away. */
function leaning(pose: Pose, hover: Hover | null): Pose {
  return hover ? { ...pose, tiltX: -hover.y * lean, tiltY: hover.x * lean } : pose;
}

interface Fan {
  count: number;
  /** Card width on screen. */
  width: number;
  /** The fan's center: the middle card's center. */
  x: number;
  y: number;
  /** Degrees between neighbours, and how far the ends dip. */
  spread: number;
  dip: number;
}

function fanPose(fan: Fan, index: number, table: Rectangle): Pose {
  const offset = index - (fan.count - 1) / 2;
  const step = Math.min(
    fan.width * 0.72,
    (table.width * 0.86 - fan.width) / Math.max(1, fan.count - 1),
  );
  return {
    x: fan.x + offset * step,
    y: fan.y + offset * offset * fan.dip,
    scale: fan.width / table.width,
    rotation: offset * fan.spread,
    tiltX: 0,
    tiltY: 0,
  };
}

/** A card in the hand, peeking up from the bottom edge; hovered, it rises whole. */
export function handPose(
  index: number,
  count: number,
  area: Rectangle,
  table: Rectangle,
  hover: Hover | null,
): Pose {
  const width = Math.min(260, area.width / 6);
  const height = (width * table.height) / table.width;
  const bottom = area.y + area.height;
  const pose = fanPose(
    { count, width, x: area.x + area.width / 2, y: bottom - height * 0.3, spread: 4, dip: 3 },
    index,
    table,
  );
  if (!hover) return pose;
  return leaning(
    { ...pose, y: bottom - height * 0.62, scale: pose.scale * 1.1, rotation: 0 },
    hover,
  );
}

/** A card of the open switcher, fanned across the middle; the chosen one stands up. */
export function spreadPose(
  index: number,
  count: number,
  area: Rectangle,
  table: Rectangle,
  chosen: boolean,
  hover: Hover | null,
): Pose {
  const width = Math.min(360, (area.width * 0.8) / Math.max(1, count * 0.75));
  const pose = fanPose(
    { count, width, x: area.x + area.width / 2, y: area.y + area.height * 0.55, spread: 5, dip: 6 },
    index,
    table,
  );
  if (!chosen) return pose;
  const height = (width * table.height) / table.width;
  return leaning(
    { ...pose, y: pose.y - height * 0.22, scale: pose.scale * 1.14, rotation: pose.rotation / 3 },
    hover,
  );
}

/** POSE as a window's position and transform, its table-sized box centered there. */
export function placement(
  pose: Pose,
  table: Rectangle,
): { x: number; y: number; transform: Transform } {
  return {
    x: pose.x - table.width / 2,
    y: pose.y - table.height / 2,
    transform: [
      perspective(1100),
      rotateX(pose.tiltX),
      rotateY(pose.tiltY),
      rotate(pose.rotation),
      scale(pose.scale),
    ],
  };
}
