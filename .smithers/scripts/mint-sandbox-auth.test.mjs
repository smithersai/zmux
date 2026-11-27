import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"
import { base64Url, buildBundle, generatePkceBundle, readMode600Cookie } from "./mint-sandbox-auth.mjs"

test("generatePkceBundle creates valid RFC 7636 S256 challenge and 300s TTL", () => {
  const pkce = generatePkceBundle()
  assert.equal(pkce.oneTimeUse, true)
  assert.equal(pkce.codeChallengeMethod, "S256")
  assert.equal(pkce.ttlSeconds, 300)
  const expected = base64Url(createHash("sha256").update(pkce.codeVerifier).digest())
  assert.equal(pkce.codeChallenge, expected)
})

test("buildBundle defaults untrusted and never leaks SMITHERS_CACHE_WRITE_TOKEN", () => {
  const prev = process.env.SMITHERS_CACHE_WRITE_TOKEN
  process.env.SMITHERS_CACHE_WRITE_TOKEN = "secret-write-token-must-never-appear"
  try {
    const bundle = buildBundle({ trusted: false }, null)
    const serialized = JSON.stringify(bundle)
    assert.equal(bundle.trust.level, "untrusted")
    assert.equal(bundle.trust.canPublishCache, false)
    assert.equal(bundle.trust.canSatisfyMergeGates, false)
    assert.equal(bundle.sandboxEnv.SMITHERS_CACHE_MODE, "read-only")
    assert.equal(bundle.sandboxEnv.SMITHERS_CACHE_WRITE_TOKEN, undefined)
    assert.ok(!serialized.includes("secret-write-token-must-never-appear"))
  } finally {
    if (prev === undefined) delete process.env.SMITHERS_CACHE_WRITE_TOKEN
    else process.env.SMITHERS_CACHE_WRITE_TOKEN = prev
  }
})

test("readMode600Cookie rejects world/group-readable cookie files", () => {
  const dir = mkdtempSync(join(tmpdir(), "zmux-auth-test-"))
  const file = join(dir, "cookie")
  try {
    writeFileSync(file, "session=abc123\n")
    chmodSync(file, 0o644)
    assert.throws(() => readMode600Cookie(file), /must be mode 0600/)
    chmodSync(file, 0o600)
    assert.equal(readMode600Cookie(file), "session=abc123")
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})
