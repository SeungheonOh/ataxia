import { Box, Rect, spring, type OutputInfo } from "@ataxia/stage";
import { colors } from "../lib/theme.js";
import { useHypr } from "./HyprProvider.js";
import { workspaceNumbers } from "./tiling.js";

const pillMotion = spring({ duration: 0.3, bounce: 0.1 });

/** The bar's workspaces: the shown one a wide accent pill, occupied ones darker dots. */
export function WorkspacePills({ output }: { output: OutputInfo }) {
  const { state, present, workspaceOf, switchTo } = useHypr();
  const shown = workspaceOf(output);
  const occupied = new Set([...present].map((id) => state.workspaces[id]));

  return (
    <Box flexDirection="row" alignItems="center">
      {workspaceNumbers.map((number) => {
        const isShown = number === shown;
        // Each pill's Box is a larger target than the pill itself.
        return (
          <Box
            key={number}
            paddingX={3}
            paddingY={12}
            cursor="pointer"
            onPointerDown={() => switchTo(number)}
          >
            <Rect
              width={isShown ? 22 : 8}
              height={8}
              radius={4}
              fill={isShown ? colors.accent : colors.ink}
              opacity={isShown ? 1 : occupied.has(number) ? 0.55 : 0.18}
              transition={pillMotion}
            />
          </Box>
        );
      })}
    </Box>
  );
}
