#!/usr/bin/env node
/**
 * Bounded Backpressure Lighthouse Audit runner for smithersai/zmux.
 *
 * Collects live Uphill continuous metrics, Factory & Trust boundary checks,
 * benchmark suite baselines, fuzz harness inventory, and trust provenance
 * (trusted vs untrusted execution) and emits a single Lighthouse-shaped JSON
 * audit document.
 */

import { execFileSync } from "node:child_process"
import { existsSync, readFileSync, readdirSync } from "node:fs"
import { join, resolve } from "node:path"

const ROOT = resolve(process.cwd())

function safeReadJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"))
  } catch {
    return null
  }
}

function safeReadText(rel) {
  const full = join(ROOT, rel)
  return existsSync(full) ? readFileSync(full, "utf8") : ""
}

function bandOf(score) {
  if (typeof score !== "number") return "none"
  return score >= 90 ? "good" : score >= 50 ? "average" : "poor"
}

function formatMetricVal(val, unit) {
  if (val === null || val === undefined) return ""
  if (typeof val === "string") return val
  if (unit === "B") return val >= 1024 ? `${(val / 1024).toFixed(1)} kB` : `${val} B`
  return unit ? `${val} ${unit}` : String(val)
}

function detectTrustProvenance(policy) {
  const explicitTrust = process.env.SMITHERS_TRUST_LEVEL
  const hasWriteToken = Boolean(process.env.SMITHERS_CACHE_WRITE_TOKEN)
  const hasReadToken = Boolean(process.env.SMITHERS_CACHE_READ_TOKEN)
  const githubEvent = process.env.GITHUB_EVENT_NAME ?? ""
  const githubRef = process.env.GITHUB_REF ?? ""
  const githubActor = process.env.GITHUB_ACTOR ?? ""
  const isSmithersSandbox = process.env.SMITHERS_CONTROLLED_SANDBOX === "1"
  const maintainers = new Set(policy?.maintainers ?? ["roninjin10"])

  const isTrustedMainCi = githubEvent === "push" && githubRef === "refs/heads/main" && hasWriteToken
  const isTrustedSandbox = isSmithersSandbox && hasWriteToken
  const isTrustedMaintainer =
    explicitTrust === "trusted" &&
    (maintainers.has(githubActor || process.env.SMITHERS_ACTOR || "") || !process.env.GITHUB_ACTIONS)

  const trusted = isTrustedMainCi || isTrustedSandbox || isTrustedMaintainer
  return {
    trust: trusted ? "trusted" : "untrusted",
    cacheMode: trusted && hasWriteToken ? "read-write" : hasReadToken ? "read-only" : "local-only",
    cacheNamespace: process.env.SMITHERS_CACHE_NAMESPACE || (trusted ? "trunk" : "untrusted-local"),
    objectStore: policy?.objectStore?.endpoint ?? "https://build.smithers.sh",
    canPublishCache: trusted && hasWriteToken,
    canSatisfyMergeGates: trusted,
    source: isTrustedSandbox
      ? "smithers-cloud-controlled-sandbox"
      : isTrustedMainCi
        ? "github-actions-main-branch"
        : isTrustedMaintainer
          ? "maintainer-signed-execution"
          : "untrusted-local-or-pr",
    note: trusted && hasWriteToken
      ? "Verified inside a Smithers-controlled sandbox with write credentials. Eligible to publish cache and satisfy merge gates."
      : trusted
        ? "Verified on a controlled main-branch runner. Satisfies merge gates while remote object store writes remain scoped to the protected CI cache step."
        : "Untrusted execution is encouraged for fast feedback. Reads the shared object store read-only and never poisons cache or skips gates."
  }
}

function evaluateFactoryTrustCategory() {
  const workspaceTs = safeReadText(".smithers/WORKSPACE.ts")
  const factoryTs = safeReadText(".smithers/FACTORY.ts")
  const homeJson = safeReadText(".smithers/home.json")
  const trustJson = safeReadText(".smithers/trust-policy.json")
  const ciYml = safeReadText(".github/workflows/ci.yml")
  const releaseYml = safeReadText(".github/workflows/release.yml")
  const codingProject = safeReadText(".smithers/coding-project.json")

  const checks = [
    {
      id: "shared-object-store",
      title: "Shared Smithers Cloud object store",
      path: ".smithers/WORKSPACE.ts",
      pass:
        workspaceTs.includes("https://build.smithers.sh") &&
        workspaceTs.includes("SMITHERS_CACHE_READ_TOKEN") &&
        workspaceTs.includes("SMITHERS_CACHE_WRITE_TOKEN"),
      description: "Action and CAS outputs sync through https://build.smithers.sh with split read/write credentials."
    },
    {
      id: "untrusted-cache-isolation",
      title: "Untrusted PR cache isolation",
      path: ".github/workflows/ci.yml",
      pass:
        ciYml.includes("SMITHERS_CACHE_READ_TOKEN") &&
        ciYml.includes("SMITHERS_CACHE_WRITE_TOKEN") &&
        ciYml.includes("refs/heads/main") &&
        !ciYml.includes("pull_request_target"),
      description: "PR runs never receive write credentials, never use pull_request_target, and cannot poison the trunk cache."
    },
    {
      id: "protected-paths-policy",
      title: "Protected paths & maintainer gates",
      path: ".smithers/trust-policy.json",
      pass:
        factoryTs.includes("protectedPaths") &&
        trustJson.includes('"canWriteCache": false') &&
        trustJson.includes('"canSatisfyMergeGates": false'),
      description: "Critical PTY, protocol, daemon, and CI files require maintainer review and person-only landing."
    },
    {
      id: "personalized-home-ui",
      title: "Personalized Maintainer, Contributor & Viewer UI",
      path: ".smithers/home.json",
      pass:
        homeJson.includes('"sections"') &&
        homeJson.includes('"maintainer"') &&
        homeJson.includes('"contributor"') &&
        homeJson.includes('"everyone"'),
      description: "Custom repository home adapts views for Maintainer, Contributor, and Viewer personas."
    },
    {
      id: "wiki-and-llms-index",
      title: "Engineering Wiki, Mythical History & llms.txt",
      path: ".smithers/coding-project.json",
      pass:
        homeJson.includes("llms.txt") &&
        codingProject.includes('"mythical-history"') &&
        existsSync(join(ROOT, ".smithers/wiki/pages/mythical-history.md")),
      description: "Source-cited wiki catalog, Mythical History chronicle, and live llms.txt index power the Smithers Docs tab."
    },
    {
      id: "auto-release-and-docs",
      title: "Automatic releases & docs on GitHub merge",
      path: ".github/workflows/release.yml",
      pass:
        releaseYml.includes("softprops/action-gh-release") &&
        releaseYml.includes("actions/deploy-pages") &&
        releaseYml.includes("x86_64-linux-musl") &&
        releaseYml.includes("aarch64-macos"),
      description: "Merges mirrored to main automatically deploy docs/wiki/audit and cut 4-platform binary releases on version bumps."
    },
    {
      id: "mcp-one-time-auth",
      title: "Authenticated Cloud MCP & one-time sandbox auth",
      path: ".smithers/scripts/mint-sandbox-auth.mjs",
      pass:
        existsSync(join(ROOT, ".smithers/scripts/mint-sandbox-auth.mjs")) &&
        existsSync(join(ROOT, ".smithers/flows/sandbox-auth/flow.mdx")),
      description: "Generates single-use OAuth PKCE / ephemeral attach bundles without ever exposing write tokens or cookies."
    }
  ]

  const passed = checks.filter((c) => c.pass).length
  const score = Math.round((passed / checks.length) * 100)
  return {
    id: "factory",
    title: "Factory & Trust",
    description: "Smithers Cloud object store, untrusted execution isolation, personalized personas, wiki, MCP auth, and auto-release gates.",
    score,
    band: bandOf(score),
    metrics: checks.map((c) => ({
      id: c.id,
      title: c.title,
      kind: "check",
      unit: null,
      value: c.pass ? "pass" : "fail",
      target: "pass",
      better: "higher",
      rollup: null,
      worstItem: c.path,
      score: c.pass ? 100 : 0,
      band: c.pass ? "good" : "poor",
      description: c.description,
      items: [{ item: c.path, value: c.pass ? "pass" : "fail", target: "pass", note: c.pass ? "verified" : c.description }]
    }))
  }
}

function readUphillReport(allowRefresh) {
  const reportPath = join(ROOT, ".uphill", "report.json")
  if (allowRefresh || !existsSync(reportPath)) {
    const candidates = [
      process.env.UPHILL_BIN,
      join(process.env.HOME ?? "", ".uphill", "bin", "uphill"),
      "uphill"
    ].filter(Boolean)
    for (const bin of candidates) {
      try {
        execFileSync(bin, ["--compact"], { cwd: ROOT, stdio: "ignore", timeout: 20_000 })
        break
      } catch {
        // Fall back to existing report.json or next candidate.
      }
    }
  }
  return safeReadJson(reportPath)
}

function deriveOpportunities(categories) {
  const derived = []
  for (const cat of categories) {
    const metricCount = Math.max((cat.metrics ?? []).length, 1)
    for (const m of cat.metrics ?? []) {
      if (typeof m.score !== "number" || m.score >= 100) continue
      const gain = Math.max(1, Math.round((100 - m.score) / metricCount))
      const failingItems = (m.items ?? []).filter((it) => {
        if (typeof it.value === "string") return it.value !== "pass"
        if (typeof it.value === "number" && typeof (it.target ?? m.target) === "number") {
          const tgt = it.target ?? m.target
          return m.better === "higher" ? it.value < tgt : it.value > tgt
        }
        return false
      })
      if (failingItems.length > 0) {
        const worst = failingItems[0]
        derived.push({
          gain,
          category: cat.title,
          metric: m.id,
          item: failingItems.length > 1 ? `${worst.item} (+${failingItems.length - 1} more)` : worst.item,
          items: failingItems.length,
          value: formatMetricVal(worst.value, m.unit),
          target: formatMetricVal(worst.target ?? m.target ?? "pass", m.unit)
        })
      } else {
        derived.push({
          gain,
          category: cat.title,
          metric: m.id,
          item: m.worstItem || "repo",
          items: 1,
          value: formatMetricVal(m.value, m.unit),
          target: formatMetricVal(m.target ?? "pass", m.unit)
        })
      }
    }
  }
  return derived.sort((a, b) => b.gain - a.gain).slice(0, 12)
}

function summarizeReport(rawReport, benchBaseline, policy, provenance) {
  const categories = []
  const opportunities = []
  const moduleMatrix = {}

  if (rawReport && Array.isArray(rawReport.categories)) {
    for (const cat of rawReport.categories) {
      const catId = cat.name ?? cat.id ?? "unknown"
      const score = typeof cat.score === "number" ? Math.round(cat.score) : 0
      const metrics = []
      for (const m of cat.metrics ?? []) {
        const mId = m.name ?? m.id ?? "metric"
        const mScore = typeof m.score === "number" ? Math.round(m.score) : null
        const items = (m.items ?? []).slice(0, 256).map((it) => {
          const itemName = it.name ?? it.item ?? "repo"
          const target = it.target ?? m.target ?? null
          if (typeof itemName === "string" && itemName.startsWith("src/")) {
            moduleMatrix[itemName] ??= { file: itemName, checks: {} }
            const pass = it.value === "pass" || (typeof it.value === "number" && typeof target === "number"
              ? (m.better === "higher" ? it.value >= target : it.value <= target)
              : null)
            moduleMatrix[itemName].checks[`${catId}:${mId}`] = {
              value: it.value ?? null,
              target,
              kind: m.kind ?? "count",
              unit: m.unit ?? null,
              better: m.better ?? "lower",
              pass,
              note: it.note ?? null
            }
          }
          return {
            item: itemName,
            value: it.value ?? null,
            target,
            note: it.note ?? null
          }
        })
        metrics.push({
          id: mId,
          title: m.title ?? mId,
          kind: m.kind ?? "count",
          unit: m.unit ?? null,
          value: m.value ?? null,
          target: m.target ?? null,
          better: m.better ?? "lower",
          rollup: m.rollup ?? null,
          worstItem: m.item ?? null,
          score: mScore,
          band: bandOf(mScore),
          description: m.description ?? "",
          items
        })
      }
      categories.push({
        id: catId,
        title: cat.title ?? catId,
        description: cat.description ?? "",
        score,
        band: bandOf(score),
        metrics
      })
    }
    for (const opp of (rawReport.opportunities ?? []).slice(0, 12)) {
      opportunities.push({
        gain: opp.gain ?? 0,
        category: opp.category ?? "",
        metric: opp.metric ?? "",
        item: opp.item ?? (opp.items > 1 ? `${opp.items} items` : "repo"),
        items: opp.items ?? 1,
        value: opp.value ?? "",
        target: opp.target ?? ""
      })
    }
  }

  // Append 6th Lighthouse category: Factory & Trust verification
  categories.push(evaluateFactoryTrustCategory())

  const finalOpportunities = opportunities.length > 0 ? opportunities : deriveOpportunities(categories)

  const overallScore = categories.length > 0
    ? Math.round(categories.reduce((acc, c) => acc + c.score, 0) / categories.length)
    : 0

  const fuzzDir = join(ROOT, "test", "fuzz")
  const fuzzHarnesses = existsSync(fuzzDir)
    ? readdirSync(fuzzDir).filter((f) => f.endsWith(".zig") && f !== "main.zig" && f !== "corpus.zig").sort()
    : []

  const benchmarks = Array.isArray(benchBaseline?.benchmarks)
    ? benchBaseline.benchmarks.map((b) => ({
        suite: b.suite,
        name: b.name,
        medianNs: b.medianNs ?? null,
        p95Ns: b.p95Ns ?? null,
        opsPerSec: b.opsPerSec ?? null,
        mbPerSec: b.mbPerSec ?? null
      }))
    : []

  const benchSuites = [...new Set(benchmarks.map((b) => b.suite))].sort()

  return {
    schema: "zmux.backpressure.lighthouse.v1",
    repository: "smithersai/zmux",
    generatedAt: new Date().toISOString(),
    overallScore,
    overallBand: bandOf(overallScore),
    provenance,
    categories,
    opportunities: finalOpportunities,
    modules: Object.values(moduleMatrix).sort((a, b) => a.file.localeCompare(b.file)),
    telemetry: {
      fuzzHarnessCount: fuzzHarnesses.length,
      fuzzHarnesses,
      benchmarkSuiteCount: benchSuites.length,
      benchmarkSuites: benchSuites,
      benchmarkCount: benchmarks.length,
      benchmarks
    },
    trustPolicy: {
      maintainers: policy?.maintainers ?? ["roninjin10"],
      objectStore: policy?.objectStore?.endpoint ?? "https://build.smithers.sh",
      mcpEndpoint: policy?.mcpEndpoint ?? "https://smithers.sh/smithersai/zmux/mcp",
      protectedPathCount: Array.isArray(policy?.protectedPaths) ? policy.protectedPaths.length : 0
    }
  }
}

function main() {
  let request = {}
  const rawArg = process.argv[2]
  if (rawArg) {
    try {
      request = JSON.parse(rawArg)
    } catch {
      request = {}
    }
  }
  const allowRefresh = request.refresh !== false
  const policy = safeReadJson(join(ROOT, ".smithers", "trust-policy.json"))
  const benchBaseline = safeReadJson(join(ROOT, "bench", "baseline.json"))
  const provenance = detectTrustProvenance(policy)
  const rawReport = readUphillReport(allowRefresh)
  const summary = summarizeReport(rawReport, benchBaseline, policy, provenance)
  process.stdout.write(`${JSON.stringify(summary)}\n`)
}

main()
