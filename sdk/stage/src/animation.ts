// Keyframe animations, played by the compositor over a node's props.
//
// Each animated prop becomes one track on one wire property. Keyframes given
// as a function of progress, and easing functions, are sampled here, so the
// compositor only ever interpolates numbers and colors on its own clock.

import { type Color, toWireColor } from "./color.js";
import { type Easing, resolveEasing, sampleCount } from "./motion.js";
import type { WireValue } from "./protocol.js";

/** The props keyframes can drive, and the value each keyframe takes. */
export interface AnimatableValues {
  x: number;
  y: number;
  width: number;
  height: number;
  scale: number;
  /** Degrees. */
  rotation: number;
  opacity: number;
  radius: number;
  blur: number;
  dim: number;
  /** A solid fill. */
  fill: Color;
  /** Text color. */
  color: Color;
  borderWidth: number;
  borderColor: Color;
  /** Degrees. */
  borderAngle: number;
  /** Degrees. */
  fillAngle: number;
  shadowColor: Color;
  shadowBlur: number;
  shadowX: number;
  shadowY: number;
  shadowSpread: number;
  /** The strength of the node's effect. */
  effectAmount: number;
}

/** Values at evenly spaced (or `offsets`) points of an iteration, or a function of its progress. */
export type Keyframes<V> = readonly V[] | ((progress: number) => V);

/** When and how keyframes play, as in the Web Animations API. */
export interface AnimationTiming {
  /** Seconds per iteration; 0.5 by default. */
  duration?: number;
  /** Seconds before the first iteration, during which the prop keeps its own value. */
  delay?: number;
  /** Shapes each iteration's progress. */
  ease?: Easing;
  /** How many times it plays, or Infinity; 1 by default. */
  iterations?: number;
  direction?: "normal" | "reverse" | "alternate" | "alternate-reverse";
  /** "add" adds the keyframes to the prop's own value, e.g. to shake it; "replace" by default. */
  composite?: "replace" | "add";
  /** Where each keyframe sits in an iteration, rising from 0 to 1. */
  offsets?: readonly number[];
  /**
   * The animation's identity. An animation keeps running across renders while it
   * stays the same and starts over when it changes; a new key replays it.
   */
  key?: string | number;
}

/**
 * Keyframes for one or more props with their timing:
 * `{ x: [0, -8, 8, 0], composite: "add", duration: 0.3 }`. Finished animations
 * leave the prop at its own value.
 */
export type Animation = AnimationTiming & {
  [K in keyof AnimatableValues]?: Keyframes<AnimatableValues[K]>;
};

const degrees = Math.PI / 180;
const number = (value: number): WireValue => value;
const angle = (value: number): WireValue => value * degrees;
const color = (value: Color): WireValue => toWireColor(value);

/** Wire property and keyframe conversion of each animatable prop. */
const tracks: { [K in keyof AnimatableValues]: [string, (value: never) => WireValue] } = {
  x: ["x", number], y: ["y", number], width: ["width", number], height: ["height", number],
  scale: ["scale", number], rotation: ["rotation", angle], opacity: ["opacity", number],
  radius: ["radius", number], blur: ["blur", number], dim: ["dim", number],
  fill: ["color", color], color: ["color", color],
  borderWidth: ["borderWidth", number], borderColor: ["borderColor", color],
  borderAngle: ["borderAngle", angle], fillAngle: ["fillAngle", angle],
  shadowColor: ["shadowColor", color], shadowBlur: ["shadowBlur", number],
  shadowX: ["shadowX", number], shadowY: ["shadowY", number],
  shadowSpread: ["shadowSpread", number], effectAmount: ["amount", number],
};

function lerp(from: WireValue, to: WireValue, fraction: number): WireValue {
  if (Array.isArray(from) && Array.isArray(to)) {
    return from.map((low, index) => lerp(low, to[index]!, fraction));
  }
  return (from as number) + ((to as number) - (from as number)) * fraction;
}

/** KEYFRAMES at PROGRESS, extrapolating past the ends as the compositor does. */
function interpolate(keyframes: WireValue[], offsets: readonly number[], progress: number): WireValue {
  let index = offsets.findIndex((offset, position) => position > 0 && offset > progress);
  if (index < 0) index = offsets.length - 1;
  const span = offsets[index]! - offsets[index - 1]!;
  return lerp(keyframes[index - 1]!, keyframes[index]!,
              span > 0 ? (progress - offsets[index - 1]!) / span : 1);
}

function evenly(count: number): number[] {
  return Array.from({ length: count }, (_, index) => index / (count - 1));
}

/** FNV-1a: a short, stable id for an animation's content. */
function hash(text: string): string {
  let value = 0x811c9dc5;
  for (let index = 0; index < text.length; index++) {
    value = Math.imul(value ^ text.charCodeAt(index), 0x01000193);
  }
  return (value >>> 0).toString(36);
}

function wireTrack(property: keyof AnimatableValues, frames: Keyframes<never>, timing: AnimationTiming) {
  const [name, convert] = tracks[property];
  const duration = timing.duration ?? 0.5;
  let keyframes = typeof frames === "function"
    ? evenly(Math.min(256, Math.max(8, Math.ceil(duration * 60)) + 1)).map((progress) => convert(frames(progress)))
    : frames.map(convert);
  let offsets: readonly number[] | undefined = timing.offsets;
  let ease = resolveEasing(timing.ease ?? "linear");
  // An easing function is applied here, by resampling the keyframes evenly in time.
  if (typeof ease === "function") {
    const shaped = ease;
    const at = offsets ?? evenly(keyframes.length);
    const source = keyframes;
    keyframes = evenly(sampleCount(duration) + 1).map((time) => interpolate(source, at, shaped(time)));
    offsets = undefined;
    ease = null;
  }
  const track: Record<string, WireValue> = { property: name, keyframes, duration };
  if (offsets) track.offsets = [...offsets];
  if (ease) track.ease = ease;
  if (timing.delay) track.delay = timing.delay;
  if (timing.iterations !== undefined && timing.iterations !== 1) {
    track.iterations = timing.iterations === Infinity ? "forever" : timing.iterations;
  }
  if (timing.direction && timing.direction !== "normal") track.direction = timing.direction;
  if (timing.composite === "add") track.composite = "add";
  track.id = timing.key === undefined ? hash(JSON.stringify(track)) : `${timing.key}/${name}`;
  return track;
}

/** The wire tracks of ANIMATE, one per animated prop. */
export function wireAnimations(animate: Animation | readonly Animation[]): WireValue[] {
  const list = Array.isArray(animate) ? animate as readonly Animation[] : [animate as Animation];
  return list.flatMap((animation) =>
    (Object.keys(tracks) as (keyof AnimatableValues)[])
      .filter((property) => animation[property] !== undefined)
      .map((property) => wireTrack(property, animation[property] as Keyframes<never>, animation)));
}
