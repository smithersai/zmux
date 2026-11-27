#!/usr/bin/env node
/**
 * Bounded, deterministic zmux JSON-RPC 2.0 & Scrollback Ring-Buffer Playground Runner.
 *
 * Implements the zmux v0.4.0 wire contract (decisions D1-D6) for interactive
 * inspection inside Smithers Cloud sandboxed iframes and static docs playgrounds:
 *   - Accepts {"request": "<json>"} or {"frame": "<json>"} or {"mode": "ringbuffer", ...}
 *   - JSON-RPC 2.0 frame parsing, nesting/size bounds, and ID validation
 *   - Error code + error.data.kind mapping (-32700, -32600, -32601, -32602, -32000, -32603)
 *   - command.exec grammar validation (split-window, new-window, respawn-pane)
 *   - Bounded circular scrollback ring-buffer replay & offset calculation
 *
 * Never spawns host processes, never touches host sockets, and accepts strictly
 * bounded JSON input on argv[2].
 */

const MAX_REQUEST_BYTES = 16 * 1024
const MAX_JSON_DEPTH = 32
const PROTOCOL_VERSION = "0.5.0"

const KNOWN_METHODS = new Set([
  "daemon.ping",
  "daemon.shutdown",
  "mux.snapshot",
  "session.create",
  "session.info",
  "session.list",
  "session.terminate",
  "session.resize",
  "session.capture",
  "session.screen",
  "session.send",
  "session.sendKey",
  "session.rename",
  "window.new",
  "window.select",
  "window.rename",
  "window.close",
  "pane.split",
  "pane.select",
  "pane.rename",
  "pane.respawn",
  "pane.wait",
  "pane.exec",
  "pane.signal",
  "pane.close",
  "pane.resizeSplit",
  "pane.zoom",
  "pane.metadata",
  "pane.record",
  "client.attach",
  "client.detach",
  "client.switch",
  "client.list",
  "client.setMode",
  "events.subscribe",
  "key.bind",
  "key.dispatch",
  "key.list",
  "command.exec"
])

const ALLOWED_COMMANDS = new Set(["split-window", "new-window", "respawn-pane"])

function measureDepth(value, current = 0) {
  if (current > MAX_JSON_DEPTH) return current
  if (value === null || typeof value !== "object") return current
  if (Array.isArray(value)) {
    let max = current + 1
    for (const item of value) {
      const d = measureDepth(item, current + 1)
      if (d > max) max = d
      if (max > MAX_JSON_DEPTH) return max
    }
    return max
  }
  let max = current + 1
  for (const val of Object.values(value)) {
    const d = measureDepth(val, current + 1)
    if (d > max) max = d
    if (max > MAX_JSON_DEPTH) return max
  }
  return max
}

function rpcError(id, code, message, kind) {
  return {
    jsonrpc: "2.0",
    id: id ?? null,
    error: { code, message, data: { kind } }
  }
}

export function simulateRingBuffer({ capacity = 64, chunks = [] }) {
  const cap = Math.max(8, Math.min(65536, Number(capacity) || 64))
  let totalWritten = 0
  let buffer = ""
  const events = []

  for (const raw of chunks.slice(0, 64)) {
    const text = String(raw)
    const offset = totalWritten
    totalWritten += Buffer.byteLength(text, "utf8")
    buffer += text
    if (buffer.length > cap) {
      buffer = buffer.slice(buffer.length - cap)
    }
    events.push({
      jsonrpc: "2.0",
      method: "pane_output",
      params: {
        pane_id: "pane-1",
        data_base64: Buffer.from(text, "utf8").toString("base64"),
        offset,
        generation: 1
      }
    })
  }

  return {
    capacity: cap,
    totalBytesWritten: totalWritten,
    retainedBytes: Buffer.byteLength(buffer, "utf8"),
    evictedBytes: Math.max(0, totalWritten - Buffer.byteLength(buffer, "utf8")),
    replayEndOffset: totalWritten,
    replayText: buffer,
    replayBase64: Buffer.from(buffer, "utf8").toString("base64"),
    notifications: events
  }
}

export function simulateSessionTrace({
  sessionId = "work",
  command = "/bin/sh",
  input = "echo hello-smithers",
  scrollbackBytes = 4096
} = {}) {
  const safeName = String(sessionId || "work").slice(0, 64)
  const safeCmd = String(command || "/bin/sh").slice(0, 128)
  const safeInput = String(input || "echo hello-smithers").slice(0, 512)
  const cap = Math.max(64, Math.min(64 * 1024 * 1024, Number(scrollbackBytes) || 4096))

  const banner = `zmux 0.4.0 [${safeName}] (${safeCmd})\r\n$ `
  const bannerBytes = Buffer.byteLength(banner, "utf8")
  const echoed = `${safeInput}\r\n${safeInput.replace(/^echo\s+/i, "")}\r\n$ `
  const echoedBytes = Buffer.byteLength(echoed, "utf8")
  const totalGen1Bytes = bannerBytes + echoedBytes
  const combined = (banner + echoed).slice(-cap)

  const paneOutputNotif = {
    jsonrpc: "2.0",
    method: "pane_output",
    params: {
      pane_id: "pane-1",
      data_base64: Buffer.from(echoed, "utf8").toString("base64"),
      offset: bannerBytes,
      generation: 1
    }
  }
  const respawnNotif = {
    jsonrpc: "2.0",
    method: "pane_respawned",
    params: { pane_id: "pane-1", generation: 2, pid: 42801 }
  }
  const exitNotif = {
    jsonrpc: "2.0",
    method: "session_exited",
    params: { session_id: "session-1", pane_id: "pane-1", exit_code: 0, signal: null, generation: 2 }
  }

  const steps = [
    {
      step: 1,
      method: "session.create",
      request: { jsonrpc: "2.0", id: 1, method: "session.create", params: { id: safeName, rows: 40, cols: 120, command: safeCmd, scrollbackBytes: cap } },
      response: { jsonrpc: "2.0", id: 1, result: { sessionId: "session-1", windowId: "window-1", paneId: "pane-1", generation: 1 } }
    },
    {
      step: 2,
      method: "client.attach",
      request: { jsonrpc: "2.0", id: 2, method: "client.attach", params: { target: safeName, createIfMissing: false, rows: 40, cols: 120 } },
      response: {
        jsonrpc: "2.0",
        id: 2,
        result: {
          clientId: "client-1",
          sessionId: "session-1",
          paneId: "pane-1",
          created: false,
          generation: 1,
          replayBase64: Buffer.from(banner, "utf8").toString("base64"),
          replayEndOffset: bannerBytes
        }
      }
    },
    {
      step: 3,
      method: "session.send",
      request: { jsonrpc: "2.0", id: 3, method: "session.send", params: { target: "pane-1", data: `${safeInput}\n` } },
      response: { jsonrpc: "2.0", id: 3, result: { ok: true, bytesWritten: Buffer.byteLength(`${safeInput}\n`, "utf8") } },
      notification: paneOutputNotif
    },
    {
      step: 4,
      method: "session.capture",
      request: { jsonrpc: "2.0", id: 4, method: "session.capture", params: { target: "pane-1", lines: 20 } },
      response: {
        jsonrpc: "2.0",
        id: 4,
        result: {
          paneId: "pane-1",
          text: combined,
          textBase64: Buffer.from(combined, "utf8").toString("base64"),
          generation: 1,
          endOffset: totalGen1Bytes
        }
      }
    },
    {
      step: 5,
      method: "pane.respawn",
      request: { jsonrpc: "2.0", id: 5, method: "pane.respawn", params: { target: "pane-1", kill: true } },
      response: { jsonrpc: "2.0", id: 5, result: { paneId: "pane-1", generation: 2, pid: 42801 } },
      notification: respawnNotif
    },
    {
      step: 6,
      method: "session.terminate",
      request: { jsonrpc: "2.0", id: 6, method: "session.terminate", params: { target: "session-1" } },
      response: { jsonrpc: "2.0", id: 6, result: { ok: true, terminated: "session-1" } },
      notification: exitNotif
    }
  ]

  return {
    sessionName: safeName,
    scrollbackCapacity: cap,
    replayEndOffset: bannerBytes,
    totalBytesStreamed: totalGen1Bytes,
    finalGeneration: 2,
    steps,
    notifications: [paneOutputNotif, respawnNotif, exitNotif]
  }
}

export function executePlaygroundRequest(input) {
  const mode = input?.mode ?? "rpc"
  if (mode === "ringbuffer") {
    return {
      ok: true,
      mode: "ringbuffer",
      contract: "zmux v0.4.0 scrollback ring buffer",
      result: simulateRingBuffer({ capacity: input.capacity, chunks: input.chunks })
    }
  }
  if (mode === "session_trace") {
    const trace = simulateSessionTrace({
      sessionId: input.sessionId,
      command: input.command,
      input: input.input,
      scrollbackBytes: input.scrollbackBytes
    })
    return {
      ok: true,
      mode: "session_trace",
      contract: "zmux v0.4.0 D1-D6 end-to-end session lifecycle",
      response: trace,
      notifications: trace.notifications,
      notes: [
        "Decision D1: pane_output streams only to attached or subscribed clients with monotonic offset and generation.",
        "Decision D4: client.attach returns replayEndOffset so live bytes below it are discarded without gaps or duplicates.",
        "Decision D4: pane.respawn with kill=true emits pane_respawned advancing generation 1 -> 2 before any gen-2 output.",
        "Decision D5: session names remain unique across the daemon until terminated."
      ]
    }
  }

  const rawFrame = typeof input?.request === "string"
    ? input.request
    : typeof input?.frame === "string"
      ? input.frame
      : ""

  if (Buffer.byteLength(rawFrame, "utf8") > MAX_REQUEST_BYTES) {
    return {
      ok: false,
      mode: "rpc",
      wireValid: false,
      response: rpcError(null, -32600, "FrameTooLarge", "invalid_request"),
      notifications: [],
      notes: ["Line exceeds bounded playground frame cap (16 KiB)."]
    }
  }
  if (rawFrame.includes("\n")) {
    return {
      ok: false,
      mode: "rpc",
      wireValid: false,
      response: rpcError(null, -32700, "MultilineFrameRejected", "parse"),
      notifications: [],
      notes: ["zmux UNIX socket frames must be one JSON document per physical line terminated by \\n."]
    }
  }

  let parsed
  try {
    parsed = JSON.parse(rawFrame)
  } catch {
    return {
      ok: false,
      mode: "rpc",
      wireValid: false,
      response: rpcError(null, -32700, "ParseError", "parse"),
      notifications: [],
      notes: ["Decision D2: malformed JSON always returns -32700 with data.kind = parse."]
    }
  }

  if (Array.isArray(parsed)) {
    return {
      ok: false,
      mode: "rpc",
      wireValid: false,
      response: rpcError(null, -32600, "BatchNotSupported", "invalid_request"),
      notifications: [],
      notes: ["Valid JSON arrays are rejected as unsupported batches (-32600 invalid_request)."]
    }
  }

  if (measureDepth(parsed) > MAX_JSON_DEPTH) {
    return {
      ok: false,
      mode: "rpc",
      wireValid: false,
      response: rpcError(null, -32600, "NestingLimitExceeded", "invalid_request"),
      notifications: [],
      notes: ["Decision D2: JSON nesting depth is bounded before dispatch."]
    }
  }

  // Note: zmuxd accepts jsonrpc omitted or "2.0" when a valid method is supplied.
  if (
    parsed === null ||
    typeof parsed !== "object" ||
    (parsed.jsonrpc !== undefined && parsed.jsonrpc !== "2.0") ||
    typeof parsed.method !== "string"
  ) {
    return {
      ok: false,
      mode: "rpc",
      wireValid: false,
      response: rpcError(null, -32600, "InvalidRequest", "invalid_request"),
      notifications: [],
      notes: ["Requests require a string method and optional jsonrpc: \"2.0\"."]
    }
  }

  const hasId = Object.prototype.hasOwnProperty.call(parsed, "id")
  if (hasId) {
    const id = parsed.id
    const validId = id === null || typeof id === "string" || (typeof id === "number" && Number.isInteger(id))
    if (!validId) {
      return {
        ok: false,
        mode: "rpc",
        wireValid: false,
        response: rpcError(null, -32600, "InvalidRequestId", "invalid_request"),
        notifications: [],
        notes: ["Decision D2: request IDs must be string, integer, or null."]
      }
    }
  }

  const params = parsed.params
  if (params !== undefined) {
    const validParams =
      (typeof params === "object" && params !== null && !Array.isArray(params)) ||
      (Array.isArray(params) && params.length === 0)
    if (!validParams) {
      return {
        ok: false,
        mode: "rpc",
        wireValid: true,
        response: hasId ? rpcError(parsed.id, -32602, "InvalidParams", "invalid_params") : null,
        notifications: [],
        notes: ["An empty array [] reads as no params, while non-empty arrays or scalars return InvalidParams (-32602)."]
      }
    }
  }

  if (!KNOWN_METHODS.has(parsed.method)) {
    return {
      ok: false,
      mode: "rpc",
      wireValid: true,
      response: hasId ? rpcError(parsed.id, -32601, "MethodNotFound", "method_not_found") : null,
      notifications: [],
      notes: [`Unknown method "${parsed.method}".`]
    }
  }

  const p = Array.isArray(params) || params === undefined ? {} : params
  let result
  const notifications = []
  const notes = []

  switch (parsed.method) {
    case "daemon.ping":
      result = {
        ok: true,
        version: PROTOCOL_VERSION,
        pid: 42420,
        socketPath: "/tmp/zmux-sandbox/sessions.sock",
        sessions: 1,
        panes: 2
      }
      notes.push("Reports live protocol version, daemon PID, resolved socket path, and separate session/pane counts.")
      break
    case "command.exec": {
      const cmdLine = String(p.command ?? "").trim()
      const verb = cmdLine.split(/\s+/)[0] || ""
      if (!ALLOWED_COMMANDS.has(verb)) {
        return {
          ok: false,
          mode: "rpc",
          wireValid: true,
          response: hasId ? rpcError(parsed.id, -32602, "InvalidParams", "invalid_params") : null,
          notifications: [],
          notes: ["command.exec accepts only split-window, new-window, and respawn-pane."]
        }
      }
      result = { ok: true, command: verb, paneId: "pane-2", generation: 1 }
      notes.push(`Validated tmux-like command verb "${verb}".`)
      break
    }
    case "session.create": {
      const name = String(p.id ?? p.name ?? p.title ?? "work")
      if (name === "duplicate") {
        return {
          ok: false,
          mode: "rpc",
          wireValid: true,
          response: hasId ? rpcError(parsed.id, -32000, "DuplicateSessionName", "conflict") : null,
          notifications: [],
          notes: ["Decision D5: session names are unique. Duplicates return -32000 with data.kind = conflict."]
        }
      }
      const scrollback = Number(p.scrollbackBytes ?? 10 * 1024 * 1024)
      if (scrollback > 64 * 1024 * 1024 || scrollback < 0) {
        return {
          ok: false,
          mode: "rpc",
          wireValid: true,
          response: hasId ? rpcError(parsed.id, -32000, "ScrollbackLimitExceeded", "limit") : null,
          notifications: [],
          notes: ["scrollbackBytes defaults to 10 MiB and must be 64 MiB or smaller."]
        }
      }
      result = { sessionId: "session-1", windowId: "window-1", paneId: "pane-1", generation: 1 }
      notes.push(
        p.clearEnv === true
          ? "Decision D3: clearEnv=true replaces daemon environment and defaults unset TERM to xterm-256color."
          : "Decision D3: env merges over daemon environment and defaults unset TERM to xterm-256color."
      )
      break
    }
    case "client.attach": {
      const target = String(p.target ?? p.session ?? p.paneId ?? "work")
      const created = Boolean(p.createIfMissing)
      const replay = "zmux 0.4.0 session ready\r\n$ "
      result = {
        clientId: "client-1",
        sessionId: "session-1",
        paneId: target.startsWith("pane-") ? target : "pane-1",
        created,
        exited: false,
        exitCode: null,
        signal: null,
        generation: 1,
        replayBase64: Buffer.from(replay, "utf8").toString("base64"),
        replayEndOffset: Buffer.byteLength(replay, "utf8")
      }
      notes.push("Decision D4: client discards live pane_output bytes below replayEndOffset in the same generation.")
      break
    }
    case "events.subscribe": {
      const panes = Array.isArray(p.panes) ? p.panes : ["*"]
      result = { subscribed: panes }
      notifications.push({
        jsonrpc: "2.0",
        method: "pane_output",
        params: {
          pane_id: "pane-1",
          data_base64: Buffer.from("hello from zmuxd\n", "utf8").toString("base64"),
          offset: 28,
          generation: 1
        }
      })
      notes.push("Decision D1: pane_output streams only to attached or explicitly subscribed connections with offset and generation.")
      break
    }
    case "pane.split":
      result = { sessionId: "session-1", windowId: "window-1", paneId: "pane-2", generation: 1 }
      notes.push("Splits active window and returns compact {sessionId, windowId, paneId, generation}.")
      break
    case "pane.respawn":
      if (p.kill !== true) {
        return {
          ok: false,
          mode: "rpc",
          wireValid: true,
          response: hasId ? rpcError(parsed.id, -32000, "PaneRunning", "conflict") : null,
          notifications: [],
          notes: ["Decision D4: pane.respawn defaults to kill=false and refuses a running pane until kill=true."]
        }
      }
      result = { paneId: "pane-1", generation: 2, pid: 42801 }
      notifications.push({
        jsonrpc: "2.0",
        method: "pane_respawned",
        params: { pane_id: "pane-1", generation: 2, pid: 42801 }
      })
      notes.push("Respawn announcement is ordered before any output from generation 2.")
      break
    case "session.capture": {
      const text = "zmux 0.4.0 scrollback snapshot\n$ zig build test\n468/477 tests passed\n"
      result = {
        paneId: "pane-1",
        text,
        textBase64: Buffer.from(text, "utf8").toString("base64"),
        generation: 1
      }
      notes.push("text replaces invalid UTF-8 with U+FFFD while textBase64 preserves raw PTY bytes.")
      break
    }
    case "mux.snapshot":
      result = {
        sessions: [
          {
            id: "session-1",
            name: "work",
            activeWindowId: "window-1",
            windows: [
              {
                id: "window-1",
                name: "dev",
                activePaneId: "pane-1",
                panes: [
                  {
                    id: "pane-1",
                    generation: 1,
                    rows: 40,
                    cols: 120,
                    alerts: { activity: true, bell: false, exited: false, lastActivityMs: 1795765000000, lastBellMs: 0 }
                  }
                ]
              }
            ]
          }
        ],
        clients: [{ id: "client-1", paneId: "pane-1" }]
      }
      notes.push("Exposes full server-owned session, window, pane, layout, client, key binding, and alert state.")
      break
    default:
      result = { ok: true, method: parsed.method, params: p }
      notes.push(`Validated method ${parsed.method} against zmux ${PROTOCOL_VERSION} JSON-RPC wire contract.`)
  }

  return {
    ok: true,
    mode: "rpc",
    wireValid: true,
    isNotification: !hasId,
    response: hasId ? { jsonrpc: "2.0", id: parsed.id, result } : null,
    notifications,
    notes: hasId ? notes : [...notes, "Decision D2: requests without an id are notifications and receive no response."]
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const rawArg = process.argv[2] ?? "{}"
  try {
    const payload = JSON.parse(rawArg)
    process.stdout.write(`${JSON.stringify(executePlaygroundRequest(payload))}\n`)
  } catch (err) {
    process.stdout.write(`${JSON.stringify({ ok: false, error: err instanceof Error ? err.message : String(err) })}\n`)
    process.exitCode = 1
  }
}
