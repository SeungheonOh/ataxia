import { useCallback, useEffect, useMemo } from "react";
import { getCamera, usePersistentState, useWindows, type Rectangle } from "@ataxia/stage";

const minimumSize = { width: 960, height: 620 };
const cascadeStep = 36;

export type PlaceWindow = (window: number, next: Partial<Rectangle>) => void;

/**
 * Where each window sits on the canvas, and a function that moves one. New
 * windows open where the camera looks, cascading so none hides another.
 */
export function usePlaces(): [ReadonlyMap<number, Rectangle>, PlaceWindow] {
  const windows = useWindows();
  const [stored, setStored] = usePersistentState<Record<number, Rectangle>>("canvas.places", {});

  const places = useMemo(() => {
    const center = getCamera() ?? { x: 0, y: 0 };
    return new Map(
      windows.map((window, index) => {
        const width = Math.max(window.width, minimumSize.width);
        const height = Math.max(window.height, minimumSize.height);
        const cascade = cascadeStep * (index % 6);
        const opening = {
          x: center.x - width / 2 + cascade,
          y: center.y - height / 2 + cascade,
          width,
          height,
        };
        return [window.id, stored[window.id] ?? opening];
      }),
    );
  }, [windows, stored]);

  // New windows keep the place they opened at.
  useEffect(() => {
    if (windows.some((window) => !stored[window.id])) setStored(Object.fromEntries(places));
  }, [places]);

  const place = useCallback<PlaceWindow>(
    (window, next) =>
      setStored((all) => ({ ...all, [window]: { ...places.get(window)!, ...next } })),
    [places, setStored],
  );

  return [places, place];
}
