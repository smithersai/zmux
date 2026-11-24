/**
 * The factory that develops smithersai/zmux (https://smithers.sh/smithersai/zmux):
 * featured flows, Dispatcher rules, GitHub policy, and the app home shown at
 * smithers.sh/smithersai/zmux. Projected into .smithers/factory.json and
 * .smithers/home.json by //.smithers:factory-write and checked by
 * //.smithers:factory-check.
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

export const factory = S.Factory({
  summary: "zmux: incremental Zig 0.17.1 CI with per-module tests and benchmarks, coverage-guided protocol and live-PTY fuzzing, and maintainer triage.",
  flows: [review, issueRepro, issuePoc, prTriage, fuzzSoak],
  on: {
    "schedule:0 14 * * 1": {
      flow: "fuzz-soak",
      description: "Weekly Monday extended fuzz soak of the protocol, line reader, and live PTY/daemon targets"
    }
  },
  github: S.Github.Policy({
    mirror: "pull",
    issues: "read",
    changes: "send-upstream",
    maintainers: ["roninjin10"],
    protectedPaths: [
      "src/protocol.zig",
      "src/sys.zig",
      "src/pty.zig",
      "src/daemon.zig",
      "src/native.zig",
      "build.zig",
      "build.zig.zon",
      ".github/workflows/release.yml"
    ]
  })
})

export const home = S.Factory.Home({
  blocks: [
    {
      type: "text",
      title: "zmux factory",
      text: "tmux-style PTY session multiplexer in Zig: a daemon owns sessions, windows, panes, and PTYs; clients attach over a UNIX-socket JSON-RPC protocol. Incremental per-module Zig tests and benchmarks, coverage-guided fuzzing, and cross-compiled release builds run through `smthrs ci` with the build.smithers.sh cache."
    },
    {
      type: "prompt",
      title: "Ask about zmux",
      placeholder: "Describe a PTY hang, attach bug, protocol issue, or change…"
    },
    {
      type: "flows",
      title: "Review, reproduce, and fuzz"
    },
    {
      type: "links",
      links: [
        { label: "Repository", url: "https://github.com/smithersai/zmux" },
        { label: "CI", url: "https://github.com/smithersai/zmux/actions/workflows/ci.yml" },
        { label: "Releases", url: "https://github.com/smithersai/zmux/releases" },
        { label: "README", url: "https://github.com/smithersai/zmux/blob/main/README.md" }
      ]
    }
  ]
})
