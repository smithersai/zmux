import { existsSync, readFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import { analyzeZigFile, emit, ROOT, walkFiles } from "./_lib.ts"

const srcFiles = walkFiles(join(ROOT, "src"), ".zig")
for (const file of srcFiles) {
  const analysis = analyzeZigFile(file)
  if (analysis.pubDecls === 0) continue
  const pct = Math.round((analysis.documentedPubDecls * 100) / analysis.pubDecls)
  emit("pub-doc-coverage", pct, {
    item: file,
    note: pct < 90 ? `${analysis.documentedPubDecls}/${analysis.pubDecls} pub decls have /// doc comments` : undefined
  })
}

const mdFiles = ["README.md", "CHANGELOG.md", "AGENTS.md"].filter((f) => existsSync(join(ROOT, f)))
for (const md of mdFiles) {
  const content = readFileSync(join(ROOT, md), "utf8")
  const links = [...content.matchAll(/\[[^\]]+\]\(([^)#]+)(?:#[^)]+)?\)/g)]
  let broken: string | undefined
  for (const match of links) {
    const target = match[1].trim()
    if (!target || /^(https?:|mailto:|#)/.test(target)) continue
    const resolved = resolve(dirname(join(ROOT, md)), target)
    if (!existsSync(resolved)) {
      broken = `broken link target: ${target}`
      break
    }
  }
  emit("markdown-links", broken ? "fail" : "pass", { item: md, note: broken })
}

emit("repo-docs", existsSync(join(ROOT, "README.md")) ? "pass" : "fail", { item: "README.md" })
emit("repo-docs", existsSync(join(ROOT, "CHANGELOG.md")) ? "pass" : "fail", { item: "CHANGELOG.md" })
emit("repo-docs", existsSync(join(ROOT, "AGENTS.md")) ? "pass" : "fail", {
  item: "AGENTS.md",
  note: existsSync(join(ROOT, "AGENTS.md")) ? undefined : "Add AGENTS.md with contributor and Uphill rules"
})
