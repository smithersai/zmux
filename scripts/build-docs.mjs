#!/usr/bin/env node
/**
 * Build the static documentation site, llms.txt index, Engineering Wiki,
 * Mythical History Chronicle, interactive Protocol Inspector, and live
 * Lighthouse Backpressure Audit Report for smithersai/zmux into dist/site/.
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
  --avg: #b25e00;
  --avg-bg: rgba(255, 164, 0, 0.14);
  --poor: #c62828;
  --poor-bg: rgba(255, 51, 51, 0.14);
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
    --avg: #f0b429;
    --poor: #f85149;
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
.diagram {
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: 12px;
  padding: 16px;
  margin: 18px 0 24px;
  overflow-x: auto;
}
.diagram svg { width: 100%; height: auto; display: block }
.pill { display: inline-block; padding: 3px 10px; border-radius: 999px; font-size: 12px; font-weight: 700; margin: 0 6px 6px 0 }
.pill.good { background: var(--good-bg); color: var(--good) }
.pill.average { background: var(--avg-bg); color: var(--avg) }
.pill.poor { background: var(--poor-bg); color: var(--poor) }
.timeline { list-style: none; padding: 0; margin: 16px 0; border-left: 2px solid var(--line); margin-left: 8px }
.timeline li { position: relative; padding: 0 0 18px 22px }
.timeline li::before {
  content: "";
  position: absolute;
  left: -7px;
  top: 6px;
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: var(--accent);
  border: 2px solid var(--bg);
}
.timeline .meta { color: var(--muted); font-size: 12px; font-family: ui-monospace, monospace }
.scroll { overflow-x: auto }
.search-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; margin: 16px 0 8px }
.search-input { width: 100%; max-width: 420px; padding: 8px 12px; border: 1px solid var(--line); border-radius: 8px; background: var(--surface); color: var(--fg); font: inherit }
.search-count { color: var(--muted); font-size: 13px }
.card[hidden] { display: none }
.num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap }
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
      <a class="${active === "history" ? "active" : ""}" href="${prefix}/history/index.html">Mythical history</a>
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

const ARCHITECTURE_SVG = `<div class="diagram" aria-label="zmux runtime and Smithers Cloud factory architecture">
<svg viewBox="0 0 920 260" xmlns="http://www.w3.org/2000/svg" role="img">
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M 0 1 L 10 5 L 0 9 z" fill="currentColor" opacity="0.65"/>
    </marker>
  </defs>
  <g fill="none" stroke="currentColor" stroke-opacity="0.35" stroke-width="1.5">
    <rect x="16" y="20" width="210" height="96" rx="10" fill="currentColor" fill-opacity="0.04"/>
    <rect x="278" y="20" width="250" height="96" rx="10" fill="currentColor" fill-opacity="0.06"/>
    <rect x="580" y="20" width="324" height="96" rx="10" fill="currentColor" fill-opacity="0.04"/>
    <rect x="16" y="148" width="275" height="92" rx="10" fill="currentColor" fill-opacity="0.04"/>
    <rect x="336" y="148" width="256" height="92" rx="10" fill="currentColor" fill-opacity="0.06"/>
    <rect x="636" y="148" width="268" height="92" rx="10" fill="currentColor" fill-opacity="0.04"/>
    <line x1="226" y1="68" x2="274" y2="68" marker-end="url(#arrow)"/>
    <line x1="528" y1="68" x2="576" y2="68" marker-end="url(#arrow)"/>
    <line x1="291" y1="194" x2="332" y2="194" marker-end="url(#arrow)"/>
    <line x1="592" y1="194" x2="632" y2="194" marker-end="url(#arrow)"/>
  </g>
  <g fill="currentColor" font-family="system-ui, -apple-system, sans-serif">
    <text x="32" y="46" font-size="13" font-weight="700">Clients (Multi-Attach)</text>
    <text x="32" y="68" font-size="12" opacity="0.78">zmux-connect CLI · Desktop</text>
    <text x="32" y="86" font-size="12" opacity="0.78">Web terminals · MCP agents</text>
    <text x="32" y="104" font-size="11" opacity="0.65">UNIX socket JSON-RPC 2.0</text>

    <text x="294" y="46" font-size="13" font-weight="700">zmuxd Daemon (Zig 0.17.1)</text>
    <text x="294" y="68" font-size="12" opacity="0.78">0700 dirs · same-UID peer creds</text>
    <text x="294" y="86" font-size="12" opacity="0.78">Sessions · Windows · Panes</text>
    <text x="294" y="104" font-size="11" opacity="0.65">Bounded scrollback + replay offsets</text>

    <text x="596" y="46" font-size="13" font-weight="700">OS PTYs and Foreground Tracker</text>
    <text x="596" y="68" font-size="12" opacity="0.78">openpty/forkpty + O_CLOEXEC hygiene</text>
    <text x="596" y="86" font-size="12" opacity="0.78">SIGHUP -> SIGTERM -> SIGKILL ladder</text>
    <text x="596" y="104" font-size="11" opacity="0.65">macOS libproc + Linux /proc foreground</text>

    <text x="32" y="174" font-size="13" font-weight="700">Smithers Cloud + Cloud MCP</text>
    <text x="32" y="196" font-size="12" opacity="0.78">smithers.sh/smithersai/zmux/mcp</text>
    <text x="32" y="214" font-size="12" opacity="0.78">OAuth 2.1 PKCE · One-time sandbox auth</text>
    <text x="32" y="230" font-size="11" opacity="0.65">Maintainer / Contributor / Viewer UI</text>

    <text x="352" y="174" font-size="13" font-weight="700">Shared Object Store + Trust Gate</text>
    <text x="352" y="196" font-size="12" opacity="0.78">build.smithers.sh (/ac + /cas)</text>
    <text x="352" y="214" font-size="12" opacity="0.78">Untrusted runs: read-only, no gate skip</text>
    <text x="352" y="230" font-size="11" opacity="0.65">Trusted sandboxes write cache + land</text>

    <text x="652" y="174" font-size="13" font-weight="700">GitHub Mirror Auto-Publish</text>
    <text x="652" y="196" font-size="12" opacity="0.78">4-target ReleaseSafe tarballs + SHA256</text>
    <text x="652" y="214" font-size="12" opacity="0.78">Docs + llms.txt + Engineering Wiki</text>
    <text x="652" y="230" font-size="11" opacity="0.65">Live Lighthouse Backpressure Audit</text>
  </g>
</svg>
</div>`

function main() {
  rmSync(OUT, { recursive: true, force: true })
  mkdirSync(join(OUT, "pages"), { recursive: true })
  mkdirSync(join(OUT, "wiki"), { recursive: true })
  mkdirSync(join(OUT, "history"), { recursive: true })
  mkdirSync(join(OUT, "audit"), { recursive: true })
  mkdirSync(join(OUT, "playground"), { recursive: true })
  writeFileSync(join(OUT, ".nojekyll"), "")

  const project = JSON.parse(readFileSync(join(ROOT, ".smithers", "coding-project.json"), "utf8"))
  const homeJson = JSON.parse(readFileSync(join(ROOT, ".smithers", "home.json"), "utf8"))
  const chroniclePath = join(ROOT, ".smithers", "wiki", "chronicle.json")
  const chronicle = existsSync(chroniclePath) ? JSON.parse(readFileSync(chroniclePath, "utf8")) : { commits: [] }
  const auditJson = JSON.parse(
    execFileSync(process.execPath, [".smithers/views/backpressure/run.mjs", '{"refresh":false}'], {
      cwd: ROOT,
      encoding: "utf8"
    })
  )

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

  const backlinks = new Map()
  for (const page of project.pages) {
    for (const relId of page.related ?? []) {
      const list = backlinks.get(relId) ?? []
      list.push(page)
      backlinks.set(relId, list)
    }
  }

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
    const backlinkHtml = (backlinks.get(page.id) ?? [])
      .map((srcPage) => `<li><a href="../${escapeHtml(srcPage.id)}/index.html">${escapeHtml(srcPage.title)}</a></li>`)
      .join("")
    const inputsHtml = (page.inputs ?? []).map((p) => `<code>${escapeHtml(p)}</code>`).join(" ")
    const wikiPageHtml = pageShell({
      title: page.title,
      description: page.purpose,
      active: "wiki",
      prefix: "../..",
      body: `<p><a href="../index.html">Back to Engineering wiki</a></p>
${page.id === "start-here" ? ARCHITECTURE_SVG : ""}
${renderMarkdown(rawMd)}
<h2>Cited source files</h2>
<p>${inputsHtml}</p>
${relatedHtml ? `<h2>Related pages</h2><ul>${relatedHtml}</ul>` : ""}
${backlinkHtml ? `<h2>Referenced by</h2><ul>${backlinkHtml}</ul>` : ""}`
    })
    writeFileSync(join(pageDir, "index.html"), wikiPageHtml)
    const searchIndex = [page.title, page.purpose, ...(page.inputs ?? [])].join(" ").toLowerCase()
    wikiCards.push(
      `<div class="card" data-wiki-card data-search="${escapeHtml(searchIndex)}"><h3><a href="${escapeHtml(page.id)}/index.html">${escapeHtml(page.title)}</a></h3><p>${escapeHtml(page.purpose)}</p></div>`
    )
  }

  writeFileSync(
    join(OUT, "wiki", "index.html"),
    pageShell({
      title: "Engineering wiki",
      description: "Source-cited architectural wiki and mythical history for smithersai/zmux",
      active: "wiki",
      prefix: "..",
      body: `<h1>zmux Engineering Wiki</h1>
<p>Every page is cataloged in <code>.smithers/coding-project.json</code>, grounded in exact public source files, and validated in CI.</p>
${ARCHITECTURE_SVG}
<div class="search-bar">
  <input id="wiki-search" class="search-input" type="search" placeholder="Search wiki pages or Zig modules (for example pty, protocol, scrollback)..." aria-label="Search engineering wiki">
  <span id="wiki-search-count" class="search-count">${wikiCards.length} of ${wikiCards.length} pages</span>
</div>
<div class="grid" id="wiki-grid">${wikiCards.join("\n")}</div>
<script>
const input = document.getElementById("wiki-search")
const countEl = document.getElementById("wiki-search-count")
const cards = [...document.querySelectorAll("[data-wiki-card]")]
input?.addEventListener("input", () => {
  const q = input.value.trim().toLowerCase()
  let shown = 0
  for (const card of cards) {
    const hay = card.getAttribute("data-search") || ""
    const match = !q || hay.includes(q)
    card.hidden = !match
    if (match) shown++
  }
  if (countEl) countEl.textContent = shown + " of " + cards.length + " pages"
})
</script>`
    })
  )

  // Render Mythical History Chronicle page.
  const commits = Array.isArray(chronicle.commits) ? chronicle.commits.slice(0, 30) : []
  const timelineItems = commits
    .map(
      (c) =>
        `<li><div class="meta">${escapeHtml(c.date || "")} · <code>${escapeHtml(c.sha || "")}</code> · ${escapeHtml(c.author || "")}</div><strong>${escapeHtml(c.subject || "")}</strong></li>`
    )
    .join("\n")
  const mythicalMd = readFileSync(join(ROOT, ".smithers/wiki/pages/mythical-history.md"), "utf8")
    .replace(/^#\s+[^\n]+\n+/, "")
  writeFileSync(
    join(OUT, "history", "index.html"),
    pageShell({
      title: "Mythical history",
      description: "Chronicle of zmux releases, hardening rounds, and Smithers Cloud stacked changesets",
      active: "history",
      prefix: "..",
      body: `<h1>zmux Mythical History</h1>
${renderMarkdown(mythicalMd)}
<h2>Commit chronicle</h2>
<ul class="timeline">${timelineItems || "<li>No recorded commits yet.</li>"}</ul>`
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
  const mdLines = [
    "# zmux Lighthouse Backpressure Audit Report",
    "",
    `- Overall score: **${auditJson.overallScore}/100**`,
    `- Trust level: **${auditJson.provenance?.trust || "untrusted"}** (${auditJson.provenance?.cacheMode || "read-only"} cache on \`build.smithers.sh\`)`,
    `- Generated at: \`${auditJson.generatedAt || ""}\``,
    "",
    "## Category Scores",
    "",
    "| Category | Score | Passing |",
    "| --- | ---: | ---: |"
  ]
  for (const cat of auditJson.categories ?? []) {
    const metrics = Array.isArray(cat.metrics) ? cat.metrics : []
    const passing = metrics.filter((m) => typeof m.score === "number" && m.score >= 90).length
    mdLines.push(`| ${cat.title} | ${cat.score}/100 | ${passing}/${metrics.length} |`)
  }
  if (Array.isArray(auditJson.opportunities) && auditJson.opportunities.length > 0) {
    mdLines.push(
      "",
      "## Top Opportunities",
      "",
      "| Gain | Metric | Target | Value |",
      "| ---: | --- | --- | --- |"
    )
    for (const opp of auditJson.opportunities.slice(0, 12)) {
      mdLines.push(
        `| +${opp.gain} | \`${opp.metric}\` | \`${opp.item}\` | ${opp.value} -> ${opp.target} |`
      )
    }
  }
  const auditMd = `${mdLines.join("\n")}\n`
  writeFileSync(join(OUT, "audit", "report.md"), auditMd)
  writeFileSync(join(OUT, "pages", "backpressure-audit.md"), auditMd)
  llmsLines.push(
    "",
    "## Backpressure Audit",
    "",
    `- [Lighthouse Backpressure Audit Report](${BASE_URL}/pages/backpressure-audit.md): Live Uphill quality scores, module matrix, and trust provenance`
  )
  llmsFull.push(`\n---\n<!-- audit/report.md -->\n\n${auditMd}`)
  writeFileSync(join(OUT, "llms.txt"), `${llmsLines.join("\n")}\n`)
  writeFileSync(join(OUT, "llms-full.txt"), `${llmsFull.join("\n")}\n`)
  if (existsSync(join(ROOT, ".uphill", "report.html"))) {
    copyFileSync(join(ROOT, ".uphill", "report.html"), join(OUT, "audit", "uphill.html"))
  }

  copyFileSync(join(ROOT, ".smithers", "playground", "index.html"), join(OUT, "playground", "index.html"))
  if (existsSync(join(ROOT, "scripts", "install.sh"))) {
    copyFileSync(join(ROOT, "scripts", "install.sh"), join(OUT, "install.sh"))
  }

  const scorePills = (auditJson.categories ?? [])
    .map((c) => `<span class="pill ${escapeHtml(c.band || "average")}">${escapeHtml(c.title)}: ${c.score}/100</span>`)
    .join("")

  const audienceRows = (homeJson.sections ?? [])
    .map(
      (s) =>
        `<tr><td><code>${escapeHtml(s.audience)}</code></td><td>${escapeHtml(s.title || "Public landing")}</td><td>${(s.blocks || []).map((b) => `<code>${escapeHtml(b.type)}</code>`).join(" ")}</td></tr>`
    )
    .join("")

  const featuredBenchNames = [
    ["buffer", "append_64B_wrapped_10MiB"],
    ["buffer", "append_64KiB_wrapped_10MiB"],
    ["protocol", "format_notification_pane_output_8KiB"],
    ["server", "rpc_mux_snapshot_roundtrip"],
    ["server", "rpc_session_capture_50_from_10MiB"],
    ["server", "clientConn_broadcast_queue_512x1KiB"]
  ]
  const fmtBenchNs = (ns) => (ns >= 1e6 ? `${(ns / 1e6).toFixed(2)} ms` : ns >= 1e3 ? `${(ns / 1e3).toFixed(2)} us` : `${ns.toFixed(ns < 10 ? 2 : 1)} ns`)
  const fmtBenchThru = (mb) => (typeof mb !== "number" ? "-" : mb >= 1024 ? `${(mb / 1024).toFixed(2)} GB/s` : `${mb.toFixed(1)} MB/s`)
  const benchList = auditJson.telemetry?.benchmarks ?? []
  const benchRows = featuredBenchNames
    .map(([suite, name]) => benchList.find((b) => b.suite === suite && b.name === name))
    .filter(Boolean)
    .map(
      (b) =>
        `<tr><td><code>${escapeHtml(b.suite)}</code></td><td><code>${escapeHtml(b.name)}</code></td><td class="num">${fmtBenchNs(b.medianNs)}</td><td class="num">${fmtBenchNs(b.p95Ns)}</td><td class="num">${fmtBenchThru(b.mbPerSec)}</td></tr>`
    )
    .join("")

  const indexBody = `
<h1>zmux</h1>
<p>tmux-style PTY session multiplexer in Zig 0.17.1. A long-lived daemon owns sessions, windows, panes, and PTYs while clients attach over a UNIX-domain JSON-RPC 2.0 socket.</p>
<p>${scorePills}</p>
${ARCHITECTURE_SVG}

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
    <h3><a href="history/index.html">Mythical History Chronicle</a></h3>
    <p>Five architectural eras from PR #1 to Smithers Cloud, plus the live commit timeline and stacked changeset pipeline.</p>
  </div>
  <div class="card">
    <h3><a href="playground/index.html">JSON-RPC Protocol Inspector</a></h3>
    <p>Validate UNIX-socket frames, atomic client.attach replay, scoped subscriptions, and scrollback ring offsets interactively.</p>
  </div>
  <div class="card">
    <h3><a href="llms.txt">Cloud MCP &amp; llms.txt Index</a></h3>
    <p>Machine-readable documentation index served to coding agents over OAuth 2.1 + PKCE at smithers.sh/smithersai/zmux/mcp.</p>
  </div>
</div>

<h2>Personalized factory views on smithers.sh/smithersai/zmux</h2>
<p><code>.smithers/home.json</code> tailors the repository home to each audience (contributors have contributed at least one change).</p>
<div class="scroll">
  <table>
    <thead><tr><th>Audience</th><th>Section</th><th>Blocks</th></tr></thead>
    <tbody>${audienceRows}</tbody>
  </table>
</div>

${benchRows ? `<h2>Performance highlights (ReleaseFast baselines)</h2>
<p>Measured across ${benchList.length} tracked Zig benchmarks in <code>bench/baseline.json</code>. Explore the full table in the <a href="audit/index.html">Lighthouse Audit Benchmarks tab</a>.</p>
<div class="scroll">
  <table>
    <thead><tr><th>Suite</th><th>Benchmark</th><th class="num">Median</th><th class="num">p95</th><th class="num">Throughput</th></tr></thead>
    <tbody>${benchRows}</tbody>
  </table>
</div>` : ""}

<h2>Install</h2>
<pre><code>curl -fsSL https://smithersai.github.io/zmux/install.sh | sh
zig fetch --save=zmux git+https://github.com/smithersai/zmux</code></pre>

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

  process.stdout.write(`Built zmux docs site in ${OUT} (${project.pages.length} wiki pages, ${commits.length} chronicle entries, overall audit ${auditJson.overallScore}/100)\n`)
}

main()
