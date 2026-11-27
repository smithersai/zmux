import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import type { Duplex } from "node:stream";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { ZmuxClient } from "./client.ts";
import { ZmuxRpcError } from "./errors.ts";
import { DEFAULT_MAX_FRAME_BYTES, NdjsonFrameParser } from "./framing.ts";
import { resolveSocketPath } from "./socket-path.ts";
import {
  WS_CLOSE_CODE,
  WS_OPCODE,
  WsFrameDecoder,
  WsProtocolError,
  computeWebSocketAccept,
  encodeWsCloseFrame,
  encodeWsFrame,
} from "./ws-framing.ts";

export interface ZmuxBridgeOptions {
  /** Path to the zmuxd UNIX socket. Defaults to standard zmux precedence. */
  socketPath?: string;
  /** Automatically spawn zmuxd if not yet listening. */
  spawnDaemon?: boolean;
  /** Explicit zmuxd binary path when spawnDaemon is true. */
  daemonBinary?: string;
  /** Bind interface (default "127.0.0.1"). */
  host?: string;
  /** Listen port (default 7681; pass 0 for an ephemeral port). */
  port?: number;
  /** Mandatory bearer token. A random 32-byte hex token is generated when omitted. */
  token?: string;
  /** Explicit origin allowlist. Defaults to loopback localhost/127.0.0.1/[::1] origins only. */
  allowOrigins?: string[];
  /** Maximum HTTP/WS incoming JSON-RPC payload size in bytes (default 1 MiB). */
  maxRequestBytes?: number;
  /** Maximum outgoing buffer per WS/SSE client before dropping output or closing (default 2 MiB). */
  maxClientBackpressureBytes?: number;
  /** Maximum concurrent WS + SSE streaming clients (default 64). */
  maxClients?: number;
  /** Serve the bundled browser demo UI at GET / (default false). */
  serveDemo?: boolean;
  /** SSE heartbeat interval in milliseconds (default 15000). */
  sseHeartbeatMs?: number;
}

const DEFAULT_MAX_REQUEST_BYTES = 1024 * 1024;
const DEFAULT_MAX_BACKPRESSURE_BYTES = 2 * 1024 * 1024;
const DEFAULT_MAX_CLIENTS = 64;
const WS_TOKEN_SUBPROTOCOL_PREFIX = "zmux-token.";
const WS_PROTOCOL_NAME = "zmux-v1";

const textEncoder = new TextEncoder();
const textDecoder = new TextDecoder("utf-8", { fatal: false });

/** Constant-time bearer token check using crypto.timingSafeEqual. */
export function verifyBearerToken(candidate: string | null | undefined, expected: string): boolean {
  if (!candidate || expected.length === 0) return false;
  const a = Buffer.from(candidate, "utf8");
  const b = Buffer.from(expected, "utf8");
  if (a.byteLength !== b.byteLength) {
    // Run a fixed-length comparison to avoid leaking length timing trivially.
    crypto.timingSafeEqual(b, b);
    return false;
  }
  return crypto.timingSafeEqual(a, b);
}

/** Check if an HTTP Origin header matches the configured allowlist or default localhost policy. */
export function isOriginAllowed(origin: string | undefined, allowOrigins?: string[]): boolean {
  if (origin === undefined) return true;
  if (allowOrigins && allowOrigins.length > 0) {
    for (const allowed of allowOrigins) {
      if (allowed === origin) return true;
    }
    return false;
  }
  try {
    const parsed = new URL(origin);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return false;
    return (
      parsed.hostname === "localhost" ||
      parsed.hostname === "127.0.0.1" ||
      parsed.hostname === "[::1]" ||
      parsed.hostname === "::1"
    );
  } catch {
    return false;
  }
}

function extractBearerHeader(req: http.IncomingMessage): string | null {
  const auth = req.headers.authorization;
  if (typeof auth !== "string") return null;
  const match = /^Bearer\s+(.+)$/i.exec(auth.trim());
  return match ? match[1]!.trim() : null;
}

function parseWsSubprotocols(header: string | string[] | undefined): string[] {
  const raw = Array.isArray(header) ? header.join(",") : (header ?? "");
  return raw
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

function extractStreamToken(
  req: http.IncomingMessage,
  url: URL,
  allowSubprotocol: boolean,
): { token: string | null; matchedProtocol: string | null } {
  const headerToken = extractBearerHeader(req);
  const protocols = allowSubprotocol ? parseWsSubprotocols(req.headers["sec-websocket-protocol"]) : [];
  const matchedProtocol = protocols.includes(WS_PROTOCOL_NAME) ? WS_PROTOCOL_NAME : null;

  if (headerToken) {
    return { token: headerToken, matchedProtocol };
  }
  if (allowSubprotocol) {
    for (const proto of protocols) {
      if (proto.startsWith(WS_TOKEN_SUBPROTOCOL_PREFIX)) {
        return {
          token: proto.slice(WS_TOKEN_SUBPROTOCOL_PREFIX.length),
          matchedProtocol,
        };
      }
    }
  }
  const queryToken = url.searchParams.get("token");
  return { token: queryToken, matchedProtocol };
}

function writeJson(
  res: http.ServerResponse,
  status: number,
  body: unknown,
  origin: string | undefined,
): void {
  const payload = JSON.stringify(body);
  const headers: Record<string, string | number> = {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload, "utf8"),
    "Cache-Control": "no-store",
  };
  if (origin) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers.Vary = "Origin";
  }
  res.writeHead(status, headers);
  res.end(payload);
}

function writeUpgradeError(socket: Duplex, statusCode: number, statusText: string, message: string): void {
  const body = JSON.stringify({ error: message });
  const response =
    `HTTP/1.1 ${statusCode} ${statusText}\r\n` +
    `Content-Type: application/json; charset=utf-8\r\n` +
    `Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n` +
    `Connection: close\r\n\r\n${body}`;
  socket.end(response);
}

function readBoundedBody(req: http.IncomingMessage, maxBytes: number): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    let failed = false;

    req.on("data", (chunk: Buffer) => {
      if (failed) return;
      total += chunk.byteLength;
      if (total > maxBytes) {
        failed = true;
        reject(Object.assign(new Error("Payload too large"), { statusCode: 413 }));
        req.resume();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => {
      if (failed) return;
      resolve(Buffer.concat(chunks, total).toString("utf8"));
    });
    req.on("error", (err) => {
      if (failed) return;
      failed = true;
      reject(err);
    });
  });
}

function isPaneOutputFrame(line: string): boolean {
  return line.includes('"method":"pane_output"') || line.includes('"method": "pane_output"');
}

export class ZmuxBridge {
  readonly socketPath: string;
  readonly host: string;
  readonly token: string;
  readonly tokenGenerated: boolean;
  private readonly requestedPort: number;
  private readonly allowOrigins?: string[];
  private readonly maxRequestBytes: number;
  private readonly maxClientBackpressureBytes: number;
  private readonly maxClients: number;
  private readonly spawnDaemon: boolean;
  private readonly daemonBinary?: string;
  private readonly serveDemo: boolean;
  private readonly sseHeartbeatMs: number;
  private readonly server: http.Server;
  private readonly activeWs = new Set<{ close: () => void }>();
  private readonly activeSse = new Set<{ close: () => void }>();
  private boundPort = 0;
  private started = false;

  constructor(options: ZmuxBridgeOptions = {}) {
    this.socketPath = resolveSocketPath(options.socketPath);
    this.host = options.host ?? "127.0.0.1";
    this.requestedPort = options.port ?? 7681;
    if (options.token && options.token.length > 0) {
      this.token = options.token;
      this.tokenGenerated = false;
    } else {
      this.token = crypto.randomBytes(32).toString("hex");
      this.tokenGenerated = true;
    }
    this.allowOrigins = options.allowOrigins;
    this.maxRequestBytes = options.maxRequestBytes ?? DEFAULT_MAX_REQUEST_BYTES;
    this.maxClientBackpressureBytes =
      options.maxClientBackpressureBytes ?? DEFAULT_MAX_BACKPRESSURE_BYTES;
    this.maxClients = options.maxClients ?? DEFAULT_MAX_CLIENTS;
    this.spawnDaemon = options.spawnDaemon ?? false;
    this.daemonBinary = options.daemonBinary;
    this.serveDemo = options.serveDemo ?? false;
    this.sseHeartbeatMs = options.sseHeartbeatMs ?? 15_000;

    this.server = http.createServer((req, res) => {
      void this.handleHttpRequest(req, res);
    });
    this.server.on("upgrade", (req, socket, head) => {
      void this.handleUpgrade(req, socket, head);
    });
  }

  get port(): number {
    return this.boundPort;
  }

  get httpUrl(): string {
    return `http://${this.host}:${this.boundPort}`;
  }

  get wsUrl(): string {
    return `ws://${this.host}:${this.boundPort}/ws`;
  }

  async start(): Promise<{ host: string; port: number; httpUrl: string; wsUrl: string }> {
    if (this.started) {
      return { host: this.host, port: this.boundPort, httpUrl: this.httpUrl, wsUrl: this.wsUrl };
    }
    if (this.spawnDaemon) {
      const probe = await ZmuxClient.connect({
        socketPath: this.socketPath,
        spawnDaemon: true,
        daemonBinary: this.daemonBinary,
      });
      probe.close();
    }
    await new Promise<void>((resolve, reject) => {
      const onError = (err: Error) => {
        this.server.off("listening", onListening);
        reject(err);
      };
      const onListening = () => {
        this.server.off("error", onError);
        const addr = this.server.address();
        if (addr && typeof addr === "object") {
          this.boundPort = addr.port;
        }
        this.started = true;
        resolve();
      };
      this.server.once("error", onError);
      this.server.once("listening", onListening);
      this.server.listen(this.requestedPort, this.host);
    });
    return { host: this.host, port: this.boundPort, httpUrl: this.httpUrl, wsUrl: this.wsUrl };
  }

  async close(): Promise<void> {
    for (const ws of [...this.activeWs]) ws.close();
    for (const sse of [...this.activeSse]) sse.close();
    this.activeWs.clear();
    this.activeSse.clear();
    if (!this.started) return;
    this.started = false;
    await new Promise<void>((resolve) => {
      this.server.close(() => resolve());
    });
  }

  private async handleHttpRequest(
    req: http.IncomingMessage,
    res: http.ServerResponse,
  ): Promise<void> {
    const origin = typeof req.headers.origin === "string" ? req.headers.origin : undefined;
    if (!isOriginAllowed(origin, this.allowOrigins)) {
      writeJson(res, 403, { error: "Origin not allowed" }, undefined);
      return;
    }

    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    const method = req.method ?? "GET";

    if (method === "OPTIONS") {
      const headers: Record<string, string> = {
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Authorization, Content-Type",
        "Access-Control-Max-Age": "600",
      };
      if (origin) {
        headers["Access-Control-Allow-Origin"] = origin;
        headers.Vary = "Origin";
      }
      res.writeHead(204, headers);
      res.end();
      return;
    }

    if (method === "GET" && url.pathname === "/healthz") {
      const daemonReachable = await this.probeDaemon();
      writeJson(
        res,
        200,
        {
          ok: true,
          daemonReachable,
          activeWsClients: this.activeWs.size,
          activeSseClients: this.activeSse.size,
        },
        origin,
      );
      return;
    }

    if (method === "GET" && this.serveDemo && (url.pathname === "/" || url.pathname === "/demo")) {
      const here = path.dirname(fileURLToPath(import.meta.url));
      const demoPath = path.resolve(here, "..", "demo", "index.html");
      try {
        const html = fs.readFileSync(demoPath, "utf8");
        res.writeHead(200, {
          "Content-Type": "text/html; charset=utf-8",
          "Cache-Control": "no-store",
        });
        res.end(html);
      } catch {
        writeJson(res, 404, { error: "Demo file not found" }, origin);
      }
      return;
    }

    if (method === "POST" && url.pathname === "/rpc") {
      const bearer = extractBearerHeader(req);
      if (!verifyBearerToken(bearer, this.token)) {
        writeJson(res, 401, { error: "Unauthorized" }, origin);
        return;
      }
      await this.handleRpcPost(req, res, origin);
      return;
    }

    if (method === "GET" && url.pathname === "/events") {
      const { token } = extractStreamToken(req, url, false);
      if (!verifyBearerToken(token, this.token)) {
        writeJson(res, 401, { error: "Unauthorized" }, origin);
        return;
      }
      await this.handleSseEvents(req, res, url, origin);
      return;
    }

    writeJson(res, 404, { error: "Not found" }, origin);
  }

  private async probeDaemon(): Promise<boolean> {
    try {
      const client = await ZmuxClient.connect({
        socketPath: this.socketPath,
        connectTimeoutMs: 500,
        defaultRequestTimeoutMs: 500,
      });
      try {
        await client.ping({ timeoutMs: 500 });
        return true;
      } finally {
        client.close();
      }
    } catch {
      return false;
    }
  }

  private async handleRpcPost(
    req: http.IncomingMessage,
    res: http.ServerResponse,
    origin: string | undefined,
  ): Promise<void> {
    let rawBody: string;
    try {
      rawBody = await readBoundedBody(req, this.maxRequestBytes);
    } catch (err) {
      const status = (err as { statusCode?: number }).statusCode === 413 ? 413 : 400;
      writeJson(res, status, { error: (err as Error).message }, origin);
      return;
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(rawBody);
    } catch {
      writeJson(
        res,
        400,
        {
          jsonrpc: "2.0",
          id: null,
          error: { code: -32700, message: "ParseError", data: { kind: "parse" } },
        },
        origin,
      );
      return;
    }

    if (
      parsed === null ||
      typeof parsed !== "object" ||
      Array.isArray(parsed) ||
      typeof (parsed as Record<string, unknown>).method !== "string"
    ) {
      writeJson(
        res,
        400,
        {
          jsonrpc: "2.0",
          id: null,
          error: { code: -32600, message: "InvalidRequest", data: { kind: "invalid_request" } },
        },
        origin,
      );
      return;
    }

    const body = parsed as { id?: string | number | null; method: string; params?: Record<string, unknown> };
    const rpcId = body.id !== undefined ? body.id : 1;

    let client: ZmuxClient;
    try {
      client = await ZmuxClient.connect({
        socketPath: this.socketPath,
        spawnDaemon: this.spawnDaemon,
        daemonBinary: this.daemonBinary,
      });
    } catch (err) {
      writeJson(res, 502, { error: `Unable to reach zmuxd: ${(err as Error).message}` }, origin);
      return;
    }

    try {
      const result = await client.call(body.method, body.params);
      writeJson(res, 200, { jsonrpc: "2.0", id: rpcId, result }, origin);
    } catch (err) {
      if (err instanceof ZmuxRpcError) {
        writeJson(
          res,
          200,
          {
            jsonrpc: "2.0",
            id: rpcId,
            error: {
              code: err.code,
              message: err.rpcMessage,
              data: { kind: err.kind },
            },
          },
          origin,
        );
      } else {
        writeJson(
          res,
          502,
          {
            jsonrpc: "2.0",
            id: rpcId,
            error: {
              code: -32603,
              message: (err as Error).message,
              data: { kind: "internal" },
            },
          },
          origin,
        );
      }
    } finally {
      client.close();
    }
  }

  private async handleSseEvents(
    req: http.IncomingMessage,
    res: http.ServerResponse,
    url: URL,
    origin: string | undefined,
  ): Promise<void> {
    if (this.activeWs.size + this.activeSse.size >= this.maxClients) {
      writeJson(res, 503, { error: "Too many active bridge clients" }, origin);
      return;
    }

    let client: ZmuxClient;
    try {
      client = await ZmuxClient.connect({
        socketPath: this.socketPath,
        spawnDaemon: this.spawnDaemon,
        daemonBinary: this.daemonBinary,
      });
    } catch (err) {
      writeJson(res, 502, { error: `Unable to reach zmuxd: ${(err as Error).message}` }, origin);
      return;
    }

    const panesParam = url.searchParams.get("panes");
    if (panesParam !== null && panesParam.length > 0) {
      const panes = panesParam
        .split(",")
        .map((p) => p.trim())
        .filter((p) => p.length > 0);
      try {
        await client.subscribeEvents(panes);
      } catch (err) {
        client.close();
        writeJson(res, 400, { error: (err as Error).message }, origin);
        return;
      }
    }

    const headers: Record<string, string> = {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
      "X-Accel-Buffering": "no",
    };
    if (origin) {
      headers["Access-Control-Allow-Origin"] = origin;
      headers.Vary = "Origin";
    }
    res.writeHead(200, headers);
    res.write(": connected\n\n");

    let closed = false;
    const heartbeat = setInterval(() => {
      if (!closed && !res.writableEnded) {
        res.write(": keepalive\n\n");
      }
    }, this.sseHeartbeatMs);

    const handle = {
      close: () => {
        if (closed) return;
        closed = true;
        clearInterval(heartbeat);
        this.activeSse.delete(handle);
        client.close();
        if (!res.writableEnded) res.end();
      },
    };
    this.activeSse.add(handle);

    client.onNotification((notification) => {
      if (closed || res.writableEnded) return;
      if (
        res.writableLength > this.maxClientBackpressureBytes &&
        notification.method === "pane_output"
      ) {
        return;
      }
      const eventLine = `event: ${notification.method}\ndata: ${JSON.stringify(notification.params)}\n\n`;
      res.write(eventLine);
    });

    client.onClose(() => handle.close());
    req.on("close", () => handle.close());
    res.on("error", () => handle.close());
  }

  private async handleUpgrade(
    req: http.IncomingMessage,
    socket: Duplex,
    head: Buffer,
  ): Promise<void> {
    const origin = typeof req.headers.origin === "string" ? req.headers.origin : undefined;
    if (!isOriginAllowed(origin, this.allowOrigins)) {
      writeUpgradeError(socket, 403, "Forbidden", "Origin not allowed");
      return;
    }

    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);
    if (url.pathname !== "/ws") {
      writeUpgradeError(socket, 404, "Not Found", "WebSocket endpoint is /ws");
      return;
    }

    const upgrade = String(req.headers.upgrade ?? "").toLowerCase();
    const wsKey = req.headers["sec-websocket-key"];
    const wsVersion = req.headers["sec-websocket-version"];
    if (upgrade !== "websocket" || typeof wsKey !== "string" || wsKey.length === 0 || wsVersion !== "13") {
      writeUpgradeError(socket, 400, "Bad Request", "Invalid WebSocket upgrade request");
      return;
    }

    const { token, matchedProtocol } = extractStreamToken(req, url, true);
    if (!verifyBearerToken(token, this.token)) {
      writeUpgradeError(socket, 401, "Unauthorized", "Invalid or missing bearer token");
      return;
    }

    if (this.activeWs.size + this.activeSse.size >= this.maxClients) {
      writeUpgradeError(socket, 503, "Service Unavailable", "Too many active bridge clients");
      return;
    }

    let unixSocket: net.Socket;
    try {
      unixSocket = await new Promise<net.Socket>((resolve, reject) => {
        const s = net.createConnection({ path: this.socketPath });
        s.once("connect", () => {
          s.off("error", reject);
          resolve(s);
        });
        s.once("error", reject);
      });
    } catch (err) {
      writeUpgradeError(socket, 502, "Bad Gateway", `Failed connecting to zmuxd: ${(err as Error).message}`);
      return;
    }

    const accept = computeWebSocketAccept(wsKey);
    const responseHeaders = [
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${accept}`,
    ];
    if (matchedProtocol) {
      responseHeaders.push(`Sec-WebSocket-Protocol: ${matchedProtocol}`);
    }
    socket.write(`${responseHeaders.join("\r\n")}\r\n\r\n`);

    const wsDecoder = new WsFrameDecoder({
      maxPayloadBytes: this.maxRequestBytes,
      requireMasked: true,
    });
    const ndjsonParser = new NdjsonFrameParser(DEFAULT_MAX_FRAME_BYTES);
    let closed = false;

    const cleanup = (closeCode?: number, reason?: string) => {
      if (closed) return;
      closed = true;
      this.activeWs.delete(handle);
      unixSocket.destroy();
      if (closeCode !== undefined && !socket.destroyed && socket.writable) {
        try {
          socket.write(encodeWsCloseFrame(closeCode, reason ?? ""));
        } catch {
          // Socket already closed.
        }
      }
      socket.destroy();
    };

    const handle = { close: () => cleanup(WS_CLOSE_CODE.GOING_AWAY, "bridge shutdown") };
    this.activeWs.add(handle);

    const processWsBytes = (data: Uint8Array) => {
      if (closed) return;
      let messages;
      try {
        messages = wsDecoder.push(data);
      } catch (err) {
        const code = err instanceof WsProtocolError ? err.closeCode : WS_CLOSE_CODE.PROTOCOL_ERROR;
        cleanup(code, (err as Error).message);
        return;
      }

      for (const msg of messages) {
        if (msg.opcode === WS_OPCODE.CLOSE) {
          cleanup(WS_CLOSE_CODE.NORMAL);
          return;
        }
        if (msg.opcode === WS_OPCODE.PING) {
          if (!socket.destroyed && socket.writable) {
            socket.write(encodeWsFrame(WS_OPCODE.PONG, msg.payload));
          }
          continue;
        }
        if (msg.opcode === WS_OPCODE.PONG) {
          continue;
        }
        if (msg.opcode === WS_OPCODE.TEXT || msg.opcode === WS_OPCODE.BINARY) {
          const text = textDecoder.decode(msg.payload).replace(/[\r\n]+/g, " ").trim();
          if (text.length === 0) continue;
          if (!unixSocket.destroyed && unixSocket.writable) {
            unixSocket.write(`${text}\n`);
          }
        }
      }
    };

    socket.on("data", (chunk: Buffer) => processWsBytes(chunk));
    socket.on("close", () => cleanup());
    socket.on("error", () => cleanup());

    unixSocket.on("data", (chunk: Buffer) => {
      if (closed) return;
      let lines: string[];
      try {
        lines = ndjsonParser.push(chunk);
      } catch {
        cleanup(WS_CLOSE_CODE.MESSAGE_TOO_BIG, "daemon frame too large");
        return;
      }
      for (const line of lines) {
        if (closed || socket.destroyed || !socket.writable) return;
        // Per-client backpressure protection: shed pane_output frames first if socket lags.
        if (socket.writableLength > this.maxClientBackpressureBytes) {
          if (isPaneOutputFrame(line)) continue;
          if (socket.writableLength > this.maxClientBackpressureBytes * 2) {
            cleanup(WS_CLOSE_CODE.POLICY_VIOLATION, "client backpressured");
            return;
          }
        }
        const payload = textEncoder.encode(line);
        socket.write(encodeWsFrame(WS_OPCODE.TEXT, payload));
      }
    });
    unixSocket.on("close", () => cleanup(WS_CLOSE_CODE.GOING_AWAY, "daemon closed"));
    unixSocket.on("error", () => cleanup(WS_CLOSE_CODE.INTERNAL_ERROR, "daemon error"));

    if (head.byteLength > 0) {
      processWsBytes(head);
    }
  }
}
