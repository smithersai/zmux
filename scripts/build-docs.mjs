#!/usr/bin/env node
/**
 * Build the static documentation site, llms.txt index, Engineering Wiki,
 * interactive Protocol Inspector, and live Lighthouse Backpressure Audit Report
 * for smithersai/zmux into dist/site/.
 *
 * Zero external dependencies so it runs identically locally, in smthrs build
 * targets, and on GitHub Actions.
 */

import { execFileSync } from "node:child_process"
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join, resolve } from "node:path"

const ROOT = resolve(process.cwd())
const OUT = join(ROOT, "dist", "site")
const BASE_URL = (process.env.ZMUX_DOCS_BASE_URL || "https://smithersai.github.io/zmux").replace(/\/+$/, "")

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

function renderInlineMarkdown(text) {
  let out = escapeHtml(text)
  out = out.replace(/`([^`]+)`/g, "<code>$1</code>")
  out = out.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
  out = out.replace(/\[([^\]]+)\]\(([^)]+)\)/g, (_, label, href) => {
    const safeHref = /^(https?:\/\/|\/|\.\/|\.\.\/|#)/.test(href) ? href : "#"
    return `<a href="${escapeHtml(safeHref)}">${label}</a>`
  })
  return out
}

function renderMarkdown(md) {
  const lines = md.replace(/\r\n/g, "\n").split("\n")
  const html = []
  let inCode = false
  let codeLines = []
  let inList = false
  let inTable = false

  const closeList = () => {
    if (inList) {
      html.push("</ul>")
      inList = false
    }
  }
  const closeTable = () => {
    if (inTable) {
      html.push("</tbody></table></div>")
      inTable = false
    }
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (line.startsWith("```")) {
      closeList()
      closeTable()
      if (inCode) {
        html.push(`<pre><code>${escapeHtml(codeLines.join("\n"))}</code></pre>`)
        codeLines = []
        inCode = false
      } else {
        inCode = true
      }
      continue
    }
    if (inCode) {
      codeLines.push(line)
      continue
    }
    if (/^\s*$/.test(line)) {
      closeList()
      closeTable()
      continue
    }
    const h = /^(#{1,4})\s+(.*)$/.exec(line)
    if (h) {
      closeList()
      closeTable()
      const level = h[1].length
      html.push(`<h${level}>${renderInlineMarkdown(h[2])}</h${level}>`)
      continue
    }
    if (line.startsWith("|") && line.endsWith("|")) {
      closeList()
      const cells = line.slice(1, -1).split("|").map((c) => c.trim())
      const next = lines[i + 1] ?? ""
      if (!inTable && /^\|[\s:-]+(\|[\s:-]+)*\|$/.test(next)) {
        html.push('<div class="scroll"><table><thead><tr>')
        for (const cell of cells) html.push(`<th>${renderInlineMarkdown(cell)}</th>`)
        html.push("</tr></thead><tbody>")
        inTable = true
        i++
        continue
      }
      if (inTable) {
        html.push("<tr>")
        for (const cell of cells) html.push(`<td>${renderInlineMarkdown(cell)}</td>`)
        html.push("</tr>")
        continue
      }
    } else {
      closeTable()
    }
    const li = /^\s*(?:-|\*|\d+\.)\s+(.*)$/.exec(line)
    if (li) {
      if (!inList) {
        html.push("<ul>")
        inList = true
      }
      html.push(`<li>${renderInlineMarkdown(li[1])}</li>`)
      continue
    }
    closeList()
    html.push(`<p>${renderInlineMarkdown(line)}</p>`)
  }
  closeList()
  closeTable()
  if (inCode) html.push(`<pre><code>${escapeHtml(codeLines.join("\n"))}</code></pre>`)
  return html.join("\n")
}

function pageShell({ title, description, active, body, prefix = "." }) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)} · zmux</title>
<meta name="description" content="${escapeHtml(description)}">
<style>
:root {
  --bg: #ffffff;
  --surface: #f6f8fa;
  --fg: #1f2328;
  --muted: #59636e;
  --line: #d0d7de;
  --accent: #0969da;
  --good: #00aa55;
  --good-bg: rgba(0, 170, 85, 0.12);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0d1117;
    --surface: #161b22;
    --fg: #e6edf3;
    --muted: #8b949e;
    --line: #30363d;
    --accent: #58a6ff;
    --good: #3fb950;
  }
}
* { box-sizing: border-box }
body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif }
header.nav {
  position: sticky;
  top: 0;
  z-index: 10;
  background: var(--bg);
  border-bottom: 1px solid var(--line);
}
.nav-inner {
  max-width: 1040px;
  margin: 0 auto;
  padding: 12px 20px;
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}
.brand { font-weight: 800; font-size: 16px; text-decoration: none; color: var(--fg); letter-spacing: -0.02em }
nav.links { display: flex; gap: 16px; flex-wrap: wrap; font-size: 14px }
nav.links a { color: var(--muted); text-decoration: none; font-weight: 500 }
nav.links a:hover, nav.links a.active { color: var(--accent) }
main { max-width: 1040px; margin: 0 auto; padding: 32px 20px 72px }
h1 { font-size: 30px; line-height: 1.2; margin: 0 0 10px; letter-spacing: -0.02em }
h2 { font-size: 20px; margin: 28px 0 10px; padding-bottom: 6px; border-bottom: 1px solid var(--line) }
h3 { font-size: 16px; margin: 20px 0 8px }
a { color: var(--accent) }
code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--surface); padding: 2px 5px; border-radius: 5px }
pre { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; overflow-x: auto }
pre code { background: transparent; padding: 0 }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 14px; margin: 18px 0 }
.card { background: var(--surface); border: 1px solid var(--line); border-radius: 12px; padding: 16px }
.card h3 { margin: 0 0 6px }
.card p { margin: 0; color: var(--muted); font-size: 14px }
.pill { display: inline-block; padding: 2px 9px; border-radius: 999px; font-size: 12px; font-weight: 600; background: var(--good-bg); color: var(--good) }
.scroll { overflow-x: auto }
table { width: 100%; border-collapse: collapse; margin: 12px 0; font-size: 14px }
th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line) }
th { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em }
footer { border-top: 1px solid var(--line); margin-top: 48px; padding-top: 18px; color: var(--muted); font-size: 13px }
</style>
</head>
<body>
<header class="nav">
  <div class="nav-inner">
    <a class="brand" href="${prefix}/index.html">zmux</a>
    <nav class="links">
      <a class="${active === "home" ? "active" : ""}" href="${prefix}/index.html">Overview</a>
      <a class="${active === "wiki" ? "active" : ""}" href="${prefix}/wiki/index.html">Engineering wiki</a>
      <a class="${active === "audit" ? "active" : ""}" href="${prefix}/audit/index.html">Lighthouse audit</a>
      <a class="${active === "playground" ? "active" : ""}" href="${prefix}/playground/index.html">Protocol inspector</a>
      <a href="${prefix}/llms.txt">llms.txt</a>
      <a href="https://smithers.sh/smithersai/zmux">Smithers Cloud</a>
      <a href="https://github.com/smithersai/zmux">GitHub</a>
    </nav>
  </div>
</header>
<main>
${body}
<footer>
  Published automatically when changes land from <a href="https://smithers.sh/smithersai/zmux">Smithers Cloud</a> to <a href="https://github.com/smithersai/zmux">GitHub</a>.
  Authenticated MCP endpoint: <code>https://smithers.sh/smithersai/zmux/mcp</code>
</footer>
</main>
</body>
</html>
`
}

function main() {
  rmSync(OUT, { recursive: true, force: true })
  mkdirSync(join(OUT, "pages"), { recursive: true })
  mkdirSync(join(OUT, "wiki"), { recursive: true })
  mkdirSync(join(OUT, "audit"), { recursive: true })
  mkdirSync(join(OUT, "playground"), { recursive: true })
  writeFileSync(join(OUT, ".nojekyll"), "")

  const project = JSON.parse(readFileSync(join(ROOT, ".smithers", "coding-project.json"), "utf8"))
  const auditJson = JSON.parse(
    execFileSync(process.execPath, [".smithers/views/backpressure/run.mjs", '{"refresh":false}'], {
      cwd: ROOT,
      encoding: "utf8"
    })
  )

  // Copy core Markdown documents into pages/ for llms.txt consumption.
  const coreDocs = [
    { slug: "readme.md", title: "README", summary: "Overview, installation, JSON-RPC API, and Zig embedding guide", src: "README.md" },
    { slug: "changelog.md", title: "Changelog", summary: "Release history including v0.4.0 D1 to D6 hardening decisions", src: "CHANGELOG.md" },
    { slug: "contributing.md", title: "Contributing", summary: "Setup, Smithers Cloud MCP workflow, trusted vs untrusted execution, and landing flow", src: "CONTRIBUTING.md" },
    { slug: "agents.md", title: "Agent and Factory Guide", summary: "Cloud MCP tools, one-time sandbox auth, Uphill rules, and jj workflow", src: "AGENTS.md" },
    { slug: "uphill-rules.md", title: "Uphill Quality Rules", summary: "Continuous footprint, TigerStyle, correctness, testing, and doc targets", src: ".agents/uphill/rules.md" }
  ]

  const llmsLines = [
    "# zmux",
    "",
    "> tmux-style PTY session multiplexer in Zig 0.17.1 with a UNIX-socket JSON-RPC 2.0 daemon, bounded scrollback replay, and public Smithers Cloud factory at https://smithers.sh/smithersai/zmux.",
    "",
    "## Core Documentation",
    ""
  ]
  const llmsFull = ["# zmux Full Documentation Bundle", ""]

  for (const doc of coreDocs) {
    const content = readFileSync(join(ROOT, doc.src), "utf8")
    writeFileSync(join(OUT, "pages", doc.slug), content)
    llmsLines.push(`- [${doc.title}](${BASE_URL}/pages/${doc.slug}): ${doc.summary}`)
    llmsFull.push(`\n---\n<!-- ${doc.src} -->\n\n${content}`)
  }

  llmsLines.push("", "## Engineering Wiki", "")

  const wikiCards = []
  for (const page of project.pages) {
    const rawMd = readFileSync(join(ROOT, page.document), "utf8")
    const mdSlug = `wiki-${page.id}.md`
    writeFileSync(join(OUT, "pages", mdSlug), rawMd)
    llmsLines.push(`- [${page.title}](${BASE_URL}/pages/${mdSlug}): ${page.purpose}`)
    llmsFull.push(`\n---\n<!-- ${page.document} -->\n\n${rawMd}`)

    const pageDir = join(OUT, "wiki", page.id)
    mkdirSync(pageDir, { recursive: true })
    const relatedHtml = (page.related ?? [])
      .map((relId) => {
        const target = project.pages.find((p) => p.id === relId)
        return target ? `<li><a href="../${escapeHtml(relId)}/index.html">${escapeHtml(target.title)}</a></li>` : ""
      })
      .join("")
    const inputsHtml = (page.inputs ?? []).map((p) => `<code>${escapeHtml(p)}</code>`).join(" ")
    const wikiPageHtml = pageShell({
      title: page.title,
      description: page.purpose,
      active: "wiki",
      prefix: "../..",
      body: `<p><a href="../index.html">Back to Engineering wiki</a></p>
${renderMarkdown(rawMd)}
<h2>Cited source files</h2>
<p>${inputsHtml}</p>
${relatedHtml ? `<h2>Related pages</h2><ul>${relatedHtml}</ul>` : ""}`
    })
    writeFileSync(join(pageDir, "index.html"), wikiPageHtml)
    wikiCards.push(
      `<div class="card"><h3><a href="${escapeHtml(page.id)}/index.html">${escapeHtml(page.title)}</a></h3><p>${escapeHtml(page.purpose)}</p></div>`
    )
  }

  writeFileSync(join(OUT, "llms.txt"), `${llmsLines.join("\n")}\n`)
  writeFileSync(join(OUT, "llms-full.txt"), `${llmsFull.join("\n")}\n`)

  // Render Wiki index.
  writeFileSync(
    join(OUT, "wiki", "index.html"),
    pageShell({
      title: "Engineering wiki",
      description: "Source-cited architectural wiki and mythical history for smithersai/zmux",
      active: "wiki",
      prefix: "..",
      body: `<h1>zmux Engineering Wiki</h1>
<p>Every page is cataloged in <code>.smithers/coding-project.json</code>, grounded in exact public source files, and validated in CI.</p>
<div class="grid">${wikiCards.join("\n")}</div>`
    })
  )

  // Render Lighthouse Backpressure Audit Report with embedded live snapshot.
  const auditTemplate = readFileSync(join(ROOT, ".smithers", "views", "backpressure", "index.html"), "utf8")
  const safeSnapshotJson = JSON.stringify(auditJson).replace(/</g, "\\u003c")
  const auditHtml = auditTemplate.replace(
    '<script id="zmux-audit-snapshot" type="application/json">null</script>',
    `<script id="zmux-audit-snapshot" type="application/json">${safeSnapshotJson}</script>`
  )
  writeFileSync(join(OUT, "audit", "index.html"), auditHtml)
  writeFileSync(join(OUT, "audit", "report.json"), `${JSON.stringify(auditJson, null, 2)}\n`)
  if (existsSync(join(ROOT, ".uphill", "report.html"))) {
    copyFileSync(join(ROOT, ".uphill", "report.html"), join(OUT, "audit", "uphill.html"))
  }

  // Copy interactive Protocol Inspector view.
  copyFileSync(join(ROOT, ".smithers", "playground", "index.html"), join(OUT, "playground", "index.html"))

  // Render site landing page.
  const scorePills = (auditJson.categories ?? [])
    .map((c) => `<span class="pill">${escapeHtml(c.title)}: ${c.score}/100</span>`)
    .join(" ")

  const indexBody = `
<h1>zmux</h1>
<p>tmux-style PTY session multiplexer in Zig 0.17.1. A long-lived daemon owns sessions, windows, panes, and PTYs while clients attach over a UNIX-domain JSON-RPC 2.0 socket.</p>
<p>${scorePills}</p>

<div class="grid">
  <div class="card">
    <h3><a href="https://smithers.sh/smithersai/zmux">Smithers Cloud Factory</a></h3>
    <p>Personalized UI for maintainers, contributors, and viewers with live issues, runs, mythical history stack, and sandboxed views.</p>
  </div>
  <div class="card">
    <h3><a href="audit/index.html">Lighthouse Backpressure Audit</a></h3>
    <p>Continuous Uphill scores for footprint, TigerStyle, correctness, testing, documentation, and trusted vs untrusted execution provenance.</p>
  </div>
  <div class="card">
    <h3><a href="wiki/index.html">Engineering Wiki</a></h3>
    <p>Eight source-cited architecture pages covering PTY lifecycle, D1 to D6 protocol rules, daemon security, and mythical history.</p>
  </div>
  <div class="card">
    <h3><a href="playground/index.html">JSON-RPC Protocol Inspector</a></h3>
    <p>Validate UNIX-socket frames, atomic client.attach replay, scoped subscriptions, and error shapes interactively.</p>
  </div>
</div>

<h2>Install</h2>
<pre><code>zig fetch --save=zmux git+https://github.com/smithersai/zmux</code></pre>

<h2>Connect via Authenticated Cloud MCP</h2>
<pre><code>claude mcp add zmux --transport http https://smithers.sh/smithersai/zmux/mcp
codex mcp add zmux --url https://smithers.sh/smithersai/zmux/mcp
agy mcp add zmux --transport http https://smithers.sh/smithersai/zmux/mcp</code></pre>

<h2>One-Time Sandbox Auth</h2>
<pre><code>node .smithers/scripts/mint-sandbox-auth.mjs</code></pre>

<h2>Verify Locally (Untrusted Read-Only Cache Encouraged)</h2>
<pre><code>mise install
smthrs ci '//...'
smthrs run //:bench
uphill --compact</code></pre>
`

  writeFileSync(
    join(OUT, "index.html"),
    pageShell({
      title: "Documentation",
      description: "tmux-style PTY session multiplexer in Zig with a public Smithers Cloud factory",
      active: "home",
      prefix: ".",
      body: indexBody
    })
  )

  process.stdout.write(`Built zmux docs site in ${OUT} (${project.pages.length} wiki pages, overall audit ${auditJson.overallScore}/100)\n`)
}

main()
