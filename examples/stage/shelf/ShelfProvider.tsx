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
// One window in play, the rest in a row, and the order they were played for the
// switcher: the deck's bookkeeping is the shelf's too.
import { deckReducer, initialDeckState, type DeckAction, type DeckState } from "../deck/state.js";
import { shelfLayout, type Shelf } from "./layout.js";

export interface ShelfContextValue {
  /** `played` is the open book, `hand` the shelf left to right. */
  state: DeckState;
  dispatch: (action: DeckAction) => void;
  output: OutputInfo | undefined;
  area: Rectangle;
  shelf: Shelf;
  /** Whether the switcher is open. */
  browsing: boolean;
  /** The book under the pointer. */
  hovered: number | null;
  setHovered: (window: number | null) => void;
}

const ShelfContext = createContext<ShelfContextValue | null>(null);

export function useShelf(): ShelfContextValue {
  const value = useContext(ShelfContext);
  if (!value) throw new Error("useShelf must be used inside <ShelfProvider>.");
  return value;
}

const fallbackArea = { x: 0, y: 0, width: 1280, height: 800 };

/** Owns the shelf's state and shares it, with the switcher's behaviour, through `useShelf`. */
export function ShelfProvider({ children }: { children: ReactNode }) {
  const windows = useWindowIds();
  const outputs = useOutputs();
  const focused = useFocusedWindow();
  const modifiers = useModifiers();
  const [state, dispatch] = usePersistentReducer("shelf", deckReducer, initialDeckState);
  const [hovered, setHovered] = useState<number | null>(null);

  const output = outputs[0];
  const area = output?.workArea ?? fallbackArea;
  const shelf = useMemo(() => shelfLayout(area), [area]);
  const browsing = state.selected !== null;

  useEffect(() => {
    dispatch({ type: "sync", windows });
  }, [windows]);

  // The open book has the keyboard; one that takes focus itself comes off the shelf.
  useEffect(() => {
    if (state.played !== null && state.played !== focused) focus(state.played);
  }, [state.played]);
  useEffect(() => {
    if (focused !== null && focused !== state.played) dispatch({ type: "play", window: focused });
  }, [focused]);

  // Letting go of Super opens the switcher's choice, as letting go of Alt does.
  const holding = modifiers.includes("logo");
  useEffect(() => {
    if (browsing && !holding) dispatch({ type: "fold", play: true });
  }, [holding]);

  const value = useMemo(
    () => ({ state, dispatch, output, area, shelf, browsing, hovered, setHovered }),
    [state, output, area, shelf, browsing, hovered],
  );
  return <ShelfContext.Provider value={value}>{children}</ShelfContext.Provider>;
}
