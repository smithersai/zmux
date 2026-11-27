import { existsSync, readFileSync } from "node:fs"
import { basename, join } from "node:path"
import { analyzeZigFile, emit, ROOT, walkFiles } from "./_lib.ts"

const srcFiles = walkFiles(join(ROOT, "src"), ".zig")
const fuzzFiles = new Set(walkFiles(join(ROOT, "test/fuzz"), ".zig").map((f) => basename(f, ".zig")))
const benchBaseline = JSON.parse(readFileSync(join(ROOT, "bench/baseline.json"), "utf8")) as {
  benchmarks: Array<{ suite: string; name: string }>
}
const benchSuites = new Set(benchBaseline.benchmarks.map((b) => b.suite))

// Map module stem to its fuzz harness name when combined
const FUZZ_ALIAS: Record<string, string> = {
  daemon: "daemon_sys",
  sys: "daemon_sys",
  rpc_line_reader: "line_reader"
}

// Group src/<module>.zig and any internal src/<module>/*.zig files under the
// owning subsystem so splitting monolithic modules into submodules preserves
// subsystem-level unit test totals, fuzz harnesses, and benchmark suites while
// footprint, style, correctness, and documentation still audit every file.
const bySubsystem = new Map<string, string[]>()
for (const file of srcFiles) {
  const parts = file.split("/")
  const subsystem = parts[1].replace(/\.zig$/, "")
  const list = bySubsystem.get(subsystem) ?? []
  list.push(file)
  bySubsystem.set(subsystem, list)
}

for (const [stem, files] of [...bySubsystem.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
  const itemLabel = `src/${stem}.zig`
  let totalTests = 0
  for (const file of files) {
    totalTests += analyzeZigFile(file).testCount
  }
  emit("unit-tests", totalTests, { item: itemLabel })

  if (stem !== "main") {
    const fuzzName = FUZZ_ALIAS[stem] ?? stem
    const hasFuzz = fuzzFiles.has(fuzzName)
    emit("fuzz-coverage", hasFuzz ? "pass" : "fail", {
      item: itemLabel,
      note: hasFuzz ? undefined : `missing fuzz harness test/fuzz/${stem}.zig`
    })

    const hasBench = benchSuites.has(stem) && existsSync(join(ROOT, `bench/${stem}_bench.zig`))
    emit("bench-coverage", hasBench ? "pass" : "fail", {
      item: itemLabel,
      note: hasBench ? undefined : `missing benchmark bench/${stem}_bench.zig or bench/baseline.json suite`
    })
  }
}
