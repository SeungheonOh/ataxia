import { Box, Rect, spring, useCamera, type OutputInfo } from "@ataxia/stage";
import { RollingText } from "../components/bar/BarText.js";
import { colors } from "../lib/theme.js";
import { useMeta } from "./MetaProvider.js";

const pillMotion = spring({ duration: 0.3, bounce: 0.1 });

/** "Canvas · 34%" on the canvas, else the room's number; clicking it leaves to the canvas. */
function Place({ output, room }: { output: OutputInfo; room: number | null }) {
  const camera = useCamera(output.name);
  const { state, enter } = useMeta();
  const number =
    room === null ? 0 : state.rooms.findIndex((candidate) => candidate.id === room) + 1;
  const zoom = Math.round((camera?.zoom ?? 1) * 100);
  return (
    <Box cursor="pointer" onPointerDown={() => enter(null, output)}>
      <RollingText identity={number}>
        {room === null ? `Canvas · ${zoom}%` : `Room ${number}`}
      </RollingText>
    </Box>
  );
}

/**
 * The bar's rooms, in the order they were made: the one this output shows a wide
 * accent pill, occupied ones darker. Clicking a pill enters its room.
 */
export function RoomPills({ output }: { output: OutputInfo }) {
  const { state, present, enteredRoom, enter } = useMeta();
  const shown = enteredRoom(output);
  const occupied = new Set([...present].map((id) => state.roomOf[id]));

  return (
    <Box flexDirection="row" alignItems="center" gap={8}>
      <Box flexDirection="row" alignItems="center">
        {state.rooms.map(({ id }) => {
          const isShown = id === shown;
          // Each pill's Box is a larger target than the pill itself.
          return (
            <Box
              key={id}
              paddingX={3}
              paddingY={12}
              cursor="pointer"
              onPointerDown={() => enter(id, output)}
            >
              <Rect
                width={isShown ? 22 : 8}
                height={8}
                radius={4}
                fill={isShown ? colors.accent : colors.ink}
                opacity={isShown ? 1 : occupied.has(id) ? 0.55 : 0.18}
                transition={pillMotion}
              />
            </Box>
          );
        })}
      </Box>
      <Place output={output} room={shown} />
    </Box>
  );
}
