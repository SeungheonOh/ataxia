import { close, launch, Shortcut } from "@ataxia/stage";
import { terminal } from "../lib/settings.js";
import { useDeck } from "./DeckProvider.js";

/** The switcher on Super+Tab, and the keys for the window in play. */
export function Keybindings() {
  const { state, dispatch, spread } = useDeck();

  /** Opens the switcher, or moves its choice by STEP. */
  function deal(step: number) {
    if (spread) {
      dispatch({ type: "cycle", step });
    } else {
      dispatch({ type: "spread" });
      // Backwards from the start lands on the card played longest ago.
      if (step < 0) dispatch({ type: "cycle", step: -2 });
    }
  }

  return (
    <>
      <Shortcut keys="Super+Tab" repeat onPress={() => deal(1)} />
      {/* Shift turns Tab into ISO_Left_Tab. */}
      <Shortcut keys="Super+Shift+ISO_Left_Tab" repeat onPress={() => deal(-1)} />
      {spread && (
        <>
          <Shortcut keys="Super+Right" repeat onPress={() => deal(1)} />
          <Shortcut keys="Super+Left" repeat onPress={() => deal(-1)} />
          <Shortcut keys="Right" repeat onPress={() => deal(1)} />
          <Shortcut keys="Left" repeat onPress={() => deal(-1)} />
          <Shortcut keys="Return" onPress={() => dispatch({ type: "fold", play: true })} />
          <Shortcut keys="Escape" onPress={() => dispatch({ type: "fold", play: false })} />
          <Shortcut keys="Super+Escape" onPress={() => dispatch({ type: "fold", play: false })} />
        </>
      )}
      <Shortcut keys="Super+Return" onPress={() => launch(terminal)} />
      <Shortcut keys="Super+Q" onPress={() => state.played !== null && close(state.played)} />
    </>
  );
}
