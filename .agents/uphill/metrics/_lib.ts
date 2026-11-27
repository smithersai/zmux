import { appendFileSync, existsSync, readdirSync, readFileSync, statSync } from "node:fs"
import { join, relative } from "node:path"

export const ROOT = process.cwd()

export function metricsPath(): string {
  const path = process.env.UPHILL_METRICS
  if (!path) throw new Error("UPHILL_METRICS environment variable is not set")
  return path
}

export function quote(value: string): string {
  const escaped = value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r?\n/g, " ")
  return `"${escaped}"`
}

export function emit(
  metric: string,
  value: string | number,
  opts?: { item?: string; target?: string | number; note?: string }
): void {
  const parts = [metric]
  if (opts?.item !== undefined) parts.push(quote(opts.item))
  parts.push(String(value))
  if (opts?.target !== undefined) parts.push("target", String(opts.target))
  if (opts?.note !== undefined) parts.push("note", quote(opts.note))
  appendFileSync(metricsPath(), `${parts.join(" ")}\n`)
}

export function walkFiles(dir: string, ext: string): string[] {
  const out: string[] = []
  if (!existsSync(dir)) return out
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith(".") || entry.name === "node_modules" || entry.name === "zig-out") continue
    const full = join(dir, entry.name)
    if (entry.isDirectory()) {
      out.push(...walkFiles(full, ext))
    } else if (entry.name.endsWith(ext)) {
      out.push(relative(ROOT, full))
    }
  }
  return out.sort()
}

export interface ZigFnSpan {
  name: string
  startLine: number
  lines: number
}

export interface ZigAnalysis {
  totalLines: number
  prodLines: number
  prodCodeLines: string[] // 1-indexed via original line number mapping
  prodLineEntries: Array<{ line: number; text: string; stripped: string }>
  prodFunctions: ZigFnSpan[]
  testCount: number
  pubDecls: number
  documentedPubDecls: number
}

function stripZigLine(line: string): string {
  let out = ""
  let inString = false
  let inChar = false
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]
    const next = line[i + 1]
    if (!inString && !inChar && ch === "/" && next === "/") break
    if (!inChar && ch === '"' && line[i - 1] !== "\\") {
      inString = !inString
      out += " "
      continue
    }
    if (!inString && ch === "'" && line[i - 1] !== "\\") {
      inChar = !inChar
      out += " "
      continue
    }
    out += inString || inChar ? " " : ch
  }
  return out
}

export function analyzeZigFile(relPath: string): ZigAnalysis {
  const raw = readFileSync(join(ROOT, relPath), "utf8")
  const lines = raw.split(/\r?\n/)
  const prodLineEntries: Array<{ line: number; text: string; stripped: string }> = []
  const prodFunctions: ZigFnSpan[] = []
  let testCount = 0
  let pubDecls = 0
  let documentedPubDecls = 0

  let inTestBlock = false
  let testDepth = 0

  // Track function bodies at top-level or inside structs in production code
  interface OpenFn {
    name: string
    startLine: number
    depth: number
    seenOpenBrace: boolean
  }
  const fnStack: OpenFn[] = []
  let braceDepth = 0

  for (let i = 0; i < lines.length; i++) {
    const lineNo = i + 1
    const text = lines[i]
    const trimmed = text.trim()
    const stripped = stripZigLine(text)

    if (!inTestBlock && /^test\s+(".*"|\{)/.test(trimmed)) {
      testCount++
      inTestBlock = true
      testDepth = 0
      for (const ch of stripped) {
        if (ch === "{") testDepth++
        else if (ch === "}") testDepth--
      }
      if (testDepth <= 0 && stripped.includes("}")) {
        inTestBlock = false
      }
      continue
    }

    if (inTestBlock) {
      for (const ch of stripped) {
        if (ch === "{") testDepth++
        else if (ch === "}") testDepth--
      }
      if (testDepth <= 0) {
        inTestBlock = false
      }
      continue
    }

    prodLineEntries.push({ line: lineNo, text, stripped })

    // Public declaration doc-comment check (top-level pub fn / pub const)
    if (braceDepth === 0 && /^pub\s+(fn|const)\s+[A-Za-z_]\w*/.test(trimmed)) {
      pubDecls++
      let k = i - 1
      while (k >= 0 && lines[k].trim() === "") k--
      if (k >= 0 && lines[k].trim().startsWith("///")) {
        documentedPubDecls++
      }
    }

    // Detect function start (not extern/prototype)
    const fnMatch = stripped.match(/^\s*(?:pub\s+)?(?:export\s+|inline\s+)?fn\s+([A-Za-z_]\w*)\s*\(/)
    if (fnMatch && !trimmed.startsWith("extern ")) {
      fnStack.push({
        name: fnMatch[1],
        startLine: lineNo,
        depth: braceDepth,
        seenOpenBrace: false
      })
    }

    for (const ch of stripped) {
      if (ch === "{") {
        braceDepth++
        for (const open of fnStack) {
          if (!open.seenOpenBrace && braceDepth > open.depth) {
            open.seenOpenBrace = true
          }
        }
      } else if (ch === "}") {
        braceDepth = Math.max(0, braceDepth - 1)
        while (fnStack.length > 0) {
          const top = fnStack[fnStack.length - 1]
          if (top.seenOpenBrace && braceDepth <= top.depth) {
            fnStack.pop()
            prodFunctions.push({
              name: top.name,
              startLine: top.startLine,
              lines: lineNo - top.startLine + 1
            })
          } else {
            break
          }
        }
      }
    }

    // Handle function prototypes ending in ';' before '{'
    if (fnStack.length > 0) {
      const top = fnStack[fnStack.length - 1]
      if (!top.seenOpenBrace && stripped.includes(";")) {
        fnStack.pop()
      }
    }
  }

  return {
    totalLines: lines.length,
    prodLines: prodLineEntries.length,
    prodCodeLines: prodLineEntries.map((e) => e.text),
    prodLineEntries,
    prodFunctions,
    testCount,
    pubDecls,
    documentedPubDecls
  }
}

export function fileBytes(relPath: string): number {
  return statSync(join(ROOT, relPath)).size
}

export function formatBytes(bytes: number): string {
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(2)}MB`
  if (bytes >= 1_000) return `${(bytes / 1_000).toFixed(2)}kB`
  return `${bytes}B`
}
