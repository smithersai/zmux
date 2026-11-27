import { readFileSync } from "node:fs"
import { join } from "node:path"
import { analyzeZigFile, emit, fileBytes, formatBytes, ROOT, walkFiles } from "./_lib.ts"

const srcFiles = walkFiles(join(ROOT, "src"), ".zig")

for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)
  emit("module-prod-lines", analysis.prodLines, { item: file })
  emit("module-bytes", formatBytes(fileBytes(file)), { item: file })
}

// Tripwire: count external dependencies declared in build.zig.zon
const zon = readFileSync(join(ROOT, "build.zig.zon"), "utf8")
const depsMatch = zon.match(/\.dependencies\s*=\s*\.\{([\s\S]*?)\n\s*\},/)
const depNames = depsMatch
  ? [...depsMatch[1].matchAll(/^\s*\.([A-Za-z_]\w*)\s*=\s*\.\{/gm)].map((m) => m[1])
  : []
emit("zig-dependencies", depNames.length)
