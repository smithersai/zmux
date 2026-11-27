import { spawnSync } from "node:child_process"
import { join } from "node:path"
import { analyzeZigFile, emit, ROOT, walkFiles } from "./_lib.ts"

const allZigFiles = [
  ...walkFiles(join(ROOT, "src"), ".zig"),
  ...walkFiles(join(ROOT, "bench"), ".zig"),
  ...walkFiles(join(ROOT, "test"), ".zig")
]

// 1. zig fmt --check across all Zig files
const fmt = spawnSync("zig", ["fmt", "--check", ...allZigFiles], {
  cwd: ROOT,
  encoding: "utf8"
})
const unformatted = new Set(
  `${fmt.stdout ?? ""}\n${fmt.stderr ?? ""}`
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.endsWith(".zig"))
)

for (const file of allZigFiles) {
  if (unformatted.has(file)) {
    emit("zig-fmt", "fail", { item: file, note: "Run `zig fmt` to format this file" })
  } else {
    emit("zig-fmt", "pass", { item: file })
  }
}

// 2. TigerStyle function length, line length, and assertion density on src/*.zig
const srcFiles = walkFiles(join(ROOT, "src"), ".zig")
for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)
  const longest = analysis.prodFunctions.reduce(
    (best, cur) => (cur.lines > best.lines ? cur : best),
    { name: "none", startLine: 1, lines: 1 }
  )
  emit("max-fn-lines", longest.lines, {
    item: file,
    note: longest.lines > 70 ? `${longest.name} at line ${longest.startLine} (${longest.lines} lines)` : undefined
  })

  const longLine = analysis.prodLineEntries.find((entry) => entry.text.length > 120)
  if (longLine) {
    emit("line-length", "fail", {
      item: file,
      note: `line ${longLine.line}: ${longLine.text.length} chars (limit 120)`
    })
  } else {
    emit("line-length", "pass", { item: file })
  }

  const assertCount = analysis.prodLineEntries.filter((entry) =>
    /\b(?:std\.debug\.)?assert\s*\(/.test(entry.stripped)
  ).length
  const perKloc = analysis.prodLines > 0 ? Math.round((assertCount * 1000) / analysis.prodLines) : 0
  emit("assert-density", perKloc, { item: file })
}
