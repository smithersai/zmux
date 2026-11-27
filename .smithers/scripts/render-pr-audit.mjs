#!/usr/bin/env node
/**
 * Render a Lighthouse-style Markdown backpressure summary for GitHub Actions
 * job summaries and pull request audit comments, combining Uphill scores,
 * Factory & Trust checks, and explicit trusted vs untrusted provenance.
 */

import { execFileSync } from "node:child_process"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..")

function bandIcon(score) {
  if (typeof score !== "number") return "⚪"
  if (score >= 90) return "🟢"
  if (score >= 50) return "🟠"
  return "🔴"
}

export function renderLighthouseMarkdown(audit) {
  const trust = audit?.provenance?.trust === "trusted" ? "trusted" : "untrusted"
  const cacheMode = audit?.provenance?.cacheMode || "read-only"
  const namespace = audit?.provenance?.cacheNamespace || "untrusted-local"
  const objectStore = audit?.provenance?.objectStore || "https://build.smithers.sh"

  const lines = [
    `## zmux Lighthouse Backpressure Audit (${audit?.overallScore ?? 0}/100 ${bandIcon(audit?.overallScore)})`,
    "",
    trust === "trusted"
      ? `> **TRUSTED GATE EXECUTION** (${audit?.provenance?.source || "maintainer-gate"}) · Object store \`${objectStore}\` (\`${cacheMode}\`, namespace \`${namespace}\`). Eligible to publish cache and satisfy merge gates.`
      : `> **UNTRUSTED FEEDBACK EXECUTION** (${audit?.provenance?.source || "untrusted-local-or-pr"}) · Object store \`${objectStore}\` (\`${cacheMode}\`, namespace \`${namespace}\`). Encouraged for fast feedback, cannot poison trunk cache or skip merge gates.`,
    "",
    "| Category | Score | Band | Passing Metrics |",
    "| --- | ---: | --- | ---: |"
  ]

  for (const cat of audit?.categories ?? []) {
    const metrics = Array.isArray(cat.metrics) ? cat.metrics : []
    const passing = metrics.filter((m) => typeof m.score === "number" && m.score >= 90).length
    lines.push(`| ${bandIcon(cat.score)} ${cat.title} | **${cat.score}/100** | ${cat.band} | ${passing}/${metrics.length} |`)
  }

  const opps = Array.isArray(audit?.opportunities) ? audit.opportunities.slice(0, 8) : []
  if (opps.length > 0) {
    lines.push(
      "",
      "### Top Opportunities",
      "",
      "| Est. Gain | Category | Metric | Target | Current | Goal |",
      "| ---: | --- | --- | --- | --- | --- |"
    )
    for (const opp of opps) {
      lines.push(
        `| +${opp.gain} | ${opp.category} | \`${opp.metric}\` | \`${opp.item}\` | ${opp.value} | ${opp.target} |`
      )
    }
  }

  lines.push(
    "",
    "Links: [Smithers Cloud Factory](https://smithers.sh/smithersai/zmux) · [Interactive Lighthouse Audit](https://smithersai.github.io/zmux/audit/) · [Engineering Wiki](https://smithersai.github.io/zmux/wiki/)"
  )
  return `${lines.join("\n")}\n`
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const raw = execFileSync(
    process.execPath,
    [resolve(ROOT, ".smithers/views/backpressure/run.mjs"), '{"refresh":false}'],
    { cwd: ROOT, encoding: "utf8" }
  )
  const audit = JSON.parse(raw)
  process.stdout.write(renderLighthouseMarkdown(audit))
}
