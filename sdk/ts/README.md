# @smithers/zmux

Zero-dependency TypeScript SDK, browser `xterm.js` adapter, and authenticated WebSocket and HTTP/SSE bridge for [zmux](https://github.com/smithersai/zmux). Runs natively in Bun and Node 22+ with zero external runtime dependencies.

## Features

- Full typed `ZmuxClient` covering all 28 v0.4.0 D1-D6 JSON-RPC methods and 11 additive v0.5.0/v0.6.0 helpers
- Exact socket path parity with `src/socket_path.zig` (`override > ZMUX_SOCKET > SMITHERS_SESSION_SOCKET > XDG_RUNTIME_DIR > HOME > /tmp/zmux-<uid>/sessions.sock`) and `sun_path` byte-length validation
- Bounded 16 MiB NDJSON frame parser with request correlation, per-call timeouts, `AbortSignal` cancellation, and optional `zmuxd` auto-spawn
- High-level `AttachedPane` with exact `replayBase64` / `replayEndOffset` / `generation` deduplication, async output streaming, `waitFor()`, and seamless `reconnect()`
- `zmux-ws` authenticated WebSocket, HTTP `/rpc`, and SSE `/events` bridge using pure RFC 6455 framing, constant-time bearer tokens, loopback bind by default, and strict `Origin` allowlisting
- `@smithers/zmux/xterm` browser adapter for `xterm.js` and `ghostty-web` with exponential-backoff reconnect and offset resumption

## Quickstart

```ts
import { ZmuxClient } from "@smithers/zmux";

const client = await ZmuxClient.connect({ spawnDaemon: true });
const ping = await client.ping();
console.log("zmuxd", ping.version, "pid", ping.pid);

const pane = await client.attachPane({
  paneId: "build",
  createIfMissing: { id: "build", rows: 30, cols: 100 },
});

await pane.send("echo ready-from-zmux", true);
const match = await pane.waitFor({ pattern: "ready-from-zmux", timeoutMs: 5000 });
console.log("matched:", match.match);

await pane.detach();
client.close();
```

## Browser xterm.js Adapter

Start the local authenticated bridge with the demo UI enabled:

```sh
zmux-ws --spawn-daemon --demo
```

Attach an `xterm.js` or `ghostty-web` terminal in the browser:

```ts
import { attachXterm } from "@smithers/zmux/xterm";

const handle = attachXterm(terminal, {
  url: "ws://127.0.0.1:7681/ws",
  token,
  target: "work",
  createIfMissing: { id: "work" },
  onStatus(status) {
    console.log("connection status:", status);
  },
});
```

## Bridge Security Defaults

`zmux-ws` is locked down by default:

- Binds to `127.0.0.1:7681` unless `--host` is explicitly configured
- Generates a random 32-byte bearer token if `--token` and `ZMUX_WS_TOKEN` are omitted, verified with `crypto.timingSafeEqual`
- Rejects cross-origin requests outside `localhost`, `127.0.0.1`, and `[::1]` unless explicitly permitted with `--allow-origin`
- Enforces payload size caps and per-client backpressure protection on `/ws`, `/rpc`, and `/events`

## Running Tests

```sh
cd sdk/ts
bun test test/
```
