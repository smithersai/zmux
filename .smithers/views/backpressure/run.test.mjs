import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import test from "node:test"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "../../..")

function runAudit(env = {}) {
  const out = execFileSync(process.execPath, [join(here, "run.mjs"), '{"refresh":false}'], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ...env }
  })
  return JSON.parse(out)
}

test("untrusted local run defaults to untrusted provenance and read-only cache", () => {
  const report = runAudit({
    SMITHERS_TRUST_LEVEL: "",
    SMITHERS_CACHE_WRITE_TOKEN: "",
    SMITHERS_CACHE_READ_TOKEN: "test-read-token",
    GITHUB_EVENT_NAME: "pull_request",
    GITHUB_REF: "refs/pull/42/merge",
    SMITHERS_CONTROLLED_SANDBOX: ""
  })
  assert.equal(report.schema, "zmux.backpressure.lighthouse.v1")
  assert.equal(report.provenance.trust, "untrusted")
  assert.equal(report.provenance.cacheMode, "read-only")
  assert.equal(report.provenance.canPublishCache, false)
  assert.equal(report.provenance.canSatisfyMergeGates, false)
})

test("trusted Smithers-controlled sandbox with write token reports trusted provenance", () => {
  const report = runAudit({
    SMITHERS_CONTROLLED_SANDBOX: "1",
    SMITHERS_CACHE_WRITE_TOKEN: "test-write-token",
    SMITHERS_CACHE_READ_TOKEN: "test-read-token"
  })
  assert.equal(report.provenance.trust, "trusted")
  assert.equal(report.provenance.cacheMode, "read-write")
  assert.equal(report.provenance.canPublishCache, true)
  assert.equal(report.provenance.canSatisfyMergeGates, true)
  assert.equal(report.provenance.source, "smithers-cloud-controlled-sandbox")
})

test("index.html renders Lighthouse gauges with zero inline styles and no forbidden internal codenames", () => {
  const html = readFileSync(join(here, "index.html"), "utf8")
  assert.ok(html.includes("<!doctype html>"))
  assert.ok(html.includes("zmux Backpressure Audit Report"))
  assert.ok(html.includes("zmux-audit-snapshot"))
  assert.ok(html.includes('data-tab="benchmarks"'))
  assert.ok(!/\bstyle\s*=/.test(html), "index.html must not contain inline style= attributes")
  assert.ok(!html.toLowerCase().includes("jjhub"))
})

test("telemetry includes full benchmark list from bench/baseline.json", () => {
  const report = runAudit({})
  assert.ok(Array.isArray(report.telemetry.benchmarks))
  assert.ok(report.telemetry.benchmarks.length >= 90)
  assert.ok(report.telemetry.benchmarkSuiteCount >= 13)
})

test("all-green Lighthouse categories do not emit backwards passing opportunities", () => {
  const report = runAudit({})
  const allGreen = report.categories.every((c) => c.score >= 90)
  if (allGreen) {
    assert.equal(report.opportunities.length, 0)
  }
})
