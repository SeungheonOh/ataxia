#!/usr/bin/env node
// Run a Stage world: ataxia-stage [--socket PATH] [--once] [--dev] WORLD.tsx
import { parseArgs } from "node:util";

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    socket: { type: "string" },
    once: { type: "boolean", default: false },
    dev: { type: "boolean", default: false },
    help: { type: "boolean", short: "h", default: false },
  },
});

if (values.help || positionals.length !== 1) {
  console.error("Usage: ataxia-stage [--socket PATH] [--once] [--dev] WORLD.tsx\n\n"
    + "  --socket PATH  Compositor socket (default: $ATAXIA_STAGE_SOCKET)\n"
    + "  --once         Load WORLD once instead of reloading it on change\n"
    + "  --dev          Use React's development build for detailed errors");
  process.exit(values.help ? 0 : 2);
}

// React selects its build when first imported, so decide before loading it.
process.env.NODE_ENV ??= values.dev ? "development" : "production";
const { run } = await import("../dist/runtime.js");
await run({ entry: positionals[0], socket: values.socket, watch: !values.once });
