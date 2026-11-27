import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import test from "node:test"
import { executePlaygroundRequest, simulateRingBuffer } from "./run.mjs"

const here = dirname(fileURLToPath(import.meta.url))

test("daemon.ping returns protocol version 0.4.0", () => {
  const out = executePlaygroundRequest({
    mode: "rpc",
    frame: '{"jsonrpc":"2.0","id":1,"method":"daemon.ping"}'
  })
  assert.equal(out.ok, true)
  assert.equal(out.response.result.version, "0.4.0")
})

test("malformed JSON returns -32700 parse error", () => {
  const out = executePlaygroundRequest({
    mode: "rpc",
    frame: '{"jsonrpc":"2.0","id":1,"method":'
  })
  assert.equal(out.ok, false)
  assert.equal(out.response.error.code, -32700)
  assert.equal(out.response.error.data.kind, "parse")
})

test("DuplicateSessionName maps to -32000 conflict", () => {
  const out = executePlaygroundRequest({
    mode: "rpc",
    frame: '{"jsonrpc":"2.0","id":7,"method":"session.create","params":{"id":"duplicate"}}'
  })
  assert.equal(out.ok, false)
  assert.equal(out.response.error.code, -32000)
  assert.equal(out.response.error.data.kind, "conflict")
})

test("events.subscribe returns pane_output notification with offset and generation", () => {
  const out = executePlaygroundRequest({
    mode: "rpc",
    frame: '{"jsonrpc":"2.0","id":4,"method":"events.subscribe","params":{"panes":["*"]}}'
  })
  assert.equal(out.ok, true)
  assert.equal(out.notifications.length, 1)
  assert.equal(out.notifications[0].method, "pane_output")
  assert.equal(out.notifications[0].params.generation, 1)
})

test("ring buffer evicts oldest bytes beyond capacity", () => {
  const res = simulateRingBuffer({ capacity: 10, chunks: ["123456", "7890abcd"] })
  assert.equal(res.totalBytesWritten, 14)
  assert.equal(res.retainedBytes, 10)
  assert.equal(res.evictedBytes, 4)
  assert.equal(res.replayText, "567890abcd")
})

test("index.html CSP script-src and style-src SHA-256 hashes match inline blocks exactly", () => {
  const html = readFileSync(join(here, "index.html"), "utf8")
  const styleMatch = html.match(/<style>([\s\S]*?)<\/style>/)
  const scriptMatch = html.match(/<script>([\s\S]*?)<\/script>/)
  assert.ok(styleMatch, "missing <style> block")
  assert.ok(scriptMatch, "missing <script> block")

  const styleHash = createHash("sha256").update(styleMatch[1], "utf8").digest("base64")
  const scriptHash = createHash("sha256").update(scriptMatch[1], "utf8").digest("base64")

  assert.ok(html.includes(`style-src 'sha256-${styleHash}'`), `CSP style-src hash mismatch; expected sha256-${styleHash}`)
  assert.ok(html.includes(`script-src 'sha256-${scriptHash}'`), `CSP script-src hash mismatch; expected sha256-${scriptHash}`)
})
