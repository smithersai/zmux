#!/usr/bin/env node
/**
 * Deterministic contract validator for smithersai/zmux's Smithers Cloud
 * software factory:
 *   --factory   Verifies .smithers/factory.json against discovered flows and policy
 *   --home      Verifies .smithers/home.json against the @smthrs/views Home schema
 *   --trust     Verifies .smithers/trust-policy.json and CI cache/gate separation
 *   --wiki      Verifies .smithers/coding-project.json and .smithers/wiki/**
 *   --views     Exercises backpressure audit, protocol inspector, and sandbox-auth scripts
 */

import { execFileSync } from "node:child_process"
import { existsSync, readFileSync, readdirSync } from "node:fs"
import { join, relative, resolve } from "node:path"

const ROOT = resolve(process.cwd())
const HTML_TAG = /<\/?[A-Za-z!?]/
const FORBIDDEN_COPY = /[;—]/
const KNOWN_BLOCK_KINDS = new Set([
  "text", "links", "flows", "prompt", "markdown", "stack", "app", "view",
  "hero", "code", "cards", "stats", "releases", "issues", "runs", "action"
])
const AUDIENCES = new Set(["everyone", "contributor", "maintainer"])

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}

function readJson(relPath) {
  const full = join(ROOT, relPath)
  assert(existsSync(full), `Missing required file: ${relPath}`)
  return JSON.parse(readFileSync(full, "utf8"))
}

function walkFlowFiles(dir, acc = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) {
      walkFlowFiles(full, acc)
    } else if (entry.name === "flow.mdx" || entry.name === "flow.ts") {
      acc.push(relative(ROOT, full).replace(/\\/g, "/"))
    }
  }
  return acc.sort()
}

function checkFactory() {
  const factory = readJson(".smithers/factory.json")
  assert(typeof factory.summary === "string" && factory.summary.length > 0 && factory.summary.length <= 140,
    "factory.json summary must be 1..140 chars")
  assert(!HTML_TAG.test(factory.summary), "factory.json summary must not contain HTML")
  assert(Array.isArray(factory.flows) && factory.flows.length > 0, "factory.json must declare flows")

  const discovered = new Set(walkFlowFiles(join(ROOT, ".smithers", "flows")))
  const declaredPaths = new Set()
  const declaredIds = new Set()

  for (const flow of factory.flows) {
    assert(typeof flow.id === "string" && flow.id.length > 0, "flow.id must be non-empty")
    assert(!declaredIds.has(flow.id), `duplicate flow id in factory.json: ${flow.id}`)
    declaredIds.add(flow.id)
    assert(existsSync(join(ROOT, flow.path)), `factory.json references missing flow file: ${flow.path}`)
    declaredPaths.add(flow.path)
  }

  for (const diskPath of discovered) {
    assert(declaredPaths.has(diskPath), `discovered flow not declared in .smithers/factory.json: ${diskPath}`)
  }

  for (const rule of factory.on ?? []) {
    const targets = Array.isArray(rule.flow) ? rule.flow : [rule.flow]
    for (const id of targets) {
      assert(declaredIds.has(id), `factory.json on-rule ${rule.event} targets unknown flow: ${id}`)
    }
  }

  assert(factory.github?.mirror === "push", "github.mirror must be 'push' for Smithers Cloud switchover")
  assert(factory.github?.changes === "land", "github.changes must be 'land' with mirror: 'push'")
  assert(factory.github?.issues === "two-way", "github.issues must be 'two-way'")
  assert(Array.isArray(factory.github?.maintainers) && factory.github.maintainers.includes("roninjin10"),
    "github.maintainers must include roninjin10")
  assert(existsSync(join(ROOT, ".smithers", "merge.json")), "Missing .smithers/merge.json")
}

function checkHome() {
  const home = readJson(".smithers/home.json")
  const factory = readJson(".smithers/factory.json")
  const flowIds = new Set((factory.flows ?? []).map((f) => f.id))

  assert(Array.isArray(home.sections) && home.sections.length >= 3 && home.sections.length <= 8,
    "home.json must declare 3..8 audience sections")
  assert(home.contributors === "role" || home.contributors === "anyone",
    "home.json contributors must be 'role' or 'anyone'")
  assert(typeof home.docs === "string" && /^https:\/\/[^\s<>"'@]+$/.test(home.docs),
    "home.json docs must be a valid https llms.txt URL")

  const seenAudiences = new Set()
  let totalBlocks = 0

  for (const section of home.sections) {
    assert(AUDIENCES.has(section.audience), `invalid section audience: ${section.audience}`)
    seenAudiences.add(section.audience)
    assert(Array.isArray(section.blocks) && section.blocks.length > 0, `section ${section.audience} needs blocks`)
    totalBlocks += section.blocks.length

    for (const block of section.blocks) {
      assert(KNOWN_BLOCK_KINDS.has(block.type), `unknown home block type: ${block.type}`)
      if (block.type === "view") {
        assert(flowIds.has(block.flow), `home.json view block references unknown flow: ${block.flow}`)
      }
      if (block.type === "code") {
        assert(typeof block.code === "string" && block.code.length > 0 && block.code.length <= 4096,
          "code block exceeds 4096 chars")
        continue
      }
      const strings = []
      const collectStrings = (v) => {
        if (typeof v === "string") strings.push(v)
        else if (Array.isArray(v)) v.forEach(collectStrings)
        else if (v && typeof v === "object") Object.values(v).forEach(collectStrings)
      }
      collectStrings(block)
      for (const s of strings) {
        assert(!HTML_TAG.test(s), `home.json block ${block.type} must not contain HTML: ${s}`)
        if (!/^https?:\/\//.test(s)) {
          assert(!FORBIDDEN_COPY.test(s), `home.json public copy must not contain semicolons or em dashes: ${s}`)
        }
      }
    }
  }

  assert(totalBlocks <= 32, `home.json declares ${totalBlocks} blocks (limit 32)`)
  for (const required of ["maintainer", "contributor", "everyone"]) {
    assert(seenAudiences.has(required), `home.json missing personalized audience section: ${required}`)
  }
}

function checkTrust() {
  const policy = readJson(".smithers/trust-policy.json")
  assert(policy.objectStore?.endpoint === "https://build.smithers.sh", "objectStore must point to build.smithers.sh")
  assert(policy.mcpEndpoint === "https://smithers.sh/smithersai/zmux/mcp", "mcpEndpoint must point to smithers.sh")
  assert(policy.executionPolicy?.untrusted?.allowExecution === true, "untrusted execution must be allowed")
  assert(policy.executionPolicy?.untrusted?.canWriteCache === false, "untrusted runs must never write cache")
  assert(policy.executionPolicy?.untrusted?.canSatisfyMergeGates === false, "untrusted runs must never skip gates")
  assert(policy.executionPolicy?.trusted?.canWriteCache === true, "trusted runs must publish to shared object store")
  assert(policy.executionPolicy?.trusted?.canSatisfyMergeGates === true, "trusted runs must satisfy merge gates")

  const ciYml = readFileSync(join(ROOT, ".github/workflows/ci.yml"), "utf8")
  assert(ciYml.includes("SMITHERS_CACHE_READ_TOKEN"), "ci.yml must bind read-only cache token")
  assert(ciYml.includes("SMITHERS_CACHE_WRITE_TOKEN"), "ci.yml must bind write cache token only on trusted main")
  assert(ciYml.includes("SMITHERS_CACHE_NAMESPACE"), "ci.yml must isolate PR runs via SMITHERS_CACHE_NAMESPACE")
  assert(!ciYml.includes("pull_request_target"), "ci.yml must never use pull_request_target")
  assert(ciYml.includes("refs/heads/main"), "ci.yml write cache token must be gated on refs/heads/main")
}

function checkWiki() {
  const project = readJson(".smithers/coding-project.json")
  assert(project.wiki === true, "coding-project.json must enable wiki")
  assert(Array.isArray(project.pages) && project.pages.length >= 6 && project.pages.length <= 30,
    "coding-project.json must declare 6..30 wiki pages")
  assert(existsSync(join(ROOT, ".smithers/wiki/README.md")), "Missing .smithers/wiki/README.md")

  const pageIds = new Set(project.pages.map((p) => p.id))
  const forbiddenSegments = /(^|\/)(\.env|Smithers-Ops|node_modules|\.git|\.jj|credentials\.json|secrets\.json)(\/|$)/i

  for (const page of project.pages) {
    assert(typeof page.id === "string" && page.id.length > 0, "wiki page missing id")
    assert(typeof page.document === "string" && page.document.startsWith(".smithers/wiki/pages/"),
      `wiki page ${page.id} document must live under .smithers/wiki/pages/`)
    const docFull = join(ROOT, page.document)
    assert(existsSync(docFull), `wiki page document missing: ${page.document}`)
    const md = readFileSync(docFull, "utf8")
    assert(md.trim().length >= 300, `wiki page ${page.document} is too short`)
    assert(Array.isArray(page.inputs) && page.inputs.length > 0, `wiki page ${page.id} must declare inputs`)
    for (const input of page.inputs) {
      assert(!forbiddenSegments.test(input), `forbidden input in wiki catalog: ${input}`)
      assert(existsSync(join(ROOT, input)), `wiki page ${page.id} cites missing input: ${input}`)
    }
    for (const rel of page.related ?? []) {
      assert(pageIds.has(rel), `wiki page ${page.id} links to unknown related page: ${rel}`)
    }
  }
}

function checkViews() {
  const auditOut = execFileSync(process.execPath, [".smithers/views/backpressure/run.mjs", '{"refresh":false}'], {
    cwd: ROOT,
    encoding: "utf8"
  })
  const audit = JSON.parse(auditOut)
  assert(audit.schema === "zmux.backpressure.lighthouse.v1", "backpressure runner schema mismatch")
  assert(audit.provenance?.trust === "untrusted" || audit.provenance?.trust === "trusted", "missing provenance trust")

  const protoOk = JSON.parse(execFileSync(
    process.execPath,
    [".smithers/playground/run.mjs", '{"request":"{\\"id\\":1,\\"method\\":\\"daemon.ping\\"}"}'],
    { cwd: ROOT, encoding: "utf8" }
  ))
  assert(protoOk.ok === true && protoOk.response?.result?.ok === true, "protocol inspector daemon.ping failed")

  const protoErr = JSON.parse(execFileSync(
    process.execPath,
    [".smithers/playground/run.mjs", '{"request":"{\\"id\\":2,\\"method\\":\\"command.exec\\",\\"params\\":{\\"command\\":\\"invalid-cmd\\"}}"}'],
    { cwd: ROOT, encoding: "utf8" }
  ))
  assert(protoErr.ok === false && protoErr.response?.error?.code === -32602, "protocol inspector error check failed")

  const authOut = JSON.parse(execFileSync(process.execPath, [".smithers/scripts/mint-sandbox-auth.mjs"], {
    cwd: ROOT,
    encoding: "utf8"
  }))
  assert(authOut.schema === "zmux.sandbox.auth.v1", "mint-sandbox-auth schema mismatch")
  assert(authOut.oneTimeAuth?.oneTimeUse === true, "sandbox auth must be one-time-use")
  assert(authOut.trust?.writeTokensRedacted === true, "sandbox auth must redact write tokens")
  assert(authOut.sandboxEnv?.SMITHERS_CACHE_WRITE_TOKEN === undefined, "sandbox auth must never print write token")

  execFileSync(
    process.execPath,
    [
      "--test",
      ".smithers/playground/run.test.mjs",
      ".smithers/views/backpressure/run.test.mjs",
      ".smithers/scripts/mint-sandbox-auth.test.mjs"
    ],
    {
      cwd: ROOT,
      stdio: "inherit"
    }
  )
}

const flags = new Set(process.argv.slice(2))
const runAll = flags.size === 0 || flags.has("--all")

const checks = [
  ["--factory", checkFactory],
  ["--home", checkHome],
  ["--trust", checkTrust],
  ["--wiki", checkWiki],
  ["--views", checkViews]
]

for (const [flag, fn] of checks) {
  if (runAll || flags.has(flag)) {
    fn()
    process.stdout.write(`ok: ${flag.slice(2)}\n`)
  }
}
