import { readFileSync } from "node:fs"
import { join } from "node:path"
import { analyzeZigFile, emit, fileBytes, formatBytes, ROOT, walkFiles } from "./_lib.ts"

const srcFiles = walkFiles(join(ROOT, "src"), ".zig")

for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)
  emit("module-prod-lines", analysis.prodLines, { item: file })
  emit("module-bytes", formatBytes(fileBytes(file)), { item: file })
}

function extractZonDependencies(zon: string): string[] {
  const startMatch = /\.dependencies\s*=\s*\.\{/.exec(zon)
  if (!startMatch) return []
  let i = startMatch.index + startMatch[0].length
  let depth = 1
  let inString = false
  let inLineComment = false
  const bodyStart = i
  let bodyEnd = zon.length
  while (i < zon.length && depth > 0) {
    const ch = zon[i]
    const next = zon[i + 1]
    if (inLineComment) {
      if (ch === "\n") inLineComment = false
      i++
      continue
    }
    if (inString) {
      if (ch === "\\") {
        i += 2
        continue
      }
      if (ch === '"') inString = false
      i++
      continue
    }
    if (ch === "/" && next === "/") {
      inLineComment = true
      i += 2
      continue
    }
    if (ch === '"') {
      inString = true
      i++
      continue
    }
    if (ch === "{") depth++
    else if (ch === "}") {
      depth--
      if (depth === 0) {
        bodyEnd = i
        break
      }
    }
    i++
  }
  const body = zon.slice(bodyStart, bodyEnd)
  const names: string[] = []
  let d = 0
  for (const line of body.split(/\r?\n/)) {
    const code = line.replace(/\/\/.*$/, "")
    if (d === 0) {
      const m = /^\s*\.([A-Za-z_]\w*)\s*=\s*\.\{/.exec(code)
      if (m) names.push(m[1])
    }
    for (const ch of code) {
      if (ch === "{") d++
      else if (ch === "}") d = Math.max(0, d - 1)
    }
  }
  return names
}

// Tripwire: count external dependencies declared in build.zig.zon
const zon = readFileSync(join(ROOT, "build.zig.zon"), "utf8")
const depNames = extractZonDependencies(zon)
emit("zig-dependencies", depNames.length)
