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

for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)
  const stem = basename(file, ".zig")

  emit("unit-tests", analysis.testCount, { item: file })

  if (stem !== "main") {
    const fuzzName = FUZZ_ALIAS[stem] ?? stem
    const hasFuzz = fuzzFiles.has(fuzzName)
    emit("fuzz-coverage", hasFuzz ? "pass" : "fail", {
      item: file,
      note: hasFuzz ? undefined : `missing fuzz harness test/fuzz/${stem}.zig`
    })

    const hasBench = benchSuites.has(stem) && existsSync(join(ROOT, `bench/${stem}_bench.zig`))
    emit("bench-coverage", hasBench ? "pass" : "fail", {
      item: file,
      note: hasBench ? undefined : `missing benchmark bench/${stem}_bench.zig or bench/baseline.json suite`
    })
  }
}
