/**
 * Deck: windows as a hand of cards, after Balatro.
 *
 *   Super+Tab, Super+Shift+Tab    deal the switcher out and move along it; let go of Super to play
 *   Left / Right, Return, Escape  move along the open switcher, play, or put it away
 *   Click a card                  play it; the window in play takes its place in the hand
 *   Super+Return / Super+Q        terminal / close the window in play
 *   Super+D                       application launcher
 *
 * The window in play fills the table and takes input. The rest lie in a fan at
 * the bottom; a card rises, pops and leans toward the pointer under it, and its
 * foil catches the light. Opening the switcher deals every card across a swirl
 * of paint, gently floating, most recently played first. Every window keeps the
 * table's size, so clients never resize as they come and go; a card is only the
 * window, live, scaled and turned in 3D. Closed windows burn away.
 */

import { Desktop } from "./components/Desktop.js";
import { Launcher } from "./components/Launcher.js";
import { ScreenEffects } from "./components/ScreenEffects.js";
import { Cards } from "./deck/Cards.js";
import { DeckProvider, useDeck } from "./deck/DeckProvider.js";
import { HandLabel } from "./deck/HandLabel.js";
import { Keybindings } from "./deck/Keybindings.js";
import { Table } from "./deck/Table.js";

function DeckLauncher() {
  const { output } = useDeck();
  return <Launcher output={output} />;
}

export default function Deck() {
  return (
    <ScreenEffects>
      <DeckProvider>
        <Table />
        <Cards />
        <Desktop barStart={HandLabel} />
        <DeckLauncher />
        <Keybindings />
      </DeckProvider>
    </ScreenEffects>
  );
}
