/**
 * The factory that develops smithersai/zmux (https://smithers.sh/smithersai/zmux):
 * featured flows, Mythical History Dispatcher rules, GitHub mirror policy, and
 * trust boundaries. Validated against .smithers/factory.json, .smithers/home.json,
 * .smithers/trust-policy.json, and .smithers/wiki/ by //.smithers:factory-check.
 */
import { Smithers as S } from "@smthrs/targets"

export const review = S.Flow({
  flow: "checks/review",
  featured: true,
  summary: "Review changes for PTY lifecycle, JSON-RPC protocol safety, attach semantics, native embedding, and Zig memory ownership."
})

export const issueRepro = S.Flow({
  flow: "issue/repro",
  featured: true,
  summary: "Reproduce a zmux PTY, daemon, attach, or protocol defect with a minimal real-PTY reproduction before planning a fix."
})

export const issuePoc = S.Flow({
  flow: "issue/poc",
  featured: true,
  summary: "Implement a bounded zmux fix with a failing unit or integration regression, fuzz seed, and benchmark check."
})

export const prTriage = S.Flow({
  flow: "pr-triage",
  featured: true,
  summary: "Assess pull request readiness from its diff and CI evidence without executing untrusted PR code."
})

export const fuzzSoak = S.Flow({
  flow: "fuzz-soak",
  featured: true,
  summary: "Run extended coverage-guided and live PTY fuzzing, minimize any crash, and report it with a corpus seed."
})

export const backpressureReport = S.Flow({
  flow: "backpressure/report",
  featured: true,
  summary: "Generate the Lighthouse-style Uphill backpressure audit report with trust provenance and ranked opportunities."
})

export const protocolPlayground = S.Flow({
  flow: "playground/protocol",
  featured: true,
  summary: "Inspect and validate zmux JSON-RPC 2.0 frames against the v0.4.0 D1-D6 wire contract."
})

export const uphill = S.Flow({
  flow: "uphill",
  featured: true,
  summary: "Run Uphill continuous metrics, verify baselines, and score footprint, TigerStyle, correctness, testing, and docs."
})

export const wikiRefresh = S.Flow({
  flow: "wiki/refresh",
  featured: true,
  summary: "Refresh and citation-check the zmux engineering wiki and mythical history from coding-project.json."
})

export const sandboxAuth = S.Flow({
  flow: "sandbox-auth",
  featured: true,
  summary: "Print one-time-use attenuated OAuth PKCE and read-only cache auth bundles for zmux sandboxes and MCP agents."
})

export const factory = S.Factory({
  summary: "zmux: public Smithers Cloud Zig factory with shared object store, Lighthouse backpressure audits, wiki, and auto releases.",
  flows: [
    review,
    issueRepro,
    issuePoc,
    prTriage,
    fuzzSoak,
    backpressureReport,
    protocolPlayground,
    uphill,
    wikiRefresh,
    sandboxAuth
  ],
  on: {
    "issue.labeled:todo": {
      flow: "issue/poc",
      description: "Implement every maintainer-approved TODO as a stacked Change on mythical history"
    },
    "change.opened": {
      flow: "checks/review",
      description: "Review every opened Change across PTY, protocol, daemon, and memory lenses"
    },
    "change.updated": {
      flow: "checks/review",
      description: "Re-review updated Changes before maintainer approval and landing"
    },
    "change.landed": {
      flow: ["wiki/refresh", "uphill"],
      description: "Refresh the engineering wiki and Lighthouse backpressure audit after every landing"
    },
    "github.push:main": {
      flow: ["wiki/refresh", "uphill"],
      description: "Refresh wiki and backpressure baseline after merges mirrored to GitHub main"
    },
    "schedule:0 14 * * 1": {
      flow: "fuzz-soak",
      description: "Weekly Monday extended fuzz soak of protocol, line reader, and live PTY/daemon targets"
    },
    "schedule:0 9 * * *": {
      flow: "backpressure/report",
      description: "Daily Lighthouse backpressure audit across all Zig modules"
    }
  },
  // Permanent switchover to Smithers Cloud: Changes land on Smithers Cloud,
  // mirror pushes to GitHub main, and GitHub push automatically triggers
  // binary releases, docs site, llms.txt, wiki, and Lighthouse audit publishing.
  github: S.Github.Policy({
    mirror: "push",
    issues: "two-way",
    changes: "land",
    maintainers: ["roninjin10"],
    dailyTokens: 500_000_000,
    protectedPaths: [
      "src/protocol.zig",
      "src/sys.zig",
      "src/pty.zig",
      "src/daemon.zig",
      "src/native.zig",
      "build.zig",
      "build.zig.zon",
      "PACKAGE.ts",
      ".smithers/WORKSPACE.ts",
      ".smithers/FACTORY.ts",
      ".smithers/PACKAGE.ts",
      ".smithers/trust-policy.json",
      ".agents/uphill/uphill.yaml",
      ".agents/uphill/uphill.baseline.yaml",
      ".github/workflows/ci.yml",
      ".github/workflows/release.yml",
      ".github/workflows/uphill.yml"
    ]
  })
})
