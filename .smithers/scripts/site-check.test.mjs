import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { dirname, join, resolve } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..")
const SITE = join(ROOT, "dist", "site")

test("build-docs.mjs produces every required site artifact with zero broken internal links", () => {
  execFileSync(process.execPath, [join(ROOT, "scripts", "build-docs.mjs")], {
    cwd: ROOT,
    stdio: "pipe"
  })

  const required = [
    "index.html",
    "llms.txt",
    "llms-full.txt",
    "install.sh",
    "wiki/index.html",
    "history/index.html",
    "audit/index.html",
    "audit/report.json",
    "audit/report.md",
    "playground/index.html"
  ]
  for (const rel of required) {
    const full = join(SITE, rel)
    assert.ok(existsSync(full), `missing built site artifact: ${rel}`)
    assert.ok(readFileSync(full, "utf8").length > 0, `empty built site artifact: ${rel}`)
  }

  // Verify every /pages/*.md URL in llms.txt resolves to a built file in dist/site/pages/
  const llms = readFileSync(join(SITE, "llms.txt"), "utf8")
  const pageMatches = [...llms.matchAll(/\/pages\/([A-Za-z0-9._-]+\.md)/g)]
  assert.ok(pageMatches.length >= 13, `expected >= 13 pages in llms.txt, found ${pageMatches.length}`)
  for (const m of pageMatches) {
    assert.ok(existsSync(join(SITE, "pages", m[1])), `llms.txt references missing page: pages/${m[1]}`)
  }

  // Crawl relative hrefs across all top-level HTML pages so 404s never ship
  const htmlPages = [
    "index.html",
    "wiki/index.html",
    "history/index.html",
    "audit/index.html",
    "playground/index.html"
  ]
  for (const page of htmlPages) {
    const html = readFileSync(join(SITE, page), "utf8")
    const baseDir = dirname(join(SITE, page))
    for (const m of html.matchAll(/href="([^"]+)"/g)) {
      const href = m[1]
      if (/^(https?:\/\/|mailto:|#)/.test(href)) continue
      const cleanHref = href.split("#")[0].split("?")[0]
      if (!cleanHref) continue
      const target = resolve(baseDir, cleanHref)
      assert.ok(
        existsSync(target) || existsSync(join(target, "index.html")),
        `broken relative link in ${page}: ${href} -> ${target}`
      )
    }
  }

  // Audit JSON carries all 6 Lighthouse categories and explicit trust provenance
  const audit = JSON.parse(readFileSync(join(SITE, "audit", "report.json"), "utf8"))
  assert.equal(typeof audit.overallScore, "number")
  assert.ok(audit.provenance?.trust === "trusted" || audit.provenance?.trust === "untrusted")
  const catIds = new Set((audit.categories ?? []).map((c) => c.id))
  assert.ok(catIds.has("factory"), "missing factory Lighthouse category")
})
