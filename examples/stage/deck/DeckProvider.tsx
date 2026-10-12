import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import {
  focus,
  useFocusedWindow,
  useModifiers,
  useOutputs,
  usePersistentReducer,
  useWindowIds,
  type OutputInfo,
  type Rectangle,
} from "@ataxia/stage";
import { tableBox, type Hover } from "./layout.js";
import { deckReducer, initialDeckState, type DeckAction, type DeckState } from "./state.js";

/** How long a deal staggers the cards, in seconds. */
const dealTime = 0.6;

export interface DeckContextValue {
  state: DeckState;
  dispatch: (action: DeckAction) => void;
  /** The output the deck is dealt on, its work area and the table on it. */
  output: OutputInfo | undefined;
  area: Rectangle;
  table: Rectangle;
  /** Whether the switcher is open. */
  spread: boolean;
  /** The card under the pointer, and where on it. */
  hover: Hover | null;
  setHover: (hover: Hover | null) => void;
  /** Counts each new hover and choice, so the card they land on pops once. */
  pops: number;
  /** True for a moment after the switcher opens or closes, while cards are dealt in turn. */
  dealing: boolean;
}

const DeckContext = createContext<DeckContextValue | null>(null);

export function useDeck(): DeckContextValue {
  const value = useContext(DeckContext);
  if (!value) throw new Error("useDeck must be used inside <DeckProvider>.");
  return value;
}

const fallbackArea = { x: 0, y: 0, width: 1280, height: 800 };

/** Owns the deck's state and shares it, with the switcher's behaviour, through `useDeck`. */
export function DeckProvider({ children }: { children: ReactNode }) {
  const windows = useWindowIds();
  const outputs = useOutputs();
  const focused = useFocusedWindow();
  const modifiers = useModifiers();
  const [state, dispatch] = usePersistentReducer("deck", deckReducer, initialDeckState);
  const [hover, setHover] = useState<Hover | null>(null);
  const [pops, setPops] = useState(0);
  const [dealing, setDealing] = useState(false);

  const output = outputs[0];
  const area = output?.workArea ?? fallbackArea;
  const table = useMemo(() => tableBox(area, Math.min(170, area.height * 0.2)), [area]);
  const spread = state.selected !== null;

  useEffect(() => {
    dispatch({ type: "sync", windows });
  }, [windows]);

  // The window in play has the keyboard; one that takes focus itself comes into play.
  useEffect(() => {
    if (state.played !== null) focus(state.played);
  }, [state.played]);
  useEffect(() => {
    if (focused !== null && focused !== state.played) dispatch({ type: "play", window: focused });
  }, [focused]);

  // Letting go of Super plays the switcher's choice, as letting go of Alt does.
  const holding = modifiers.includes("logo");
  useEffect(() => {
    if (spread && !holding) dispatch({ type: "fold", play: true });
  }, [holding]);

  // Cards deal one after another as the switcher opens or closes, then follow at once.
  useEffect(() => {
    setDealing(true);
    const timer = setTimeout(() => setDealing(false), dealTime * 1000);
    return () => clearTimeout(timer);
  }, [spread]);

  const hovered = hover?.window ?? null;
  useEffect(() => setPops((count) => count + 1), [hovered, state.selected]);

  const value = useMemo(
    () => ({ state, dispatch, output, area, table, spread, hover, setHover, pops, dealing }),
    [state, output, area, table, spread, hover, setHover, pops, dealing],
  );
  return <DeckContext.Provider value={value}>{children}</DeckContext.Provider>;
}
