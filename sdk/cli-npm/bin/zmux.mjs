#!/usr/bin/env node
import { fileURLToPath } from "node:url";

import { runCli } from "../lib/launcher.mjs";

const selfPath = fileURLToPath(import.meta.url);

try {
  const exitCode = await runCli(process.argv.slice(2), {
    selfRealPaths: [selfPath],
  });
  process.exit(exitCode);
} catch (err) {
  console.error(`zmux: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
}
