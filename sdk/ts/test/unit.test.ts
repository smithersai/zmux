import { describe, expect, test } from "bun:test";

import {
  AttachedPane,
  PaneStreamReconciler,
  type ZmuxPaneTransport,
} from "../src/attached-pane.ts";
import { isOriginAllowed, verifyBearerToken } from "../src/bridge.ts";
import { ZmuxFrameError, ZmuxRpcError } from "../src/errors.ts";
import { NdjsonFrameParser, decodeBase64, encodeBase64 } from "../src/framing.ts";
import {
  SocketPathError,
  absolutizeSocketPath,
  isDefaultManagedSocketPath,
  maxUnixPathLen,
  resolveSocketPath,
  resolveSocketPathUnvalidated,
  validateSocketPath,
} from "../src/socket-path.ts";
import type {
  AttachResult,
  ClientAttachParams,
  ZmuxNotification,
} from "../src/types.ts";
import {
  WS_CLOSE_CODE,
  WS_OPCODE,
  WsFrameDecoder,
  WsProtocolError,
  computeWebSocketAccept,
  encodeWsFrame,
} from "../src/ws-framing.ts";
import {
  attachXterm,
  type WebSocketLike,
  type XtermConnectionStatus,
  type XtermLike,
} from "../src/xterm.ts";

const enc = new TextEncoder();
const dec = new TextDecoder();

describe("NdjsonFrameParser & base64", () => {
  test("handles 1-byte chunks, multi-line bursts, CRLF, and split UTF-8", () => {
    const parser = new NdjsonFrameParser(1024);
    const payload = enc.encode('{"a":"héllo 🚀"}\r\n\n{"b":2}\n{"c":3}\n');
    const out: string[] = [];
    for (let i = 0; i < payload.byteLength; i += 1) {
      out.push(...parser.push(payload.subarray(i, i + 1)));
    }
    expect(out).toEqual(['{"a":"héllo 🚀"}', '{"b":2}', '{"c":3}']);
    expect(parser.pendingBytes).toBe(0);
  });

  test("enforces maxFrameBytes on complete and incomplete lines", () => {
    const parser = new NdjsonFrameParser(16);
    expect(() => parser.push("12345678901234567")).toThrow(ZmuxFrameError);
    expect(parser.pendingBytes).toBe(0);
    expect(parser.push('{"ok":true}\n')).toEqual(['{"ok":true}']);
    expect(() => parser.push("12345678901234567\n")).toThrow(ZmuxFrameError);
  });

  test("roundtrips arbitrary binary through base64", () => {
    const raw = new Uint8Array(256);
    for (let i = 0; i < 256; i += 1) raw[i] = i;
    const b64 = encodeBase64(raw);
    expect(decodeBase64(b64)).toEqual(raw);
    expect(decodeBase64("")).toEqual(new Uint8Array(0));
  });
});

describe("socket-path parity with src/socket_path.zig", () => {
  test("follows override > ZMUX_SOCKET > SMITHERS_SESSION_SOCKET > XDG > HOME > uid fallback", () => {
    const uid = 501;
    expect(resolveSocketPath(null, { env: {}, uid })).toBe("/tmp/zmux-501/sessions.sock");
    expect(resolveSocketPath(null, { env: { HOME: "/home/u" }, uid })).toBe(
      "/home/u/.smithers/sessions.sock",
    );
    expect(
      resolveSocketPath(null, {
        env: { HOME: "/home/u", XDG_RUNTIME_DIR: "/run/user/7/" },
        uid,
      }),
    ).toBe("/run/user/7/smithers-sessions.sock");
    expect(
      resolveSocketPath(null, {
        env: {
          HOME: "/home/u",
          XDG_RUNTIME_DIR: "/run/user/7",
          SMITHERS_SESSION_SOCKET: "/s/smithers.sock",
        },
        uid,
      }),
    ).toBe("/s/smithers.sock");
    expect(
      resolveSocketPath(null, {
        env: {
          HOME: "/home/u",
          XDG_RUNTIME_DIR: "/run/user/7",
          SMITHERS_SESSION_SOCKET: "/s/smithers.sock",
          ZMUX_SOCKET: "/s/zmux.sock",
        },
        uid,
      }),
    ).toBe("/s/zmux.sock");
    expect(
      resolveSocketPath("/s/override.sock", {
        env: { ZMUX_SOCKET: "/s/zmux.sock" },
        uid,
      }),
    ).toBe("/s/override.sock");
  });

  test("skips empty env values and rejects empty override", () => {
    expect(
      resolveSocketPath(null, {
        env: {
          ZMUX_SOCKET: "",
          SMITHERS_SESSION_SOCKET: "",
          XDG_RUNTIME_DIR: "",
          HOME: "/home/u",
        },
      }),
    ).toBe("/home/u/.smithers/sessions.sock");

    try {
      resolveSocketPath("", { env: { HOME: "/home/u" } });
      expect.unreachable("expected EmptySocketPath");
    } catch (err) {
      expect(err).toBeInstanceOf(SocketPathError);
      expect((err as SocketPathError).code).toBe("EmptySocketPath");
    }
  });

  test("absolutize drops only leading ./ and preserves .. and inner ./", () => {
    expect(absolutizeSocketPath("/tmp/a.sock", "/work")).toBe("/tmp/a.sock");
    expect(absolutizeSocketPath("sub/a.sock", "/work")).toBe("/work/sub/a.sock");
    expect(absolutizeSocketPath(".//./a.sock", "/work")).toBe("/work/a.sock");
    expect(absolutizeSocketPath("../a.sock", "/work")).toBe("/work/../a.sock");
    expect(absolutizeSocketPath("a/./b.sock", "/work")).toBe("/work/a/./b.sock");
    expect(() => absolutizeSocketPath("./", "/work")).toThrow(SocketPathError);
    expect(() => absolutizeSocketPath("././.", "/work")).toThrow(SocketPathError);
    expect(() => absolutizeSocketPath("/a\0b", "/work")).toThrow(SocketPathError);
  });

  test("validate checks sun_path byte limits for darwin (103) and linux (107)", () => {
    expect(maxUnixPathLen("darwin")).toBe(103);
    expect(maxUnixPathLen("linux")).toBe(107);

    const darwinExact = "/" + "s".repeat(102);
    const darwinTooLong = "/" + "s".repeat(103);
    expect(() => validateSocketPath(darwinExact, 103)).not.toThrow();
    expect(() => validateSocketPath(darwinTooLong, 103)).toThrow(SocketPathError);
    expect(resolveSocketPathUnvalidated(darwinTooLong)).toBe(darwinTooLong);

    // Multi-byte UTF-8 counts bytes, not JS code units.
    const utf8Over = "/" + "é".repeat(52); // 1 + 104 = 105 bytes > 103
    expect(() => validateSocketPath(utf8Over, 103)).toThrow(SocketPathError);

    // Precedence: NUL before relative, trailing slash before too long.
    try {
      validateSocketPath("rel\0/");
    } catch (err) {
      expect((err as SocketPathError).code).toBe("SocketPathContainsNul");
    }
    try {
      validateSocketPath("/" + "a".repeat(120) + "/", 103);
    } catch (err) {
      expect((err as SocketPathError).code).toBe("NoSocketDirectory");
    }
  });

  test("isDefaultManagedSocketPath matches HOME/.smithers and /tmp/zmux-<uid> only", () => {
    expect(isDefaultManagedSocketPath("/tmp/zmux-501/sessions.sock", { env: {}, uid: 501 })).toBe(true);
    expect(isDefaultManagedSocketPath("/tmp/zmux-502/sessions.sock", { env: {}, uid: 501 })).toBe(false);
    expect(
      isDefaultManagedSocketPath("/home/u/.smithers//sessions.sock", {
        env: { HOME: "/home/u/" },
        uid: 501,
      }),
    ).toBe(true);
    expect(
      isDefaultManagedSocketPath("/run/user/7/smithers-sessions.sock", {
        env: { HOME: "/home/u" },
        uid: 501,
      }),
    ).toBe(false);
  });
});

describe("PaneStreamReconciler & AttachedPane deduplication", () => {
  test("deduplicates replay overlap, partial chunk overlap, reconnects, and generation bumps", () => {
    const rec = new PaneStreamReconciler();

    const attach1 = rec.applyAttach({
      clientId: "c-1",
      sessionId: "s-1",
      windowId: "w-1",
      paneId: "p-1",
      rows: 24,
      cols: 80,
      created: false,
      exited: false,
      exitCode: null,
      signal: null,
      generation: 1,
      replayBase64: encodeBase64(enc.encode("hello worl")),
      replayStartOffset: 0,
      replayEndOffset: 10,
    });
    expect(dec.decode(attach1.bytes)).toBe("hello worl");
    expect(rec.nextOffset).toBe(10);

    // Completely overlapped chunk -> empty
    const dup = rec.applyOutput({
      pane_id: "p-1",
      data_base64: encodeBase64(enc.encode("worl")),
      offset: 6,
      generation: 1,
    });
    expect(dup.byteLength).toBe(0);

    // Partially overlapped chunk [8..14) -> only "d!\n"
    const partial = rec.applyOutput({
      pane_id: "p-1",
      data_base64: encodeBase64(enc.encode("rld!\n")),
      offset: 8,
      generation: 1,
    });
    expect(dec.decode(partial)).toBe("d!\n");
    expect(rec.nextOffset).toBe(13);

    // Stale generation ignored
    const stale = rec.applyOutput({
      pane_id: "p-1",
      data_base64: encodeBase64(enc.encode("old")),
      offset: 100,
      generation: 0,
    });
    expect(stale.byteLength).toBe(0);

    // Reconnect on v0.4.0 daemon returns full scrollback [0..17): only unseen tail [13..17) emitted
    const reconV4 = rec.applyAttach({
      clientId: "c-2",
      sessionId: "s-1",
      windowId: "w-1",
      paneId: "p-1",
      rows: 24,
      cols: 80,
      created: false,
      exited: false,
      exitCode: null,
      signal: null,
      generation: 1,
      replayBase64: encodeBase64(enc.encode("hello world!\nNEXT")),
      replayStartOffset: 0,
      replayEndOffset: 17,
    });
    expect(reconV4.dropped).toBeUndefined();
    expect(dec.decode(reconV4.bytes)).toBe("NEXT");
    expect(rec.nextOffset).toBe(17);

    // Reconnect after scrollback wrap past offset 17 -> reports dropped bytes
    const reconWrap = rec.applyAttach({
      clientId: "c-3",
      sessionId: "s-1",
      windowId: "w-1",
      paneId: "p-1",
      rows: 24,
      cols: 80,
      created: false,
      exited: false,
      exitCode: null,
      signal: null,
      generation: 1,
      replayBase64: encodeBase64(enc.encode("AFTER")),
      replayStartOffset: 50,
      replayEndOffset: 55,
    });
    expect(reconWrap.dropped).toEqual({
      paneId: "p-1",
      droppedBytes: 33,
      resumeOffset: 50,
      generation: 1,
    });
    expect(dec.decode(reconWrap.bytes)).toBe("AFTER");
    expect(rec.nextOffset).toBe(55);

    // Respawn advances generation and resets offset
    expect(rec.applyRespawned({ pane_id: "p-1", generation: 2, pid: 999 })).toBe(true);
    expect(rec.generation).toBe(2);
    expect(rec.nextOffset).toBeNull();
    const fresh = rec.applyOutput({
      pane_id: "p-1",
      data_base64: encodeBase64(enc.encode("gen2")),
      offset: 0,
      generation: 2,
    });
    expect(dec.decode(fresh)).toBe("gen2");
  });

  test("AttachedPane reconnect falls back on v0.4.0 invalid_params without duplicating bytes", async () => {
    const listeners = new Set<(n: ZmuxNotification) => void>();
    const attachCalls: ClientAttachParams[] = [];

    const transport: ZmuxPaneTransport = {
      async attach(params) {
        attachCalls.push(params);
        if (params.resumeFromOffset !== undefined) {
          throw new ZmuxRpcError({
            code: -32602,
            kind: "invalid_params",
            rpcMessage: "InvalidParams",
            method: "client.attach",
          });
        }
        const isFirst = attachCalls.length === 1;
        return {
          clientId: isFirst ? "c-1" : "c-2",
          sessionId: "s-1",
          windowId: "w-1",
          paneId: "p-1",
          rows: 24,
          cols: 80,
          created: false,
          exited: false,
          exitCode: null,
          signal: null,
          generation: 1,
          replayBase64: encodeBase64(enc.encode(isFirst ? "abc" : "abcdef")),
          replayStartOffset: 0,
          replayEndOffset: isFirst ? 3 : 6,
        };
      },
      async detach() {
        return { ok: true };
      },
      async send() {
        return { ok: true };
      },
      async sendKey() {
        return { ok: true };
      },
      async resizeSession() {
        return { ok: true };
      },
      onNotification(fn) {
        listeners.add(fn);
        return () => listeners.delete(fn);
      },
    };

    const pane = await AttachedPane.attach(transport, { paneId: "p-1" });
    expect(dec.decode(pane.replayBytes)).toBe("abc");

    const received: string[] = [];
    pane.on("data", (bytes) => received.push(dec.decode(bytes)));

    await pane.reconnect();
    expect(attachCalls.length).toBe(3); // initial + resume attempt + fallback
    expect(attachCalls[1]!.resumeFromOffset).toBe(3);
    expect(attachCalls[2]!.resumeFromOffset).toBeUndefined();
    expect(received).toEqual(["def"]);
    expect(pane.bufferedText).toBe("abcdef");

    pane.dispose();
  });
});

describe("RFC 6455 WebSocket framing", () => {
  test("computeWebSocketAccept matches RFC 6455 section 1.3 vector", () => {
    expect(computeWebSocketAccept("dGhlIHNhbXBsZSBub25jZQ==")).toBe(
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
    );
  });

  test("decodes masked small, 16-bit, fragmented, and ping-interleaved frames in 1-byte chunks", () => {
    const mask = new Uint8Array([0x37, 0xfa, 0x21, 0x3d]);
    const decoder = new WsFrameDecoder({ maxPayloadBytes: 1024 * 1024, requireMasked: true });

    const part1 = encodeWsFrame(WS_OPCODE.TEXT, enc.encode("hello "), { fin: false, mask });
    const ping = encodeWsFrame(WS_OPCODE.PING, enc.encode("hb"), { fin: true, mask });
    const part2 = encodeWsFrame(WS_OPCODE.CONTINUATION, enc.encode("world"), { fin: true, mask });
    const mediumText = "x".repeat(400);
    const medium = encodeWsFrame(WS_OPCODE.TEXT, enc.encode(mediumText), { fin: true, mask });

    const combined = new Uint8Array(
      part1.byteLength + ping.byteLength + part2.byteLength + medium.byteLength,
    );
    let pos = 0;
    for (const f of [part1, ping, part2, medium]) {
      combined.set(f, pos);
      pos += f.byteLength;
    }

    const decoded = [];
    for (let i = 0; i < combined.byteLength; i += 1) {
      decoded.push(...decoder.push(combined.subarray(i, i + 1)));
    }

    expect(decoded.length).toBe(3);
    expect(decoded[0]!.opcode).toBe(WS_OPCODE.PING);
    expect(dec.decode(decoded[0]!.payload)).toBe("hb");
    expect(decoded[1]!.opcode).toBe(WS_OPCODE.TEXT);
    expect(dec.decode(decoded[1]!.payload)).toBe("hello world");
    expect(decoded[2]!.opcode).toBe(WS_OPCODE.TEXT);
    expect(dec.decode(decoded[2]!.payload)).toBe(mediumText);
  });

  test("rejects unmasked client frames, RSV bits, and oversized payloads", () => {
    const decoder = new WsFrameDecoder({ maxPayloadBytes: 32, requireMasked: true });
    const unmasked = encodeWsFrame(WS_OPCODE.TEXT, enc.encode("hi"));
    expect(() => decoder.push(unmasked)).toThrow(WsProtocolError);

    const mask = new Uint8Array([1, 2, 3, 4]);
    const oversized = encodeWsFrame(WS_OPCODE.TEXT, enc.encode("a".repeat(33)), { mask });
    try {
      new WsFrameDecoder({ maxPayloadBytes: 32, requireMasked: true }).push(oversized);
      expect.unreachable("expected MESSAGE_TOO_BIG");
    } catch (err) {
      expect(err).toBeInstanceOf(WsProtocolError);
      expect((err as WsProtocolError).closeCode).toBe(WS_CLOSE_CODE.MESSAGE_TOO_BIG);
    }
  });
});

describe("bridge auth & origin security helpers", () => {
  test("verifyBearerToken enforces exact constant-time equality", () => {
    expect(verifyBearerToken("secret-123", "secret-123")).toBe(true);
    expect(verifyBearerToken("secret-124", "secret-123")).toBe(false);
    expect(verifyBearerToken("short", "secret-123")).toBe(false);
    expect(verifyBearerToken("", "secret-123")).toBe(false);
    expect(verifyBearerToken(null, "secret-123")).toBe(false);
  });

  test("isOriginAllowed restricts to loopback by default and honors explicit allowlist", () => {
    expect(isOriginAllowed(undefined)).toBe(true);
    expect(isOriginAllowed("http://localhost:3000")).toBe(true);
    expect(isOriginAllowed("http://127.0.0.1:7681")).toBe(true);
    expect(isOriginAllowed("https://[::1]:8443")).toBe(true);
    expect(isOriginAllowed("https://evil.example")).toBe(false);
    expect(isOriginAllowed("null")).toBe(false);

    expect(isOriginAllowed("https://app.example.com", ["https://app.example.com"])).toBe(true);
    expect(isOriginAllowed("http://localhost:3000", ["https://app.example.com"])).toBe(false);
  });
});

describe("@smithers/zmux/xterm adapter", () => {
  test("attaches, deduplicates across reconnect, forwards input/resize, and respects readOnly", async () => {
    const written: string[] = [];
    let onDataCb: ((data: string) => void) | null = null;
    let onResizeCb: ((size: { cols: number; rows: number }) => void) | null = null;

    const fakeTerm: XtermLike = {
      cols: 100,
      rows: 30,
      write(data) {
        written.push(typeof data === "string" ? data : dec.decode(data));
      },
      onData(cb) {
        onDataCb = cb;
        return { dispose() {} };
      },
      onResize(cb) {
        onResizeCb = cb;
        return { dispose() {} };
      },
    };

    const sockets: Array<{
      url: string;
      protocols?: string[];
      sent: Record<string, unknown>[];
      ws: WebSocketLike;
    }> = [];

    const statuses: XtermConnectionStatus[] = [];

    const handle = attachXterm(fakeTerm, {
      url: "ws://127.0.0.1:7681/ws",
      token: "tok-abc",
      target: "work",
      reconnectInitialDelayMs: 10,
      reconnectMaxDelayMs: 20,
      onStatus: (s) => statuses.push(s),
      webSocketFactory(url, protocols) {
        const sent: Record<string, unknown>[] = [];
        const ws: WebSocketLike = {
          readyState: 1,
          onopen: null,
          onmessage: null,
          onerror: null,
          onclose: null,
          send(raw) {
            const req = JSON.parse(raw) as { id: number; method: string; params: Record<string, unknown> };
            sent.push(req);
            if (req.method === "client.attach") {
              const isReconnect = sockets.length > 1;
              const replay = isReconnect ? "hello world!" : "hello ";
              const res: AttachResult = {
                clientId: isReconnect ? "c-2" : "c-1",
                sessionId: "s-1",
                windowId: "w-1",
                paneId: "p-1",
                rows: 30,
                cols: 100,
                created: false,
                exited: false,
                exitCode: null,
                signal: null,
                generation: 1,
                replayBase64: encodeBase64(enc.encode(replay)),
                replayStartOffset: 0,
                replayEndOffset: replay.length,
              };
              ws.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: req.id, result: res }) });
            } else {
              ws.onmessage?.({ data: JSON.stringify({ jsonrpc: "2.0", id: req.id, result: { ok: true } }) });
            }
          },
          close() {
            ws.onclose?.({ code: 1000, reason: "closed" });
          },
        };
        sockets.push({ url, protocols, sent, ws });
        queueMicrotask(() => ws.onopen?.({}));
        return ws;
      },
    });

    await new Promise((r) => setTimeout(r, 25));
    expect(sockets[0]!.protocols).toEqual(["zmux-v1", "zmux-token.tok-abc"]);
    expect(handle.status).toBe("connected");
    expect(written.join("")).toBe("hello ");

    // Live output chunk partially overlapping replay ("o wor")
    sockets[0]!.ws.onmessage?.({
      data: JSON.stringify({
        jsonrpc: "2.0",
        method: "pane_output",
        params: {
          pane_id: "p-1",
          data_base64: encodeBase64(enc.encode("o wor")),
          offset: 4,
          generation: 1,
        },
      }),
    });
    expect(written.join("")).toBe("hello wor");

    // Input & resize forwarding
    onDataCb!("ls\r");
    onResizeCb!({ rows: 40, cols: 120 });
    await new Promise((r) => setTimeout(r, 10));
    expect(sockets[0]!.sent.some((r) => r.method === "session.send")).toBe(true);
    expect(sockets[0]!.sent.some((r) => r.method === "session.resize")).toBe(true);

    // Simulate network drop -> auto-reconnect with resumeFromOffset=9 -> receives only "ld!"
    sockets[0]!.ws.onclose?.({ code: 1006, reason: "drop" });
    await new Promise((r) => setTimeout(r, 40));
    expect(sockets.length).toBeGreaterThanOrEqual(2);
    const secondAttach = sockets[1]!.sent.find((r) => r.method === "client.attach") as {
      params: Record<string, unknown>;
    };
    expect(secondAttach.params.resumeFromOffset).toBe(9);
    expect(written.join("")).toBe("hello world!");
    expect(statuses).toContain("reconnecting");

    handle.dispose();
    expect(handle.status).toBe("disposed");
  });
});
