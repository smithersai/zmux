import assert from "node:assert/strict"
import test from "node:test"
import { renderLighthouseMarkdown } from "./render-pr-audit.mjs"

test("renderLighthouseMarkdown renders untrusted provenance banner and all category rows", () => {
  const md = renderLighthouseMarkdown({
    overallScore: 86,
    provenance: {
      trust: "untrusted",
      cacheMode: "read-only",
      cacheNamespace: "pr-42",
      objectStore: "https://build.smithers.sh",
      source: "untrusted-local-or-pr"
    },
    categories: [
      { title: "Footprint", score: 92, band: "good", metrics: [{ score: 92 }] },
      { title: "Correctness", score: 100, band: "good", metrics: [{ score: 100 }] }
    ],
    opportunities: [
      { gain: 5, category: "Footprint", metric: "module-bytes", item: "src/server.zig", value: "25 kB", target: "24 kB" }
    ]
  })
  assert.ok(md.includes("UNTRUSTED FEEDBACK EXECUTION"))
  assert.ok(md.includes("cannot poison trunk cache or skip merge gates"))
  assert.ok(md.includes("pr-42"))
  assert.ok(md.includes("🟢 Footprint"))
  assert.ok(md.includes("🟢 Correctness"))
  assert.ok(md.includes("Top Opportunities"))
  assert.ok(!md.includes("—"))
})

test("renderLighthouseMarkdown renders trusted gate banner for trusted executions", () => {
  const md = renderLighthouseMarkdown({
    overallScore: 97,
    provenance: {
      trust: "trusted",
      cacheMode: "read-write",
      cacheNamespace: "trunk",
      objectStore: "https://build.smithers.sh",
      source: "github-actions-main-branch"
    },
    categories: [{ title: "Factory & Trust", score: 100, band: "good", metrics: [{ score: 100 }] }],
    opportunities: []
  })
  assert.ok(md.includes("TRUSTED GATE EXECUTION"))
  assert.ok(md.includes("Eligible to publish cache and satisfy merge gates"))
  assert.ok(!md.includes("Top Opportunities"))
})
