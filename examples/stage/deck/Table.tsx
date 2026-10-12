import { Rect, Screen, useOutputs } from "@ataxia/stage";
import { useDeck } from "./DeckProvider.js";
import { paintSwirl } from "./shaders.js";

/**
 * The table under the cards: a swirl of paint. It turns only while the switcher is
 * open; closed, its clock holds and it is drawn once, so a still desktop costs nothing.
 */
export function Table() {
  const outputs = useOutputs();
  const { spread } = useDeck();
  // The swirl is opaque, so nothing need be drawn beneath it.
  return outputs.map((output) => (
    <Screen key={output.name} output={output.name}>
      <Rect
        width={output.width}
        height={output.height}
        effect={{ shader: paintSwirl, local: true, time: spread }}
      />
    </Screen>
  ));
}
