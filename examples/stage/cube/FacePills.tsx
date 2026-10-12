import { Box, Rect, spring } from "@ataxia/stage";
import { colors } from "../lib/theme.js";
import { useCube } from "./CubeProvider.js";
import { faces } from "./state.js";

const pillMotion = spring({ duration: 0.3, bounce: 0.1 });

/** The bar's faces: the one in front a wide accent pill, occupied ones darker dots. */
export function FacePills() {
  const { state, front, dispatch } = useCube();
  const occupied = new Set(Object.values(state.faceOf));
  return (
    <Box flexDirection="row" alignItems="center">
      {Array.from({ length: faces }, (_, face) => (
        // Each pill's Box is a larger target than the pill itself.
        <Box
          key={face}
          paddingX={3}
          paddingY={12}
          cursor="pointer"
          onPointerDown={() => dispatch({ type: "show", face })}
        >
          <Rect
            width={face === front ? 22 : 8}
            height={8}
            radius={4}
            fill={face === front ? colors.accent : colors.ink}
            opacity={face === front ? 1 : occupied.has(face) ? 0.55 : 0.18}
            transition={pillMotion}
          />
        </Box>
      ))}
    </Box>
  );
}
