import { useWindows } from "@ataxia/stage";
import { Card } from "./Card.js";
import { useDeck } from "./DeckProvider.js";
import { handPose, playPose, spreadPose, type Pose } from "./layout.js";

/** Seconds between cards as they are dealt. */
const dealStep = 0.04;

/**
 * Every window as a card: the one in play fills the table, the others lie in a
 * fan along the bottom. With the switcher open they all fan out across the
 * middle, most recently played first, and the chosen one stands up.
 */
export function Cards() {
  const { state, dispatch, area, table, spread, hover, setHover, pops, dealing } = useDeck();
  const windows = useWindows();
  const titles = new Map(windows.map((window) => [window.id, window.title || window.appId]));
  const hoverOn = (id: number) => (hover?.window === id ? hover : null);

  const poses = new Map<number, Pose>();
  if (spread) {
    state.recent.forEach((id, index) =>
      poses.set(
        id,
        spreadPose(index, state.recent.length, area, table, id === state.selected, hoverOn(id)),
      ),
    );
  } else {
    if (state.played !== null) poses.set(state.played, playPose(table));
    state.hand.forEach((id, index) =>
      poses.set(id, handPose(index, state.hand.length, area, table, hoverOn(id))),
    );
  }

  // Paint order: the window in play under the hand, the lifted card over its neighbours.
  const lifted = spread ? state.selected : (hover?.window ?? null);
  const order = [...poses.keys()].sort((a, b) => Number(a === lifted) - Number(b === lifted));

  function pick(id: number) {
    if (spread) {
      dispatch({ type: "choose", window: id });
      dispatch({ type: "fold", play: true });
    } else {
      dispatch({ type: "play", window: id });
    }
    setHover(null);
  }

  return order.map((id) => {
    const chosen = spread && id === state.selected;
    const index = spread ? state.recent.indexOf(id) : state.hand.indexOf(id);
    return (
      <Card
        key={id}
        id={id}
        index={index}
        table={table}
        pose={poses.get(id)!}
        played={!spread && id === state.played}
        hover={hoverOn(id)}
        title={titles.get(id) ?? ""}
        titled={chosen || hoverOn(id) !== null}
        delay={dealing ? Math.max(0, index) * dealStep : 0}
        swaying={spread}
        popKey={chosen ? `chosen-${pops}` : hoverOn(id) ? `hover-${pops}` : null}
        onHover={(next) => {
          setHover(next);
          if (next && spread && next.window !== state.selected)
            dispatch({ type: "choose", window: id });
        }}
        onPick={() => pick(id)}
      />
    );
  });
}
