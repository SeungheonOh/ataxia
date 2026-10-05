// Transition descriptions. The compositor runs them on its own frame clock,
// so a prop change costs one message no matter how long it animates.

export type CubicBezier = [number, number, number, number];
export type Easing = "linear" | "ease" | "ease-in" | "ease-out" | "ease-in-out" | CubicBezier;

export type Motion =
  | { type: "spring"; stiffness: number; damping: number; mass: number; delay?: number }
  | { type: "tween"; duration: number; ease: CubicBezier | null; delay?: number;
      repeat?: number | "forever" }
  | { type: "instant" };

export interface SpringOptions {
  /** Physical parameters; defaults match react-spring's "default" preset. */
  stiffness?: number;
  damping?: number;
  mass?: number;
  /** Perceptual alternative: settle time in seconds and bounce in -1..1. */
  duration?: number;
  bounce?: number;
  /** Seconds to hold the starting value first, e.g. to stagger a list. */
  delay?: number;
}

export interface TweenOptions {
  delay?: number;
  /** Extra runs after the first, or Infinity to loop forever (e.g. a spinning border). */
  repeat?: number;
}

const easings: Record<Exclude<Easing, CubicBezier>, CubicBezier | null> = {
  linear: null,
  ease: [0.25, 0.1, 0.25, 1],
  "ease-in": [0.42, 0, 1, 1],
  "ease-out": [0, 0, 0.58, 1],
  "ease-in-out": [0.42, 0, 0.58, 1],
};

export const instant: Motion = { type: "instant" };

export function spring(options: SpringOptions = {}): Motion {
  const mass = options.mass ?? 1;
  if (options.duration !== undefined) {
    // SwiftUI's mapping from duration and bounce to a unit-mass spring.
    const duration = Math.max(options.duration, 0.01);
    const bounce = Math.min(Math.max(options.bounce ?? 0, -0.99), 0.99);
    const stiffness = (2 * Math.PI / duration) ** 2 * mass;
    const damping = bounce >= 0
      ? 4 * Math.PI * (1 - bounce) * mass / duration
      : 4 * Math.PI * mass / (duration * (1 + bounce));
    return { type: "spring", stiffness, damping, mass, delay: options.delay };
  }
  return { type: "spring", stiffness: options.stiffness ?? 170, damping: options.damping ?? 26, mass,
           delay: options.delay };
}

/** Time-based transition; DURATION is in seconds. */
export function tween(duration: number, ease: Easing = "ease", options: TweenOptions = {}): Motion {
  // A zero-length tween is a jump; the compositor accepts only positive durations.
  if (!(duration > 0)) return instant;
  const repeat = options.repeat === Infinity ? "forever" : options.repeat;
  return { type: "tween", duration, ease: typeof ease === "string" ? easings[ease] : ease,
           delay: options.delay, repeat };
}

export function isMotion(value: unknown): value is Motion {
  return typeof value === "object" && value !== null && "type" in value;
}
