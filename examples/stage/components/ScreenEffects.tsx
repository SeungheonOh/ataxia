import type { ReactNode } from "react";
import { Group, Shortcut, tween, usePersistentState } from "@ataxia/stage";
import { crt, magnifier, warmth } from "../lib/effects.js";

const fade = { effect: tween(0.6, "ease-in-out") };

/**
 * Whole-screen effects, each on a shortcut:
 *
 *   Super+N   night light: warm colors for the evening
 *   Super+R   retro: an old CRT
 *   Super+Z   a magnifying lens under the pointer
 *
 * Each fades in and out; one that is off costs nothing, as an effect at amount 0
 * is skipped.
 */
export function ScreenEffects({ children }: { children: ReactNode }) {
  const [nightLight, setNightLight] = usePersistentState("nightLight", false);
  const [retro, setRetro] = usePersistentState("retro", false);
  const [lens, setLens] = usePersistentState("magnifier", false);
  return (
    <>
      <Shortcut keys="Super+N" onPress={() => setNightLight((on) => !on)} />
      <Shortcut keys="Super+R" onPress={() => setRetro((on) => !on)} />
      <Shortcut keys="Super+Z" onPress={() => setLens((on) => !on)} />
      <Group
        effect={{
          shader: magnifier,
          area: "output",
          pointer: true,
          amount: lens ? 1 : 0,
          uniforms: { radius: 150, zoom: 2 },
        }}
        transition={fade}
      >
        <Group effect={{ shader: crt, area: "output", amount: retro ? 1 : 0 }} transition={fade}>
          <Group
            effect={{ shader: warmth, area: "output", local: true, amount: nightLight ? 1 : 0 }}
            transition={fade}
          >
            {children}
          </Group>
        </Group>
      </Group>
    </>
  );
}
