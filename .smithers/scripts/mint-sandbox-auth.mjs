#!/usr/bin/env node
/**
 * Print one-time-use, attenuated authentication bootstrap bundles for
 * smithersai/zmux sandboxes and coding agents.
 *
 * Security invariants:
 * - Never reads or prints SMITHERS_CACHE_WRITE_TOKEN, GitHub PATs, or browser
 *   session cookies onto stdout or into sandbox environments.
 * - Generates a fresh single-use OAuth 2.1 + PKCE (S256) challenge/verifier
 *   and state bound to https://smithers.sh/smithersai/zmux/mcp (TTL 300s).
 * - Optionally exchanges a mode-0600 session cookie file (never argv) with
 *   POST /api/runs/<runId>/credential to print a short-lived attenuated
 *   `act: "sandbox"` bearer token with narrowed capability ceilings.
 * - Always binds untrusted sandboxes to read-only object store access on
 *   https://build.smithers.sh so untrusted runs never poison cache or skip gates.
 */

import { createHash, randomBytes } from "node:crypto"
import { readFileSync, statSync } from "node:fs"

const REPO = "smithersai/zmux"
const ORIGIN = (process.env.SMITHERS_CLOUD_ORIGIN || "https://smithers.sh").replace(/\/+$/, "")
const MCP_URL = `${ORIGIN}/${REPO}/mcp`
const DISCOVERY_URL = `${ORIGIN}/.well-known/oauth-protected-resource/${REPO}/mcp`
const AUTH_SERVER_URL = `${ORIGIN}/.well-known/oauth-authorization-server`
const OBJECT_STORE = "https://build.smithers.sh"

function base64Url(buf) {
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function generatePkceBundle() {
  const verifier = base64Url(randomBytes(32))
  const challenge = base64Url(createHash("sha256").update(verifier).digest())
  const state = base64Url(randomBytes(24))
  const nonce = base64Url(randomBytes(16))
  const expiresAt = new Date(Date.now() + 300 * 1000).toISOString()
  return {
    protocol: "oauth-2.1-pkce-s256",
    oneTimeUse: true,
    ttlSeconds: 300,
    expiresAt,
    mcpUrl: MCP_URL,
    protectedResourceMetadata: DISCOVERY_URL,
    authorizationServerMetadata: AUTH_SERVER_URL,
    scopes: ["mcp:read", "mcp:write"],
    codeVerifier: verifier,
    codeChallenge: challenge,
    codeChallengeMethod: "S256",
    state,
    nonce
  }
}

async function maybeMintRunCredential(runId, flow, cookieFile) {
  if (!runId || !cookieFile) return null
  const st = statSync(cookieFile)
  if ((st.mode & 0o077) !== 0) {
    throw new Error(`Refusing ${cookieFile}: session cookie file must be mode 0600`)
  }
  const cookie = readFileSync(cookieFile, "utf8").trim()
  if (!cookie) throw new Error("Session cookie file is empty")

  const endpoint = `${ORIGIN}/api/runs/${encodeURIComponent(runId)}/credential`
  const res = await fetch(endpoint, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      cookie
    },
    body: JSON.stringify({
      flow: flow || "checks/review",
      ceiling: [["fs:read:**", "proc:spawn:zig *", "proc:spawn:smthrs *", "proc:spawn:uphill *"]]
    })
  })
  if (!res.ok) {
    throw new Error(`Credential mint failed with HTTP ${res.status}`)
  }
  const body = await res.json()
  return {
    minted: true,
    act: "sandbox",
    runId,
    flow: flow || "checks/review",
    token: body.token ?? null,
    expiresAt: body.expiresAt ?? null
  }
}

function buildBundle(options, runCredential) {
  const pkce = generatePkceBundle()
  const trustLevel = options.trusted ? "trusted" : "untrusted"
  const env = {
    SMITHERS_CLOUD_ORIGIN: ORIGIN,
    SMITHERS_MCP_URL: MCP_URL,
    SMITHERS_CACHE_URL: OBJECT_STORE,
    SMITHERS_TRUST_LEVEL: trustLevel,
    SMITHERS_CACHE_MODE: options.trusted ? "read-write" : "read-only",
    SMITHERS_OAUTH_STATE: pkce.state,
    SMITHERS_OAUTH_CODE_CHALLENGE: pkce.codeChallenge,
    SMITHERS_OAUTH_CODE_CHALLENGE_METHOD: pkce.codeChallengeMethod
  }
  if (process.env.SMITHERS_CACHE_READ_TOKEN) {
    env.SMITHERS_CACHE_READ_TOKEN = "[BOUND_VIA_EGRESS_PROXY]"
  }

  return {
    schema: "zmux.sandbox.auth.v1",
    repository: REPO,
    generatedAt: new Date().toISOString(),
    trust: {
      level: trustLevel,
      canPublishCache: Boolean(options.trusted),
      canSatisfyMergeGates: Boolean(options.trusted),
      writeTokensRedacted: true,
      personOnlyActionsBlocked: [
        "pull/merge",
        "issue/triage",
        "issue/commitment",
        "todo/commit",
        "secrets/write"
      ]
    },
    oneTimeAuth: pkce,
    runCredential,
    sandboxEnv: env,
    mcpClients: {
      claude: `claude mcp add zmux --transport http ${MCP_URL}`,
      codex: `codex mcp add zmux --url ${MCP_URL}`,
      agy: `agy mcp add zmux --transport http ${MCP_URL}`,
      cursor: { mcpServers: { zmux: { url: MCP_URL } } }
    },
    agentPrompt:
      `Connect to the Smithers Cloud MCP server at ${MCP_URL} (OAuth 2.1 PKCE, single-use challenge ${pkce.codeChallenge.slice(0, 12)}...). ` +
      `Use Smithers MCP tools (repo_*, docs_*, flows_*, issues_*, pulls_*, todo_*, work_link_post) for all issues, TODOs, PRs, artifacts, and stacked changesets. ` +
      `Run checks via smthrs ci '//...' and uphill --compact with read-only object store access at ${OBJECT_STORE}.`
  }
}

async function main() {
  const args = process.argv.slice(2)
  const format = args.includes("--shell") ? "shell" : "json"
  const runIdx = args.indexOf("--run-id")
  const flowIdx = args.indexOf("--flow")
  const cookieIdx = args.indexOf("--cookie-file")
  const runId = runIdx >= 0 ? args[runIdx + 1] : undefined
  const flow = flowIdx >= 0 ? args[flowIdx + 1] : undefined
  const cookieFile = cookieIdx >= 0 ? args[cookieIdx + 1] : undefined

  let runCredential = null
  if (runId && cookieFile) {
    runCredential = await maybeMintRunCredential(runId, flow, cookieFile)
  }

  // Sandboxes default strictly to untrusted unless explicitly inside a
  // Smithers-controlled sandbox with a minted credential.
  const trusted = process.env.SMITHERS_CONTROLLED_SANDBOX === "1" && Boolean(runCredential?.minted)
  const bundle = buildBundle({ trusted }, runCredential)

  if (format === "shell") {
    const lines = [
      `# One-time-use sandbox auth bootstrap for ${REPO} (expires ${bundle.oneTimeAuth.expiresAt})`,
      ...Object.entries(bundle.sandboxEnv).map(([k, v]) => `export ${k}=${JSON.stringify(v)}`),
      `# Connect your agent over authenticated Cloud MCP:`,
      `# ${bundle.mcpClients.claude}`,
      `# ${bundle.mcpClients.codex}`,
      `# ${bundle.mcpClients.agy}`
    ]
    process.stdout.write(`${lines.join("\n")}\n`)
    return
  }

  process.stdout.write(`${JSON.stringify(bundle, null, 2)}\n`)
}

main().catch((err) => {
  process.stderr.write(`mint-sandbox-auth error: ${err instanceof Error ? err.message : String(err)}\n`)
  process.exit(1)
})
