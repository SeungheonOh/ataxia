import { close, launch, Shortcut } from "@ataxia/stage";
import { terminal } from "../lib/settings.js";
import { useShelf } from "./ShelfProvider.js";

/** The switcher on Super+Tab, and the keys for the open book. */
export function Keybindings() {
  const { state, dispatch, browsing } = useShelf();

  /** Opens the switcher, or moves its choice by STEP. */
  function browse(step: number) {
    if (browsing) {
      dispatch({ type: "cycle", step });
    } else {
      dispatch({ type: "spread" });
      // Backwards from the start lands on the book read longest ago.
      if (step < 0) dispatch({ type: "cycle", step: -2 });
    }
  }

  return (
    <>
      <Shortcut keys="Super+Tab" repeat onPress={() => browse(1)} />
      {/* Shift turns Tab into ISO_Left_Tab. */}
      <Shortcut keys="Super+Shift+ISO_Left_Tab" repeat onPress={() => browse(-1)} />
      {browsing && (
        <>
          <Shortcut keys="Super+Right" repeat onPress={() => browse(1)} />
          <Shortcut keys="Super+Left" repeat onPress={() => browse(-1)} />
          <Shortcut keys="Right" repeat onPress={() => browse(1)} />
          <Shortcut keys="Left" repeat onPress={() => browse(-1)} />
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
