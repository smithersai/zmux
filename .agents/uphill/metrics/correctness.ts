import { join } from "node:path"
import { analyzeZigFile, emit, ROOT, walkFiles } from "./_lib.ts"

const srcFiles = walkFiles(join(ROOT, "src"), ".zig")

for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)

  const panicHit = analysis.prodLineEntries.find((e) =>
    /\B@panic\s*\(|\bcatch\s+unreachable\b|\bunreachable\b/.test(e.stripped)
  )
  emit("no-panic", panicHit ? "fail" : "pass", {
    item: file,
    note: panicHit ? `line ${panicHit.line}: panic or unreachable in production code` : undefined
  })

  const todoHit = analysis.prodLineEntries.find((e) => /\b(TODO|FIXME|XXX|HACK)\b/.test(e.text))
  emit("no-todo", todoHit ? "fail" : "pass", {
    item: file,
    note: todoHit ? `line ${todoHit.line}: unresolved TODO/FIXME marker` : undefined
  })

  const debugPrintHit = analysis.prodLineEntries.find((e) => /\bstd\.debug\.print\s*\(/.test(e.stripped))
  emit("no-debug-print", debugPrintHit ? "fail" : "pass", {
    item: file,
    note: debugPrintHit ? `line ${debugPrintHit.line}: std.debug.print in production code` : undefined
  })

  const swallowHit = analysis.prodLineEntries.find((e) => /\bcatch\s*\{\s*\}/.test(e.stripped))
  emit("no-empty-catch", swallowHit ? "fail" : "pass", {
    item: file,
    note: swallowHit ? `line ${swallowHit.line}: silent \`catch {}\` swallows errors` : undefined
  })
}
