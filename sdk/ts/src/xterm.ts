import {
  PaneStreamReconciler,
  type DroppedOutputEvent,
  type PaneExitedEvent,
} from "./attached-pane.ts";
import { ZmuxError, ZmuxRpcError, inferErrorKind } from "./errors.ts";
import { encodeBase64 } from "./framing.ts";
import type {
  AttachResult,
  ClientAttachParams,
  ClientDetachedParams,
  ClientSwitchedParams,
  JsonRpcResponse,
  PaneOutputDroppedParams,
  PaneOutputParams,
  PaneRespawnedParams,
  ReplayMode,
  ResizePolicy,
  SessionCreateParams,
  SessionExitedParams,
} from "./types.ts";

export interface Disposable {
  dispose(): void;
}

/** Structural interface compatible with xterm.js (`Terminal`) and ghostty-web. */
export interface XtermLike {
  readonly cols: number;
  readonly rows: number;
  write(data: string | Uint8Array, callback?: () => void): void;
  onData(listener: (data: string) => void): Disposable | (() => void);
  onBinary?(listener: (data: string) => void): Disposable | (() => void);
  onResize?(listener: (size: { cols: number; rows: number }) => void): Disposable | (() => void);
  reset?(): void;
}

/** Minimal WebSocket contract compatible with browser `WebSocket`, Node 22+, and Bun. */
export interface WebSocketLike {
  readonly readyState: number;
  onopen: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onerror: ((event: unknown) => void) | null;
  onclose: ((event: { code?: number; reason?: string }) => void) | null;
  send(data: string): void;
  close(code?: number, reason?: string): void;
}

export type XtermConnectionStatus =
  | "connecting"
  | "connected"
  | "reconnecting"
  | "disconnected"
  | "disposed";

export interface AttachXtermOptions {
  /** WebSocket URL of zmux-ws (for example "ws://127.0.0.1:7681/ws"). */
  url: string;
  /** Bearer token configured on zmux-ws. */
  token: string;
  /** Target pane ID, session ID, or session name. */
  target: string;
  /** Optional session.create payload to create the session if missing. */
  createIfMissing?: SessionCreateParams;
  /** Auth transport for WebSocket upgrade: subprotocol (default) avoids query strings. */
  authMode?: "subprotocol" | "query";
  /** Attach read-only (disables input and resize forwarding). */
  readOnly?: boolean;
  /** Resize coordination policy (additive v0.5.0). */
  resizePolicy?: ResizePolicy;
  /** Replay mode (additive v0.5.0). */
  replayMode?: ReplayMode;
  /** Automatically reconnect on socket drops (default true). */
  reconnect?: boolean;
  /** Initial reconnect delay in milliseconds (default 250). */
  reconnectInitialDelayMs?: number;
  /** Maximum reconnect delay in milliseconds (default 10000). */
  reconnectMaxDelayMs?: number;
  /** Exponential backoff factor (default 2). */
  reconnectFactor?: number;
  /** Max reconnect attempts before giving up (default Infinity). */
  maxReconnectAttempts?: number;
  /** Injectable WebSocket constructor for tests or custom environments. */
  webSocketFactory?: (url: string, protocols?: string[]) => WebSocketLike;
  onStatus?: (status: XtermConnectionStatus, detail?: string) => void;
  onAttach?: (result: AttachResult) => void;
  onDropped?: (event: DroppedOutputEvent) => void;
  onExited?: (event: PaneExitedEvent) => void;
  onError?: (error: Error) => void;
}

export interface XtermAttachment extends Disposable {
  readonly status: XtermConnectionStatus;
  readonly clientId: string;
  readonly paneId: string;
  readonly sessionId: string;
  readonly generation: number;
  readonly nextOffset: number | null;
  send(text: string, enter?: boolean): Promise<void>;
  sendKey(key: string): Promise<void>;
  resize(rows: number, cols: number): Promise<void>;
  rpc<T = unknown>(method: string, params?: Record<string, unknown>): Promise<T>;
  reconnectNow(): void;
}

const WS_OPEN = 1;
const textEncoder = new TextEncoder();

function disposeLike(handle: Disposable | (() => void) | undefined): void {
  if (!handle) return;
  if (typeof handle === "function") handle();
  else handle.dispose();
}

function defaultWebSocketFactory(url: string, protocols?: string[]): WebSocketLike {
  const Ctor = (globalThis as unknown as { WebSocket?: new (u: string, p?: string[]) => WebSocketLike }).WebSocket;
  if (!Ctor) {
    throw new ZmuxError("No global WebSocket constructor available. Pass options.webSocketFactory.");
  }
  return protocols && protocols.length > 0 ? new Ctor(url, protocols) : new Ctor(url);
}

interface PendingWsRpc {
  method: string;
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
}

/**
 * Attach an `xterm.js` or `ghostty-web` terminal instance to a live zmux pane
 * over `zmux-ws`, with automatic exponential-backoff reconnect, offset-based
 * deduplication, and resize/input forwarding.
 */
export function attachXterm(
  terminal: XtermLike,
  options: AttachXtermOptions,
): XtermAttachment {
  const reconciler = new PaneStreamReconciler();
  const wsFactory = options.webSocketFactory ?? defaultWebSocketFactory;
  const authMode = options.authMode ?? "subprotocol";
  const allowReconnect = options.reconnect ?? true;
  const initialDelay = options.reconnectInitialDelayMs ?? 250;
  const maxDelay = options.reconnectMaxDelayMs ?? 10_000;
  const factor = options.reconnectFactor ?? 2;
  const maxAttempts = options.maxReconnectAttempts ?? Number.POSITIVE_INFINITY;

  let status: XtermConnectionStatus = "connecting";
  let socket: WebSocketLike | null = null;
  let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  let attempts = 0;
  let disposed = false;
  let nextId = 1;
  let clientId = "";
  let sessionId = "";
  let attached = false;
  const pending = new Map<number, PendingWsRpc>();

  const setStatus = (next: XtermConnectionStatus, detail?: string) => {
    if (status === next && detail === undefined) return;
    status = next;
    options.onStatus?.(next, detail);
  };

  const rejectAllPending = (err: Error) => {
    for (const [, entry] of pending) {
      entry.reject(err);
    }
    pending.clear();
  };

  const rpc = <T = unknown>(method: string, params?: Record<string, unknown>): Promise<T> => {
    if (disposed || !socket || socket.readyState !== WS_OPEN) {
      return Promise.reject(new ZmuxError(`WebSocket is not open for "${method}"`));
    }
    const id = nextId++;
    const frame = JSON.stringify(
      params !== undefined
        ? { jsonrpc: "2.0", id, method, params }
        : { jsonrpc: "2.0", id, method },
    );
    return new Promise<T>((resolve, reject) => {
      pending.set(id, {
        method,
        resolve: resolve as (value: unknown) => void,
        reject,
      });
      try {
        socket!.send(frame);
      } catch (err) {
        pending.delete(id);
        reject(err instanceof Error ? err : new ZmuxError(String(err)));
      }
    });
  };

  const buildAttachParams = (includeResume: boolean): ClientAttachParams => {
    const target = reconciler.paneId || options.target;
    const base: ClientAttachParams = {
      paneId: target,
      rows: Math.max(1, terminal.rows || 24),
      cols: Math.max(1, terminal.cols || 80),
      ...(options.createIfMissing && reconciler.paneId.length === 0
        ? { createIfMissing: options.createIfMissing }
        : {}),
    };
    if (!includeResume) return base;
    return {
      ...base,
      ...(reconciler.nextOffset !== null
        ? {
            resumeFromOffset: reconciler.nextOffset,
            resumeGeneration: reconciler.generation,
          }
        : {}),
      ...(options.readOnly !== undefined ? { readOnly: options.readOnly } : {}),
      ...(options.resizePolicy !== undefined ? { resizePolicy: options.resizePolicy } : {}),
      ...(options.replayMode !== undefined ? { replayMode: options.replayMode } : {}),
    };
  };

  const handleNotification = (method: string, rawParams: unknown) => {
    const params = (rawParams ?? {}) as Record<string, unknown>;
    switch (method) {
      case "pane_output": {
        const bytes = reconciler.applyOutput(params as unknown as PaneOutputParams);
        if (bytes.byteLength > 0) {
          terminal.write(bytes);
        }
        break;
      }
      case "pane_output_dropped": {
        const dropped = reconciler.applyDropped(params as unknown as PaneOutputDroppedParams);
        if (dropped) options.onDropped?.(dropped);
        break;
      }
      case "pane_respawned": {
        reconciler.applyRespawned(params as unknown as PaneRespawnedParams);
        break;
      }
      case "client_switched": {
        const p = params as unknown as ClientSwitchedParams;
        if (p.client_id !== clientId) return;
        const switched = reconciler.applySwitched(p);
        terminal.reset?.();
        if (switched.bytes.byteLength > 0) {
          terminal.write(switched.bytes);
        }
        break;
      }
      case "session_exited": {
        const p = params as unknown as SessionExitedParams;
        if (p.session_id !== reconciler.paneId) return;
        if (p.generation < reconciler.generation) return;
        options.onExited?.({
          paneId: p.session_id,
          pid: p.pid,
          exitCode: p.exit_code,
          signal: p.signal,
          generation: p.generation,
        });
        break;
      }
      case "client_detached": {
        const p = params as unknown as ClientDetachedParams;
        if (p.client_id !== clientId) return;
        attached = false;
        setStatus("disconnected", p.reason);
        break;
      }
      default:
        break;
    }
  };

  const scheduleReconnect = (reason?: string) => {
    if (disposed || !allowReconnect) {
      setStatus(disposed ? "disposed" : "disconnected", reason);
      return;
    }
    if (attempts >= maxAttempts) {
      setStatus("disconnected", "max reconnect attempts reached");
      return;
    }
    const delay = Math.min(maxDelay, Math.round(initialDelay * Math.pow(factor, attempts)));
    attempts += 1;
    setStatus("reconnecting", `retrying in ${delay}ms`);
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      connect();
    }, delay);
  };

  const connect = () => {
    if (disposed) return;
    if (reconnectTimer !== null) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    setStatus(attempts === 0 ? "connecting" : "reconnecting");

    let targetUrl = options.url;
    let protocols: string[] | undefined;
    if (authMode === "query") {
      const parsed = new URL(options.url);
      parsed.searchParams.set("token", options.token);
      targetUrl = parsed.toString();
    } else {
      protocols = ["zmux-v1", `zmux-token.${options.token}`];
    }

    const ws = wsFactory(targetUrl, protocols);
    socket = ws;

    const bufferedNotifications: Array<{ method: string; params: unknown }> = [];
    let attachComplete = false;

    ws.onopen = () => {
      if (disposed || socket !== ws) return;
      void (async () => {
        try {
          let result: AttachResult;
          try {
            result = await rpc<AttachResult>(
              "client.attach",
              buildAttachParams(true) as Record<string, unknown>,
            );
          } catch (err) {
            if (err instanceof ZmuxRpcError && err.kind === "invalid_params") {
              result = await rpc<AttachResult>(
                "client.attach",
                buildAttachParams(false) as Record<string, unknown>,
              );
            } else {
              throw err;
            }
          }
          if (disposed || socket !== ws) return;

          clientId = result.clientId;
          sessionId = result.sessionId;
          attached = true;
          attempts = 0;

          const { bytes, dropped } = reconciler.applyAttach(result);
          if (dropped) options.onDropped?.(dropped);
          if (bytes.byteLength > 0) terminal.write(bytes);

          attachComplete = true;
          for (const queued of bufferedNotifications) {
            handleNotification(queued.method, queued.params);
          }
          bufferedNotifications.length = 0;

          setStatus("connected");
          options.onAttach?.(result);
        } catch (err) {
          const error = err instanceof Error ? err : new ZmuxError(String(err));
          options.onError?.(error);
          ws.close();
        }
      })();
    };

    ws.onmessage = (event) => {
      if (disposed || socket !== ws) return;
      if (typeof event.data !== "string") return;
      let msg: Record<string, unknown>;
      try {
        const parsed: unknown = JSON.parse(event.data);
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return;
        msg = parsed as Record<string, unknown>;
      } catch {
        return;
      }

      if ("id" in msg && ("result" in msg || "error" in msg)) {
        const id = msg.id;
        if (typeof id !== "number") return;
        const entry = pending.get(id);
        if (!entry) return;
        pending.delete(id);
        const resp = msg as unknown as JsonRpcResponse;
        if ("error" in resp) {
          entry.reject(
            new ZmuxRpcError({
              code: resp.error.code,
              kind: inferErrorKind(resp.error.code, resp.error.data?.kind),
              rpcMessage: resp.error.message,
              method: entry.method,
            }),
          );
        } else {
          entry.resolve(resp.result);
        }
        return;
      }

      if (typeof msg.method === "string") {
        if (!attachComplete) {
          bufferedNotifications.push({ method: msg.method, params: msg.params });
        } else {
          handleNotification(msg.method, msg.params);
        }
      }
    };

    ws.onerror = () => {
      if (disposed || socket !== ws) return;
      options.onError?.(new ZmuxError("WebSocket transport error"));
    };

    ws.onclose = (ev) => {
      if (socket === ws) {
        socket = null;
        attached = false;
        rejectAllPending(new ZmuxError("WebSocket connection closed"));
        scheduleReconnect(ev.reason || `code ${ev.code ?? 1006}`);
      }
    };
  };

  const dataDisp = terminal.onData((data) => {
    if (disposed || options.readOnly || !attached || !reconciler.paneId) return;
    const b64 = encodeBase64(textEncoder.encode(data));
    void rpc("session.send", { sessionId: reconciler.paneId, dataBase64: b64 }).catch((err) => {
      options.onError?.(err instanceof Error ? err : new ZmuxError(String(err)));
    });
  });

  const binaryDisp = terminal.onBinary?.((binary) => {
    if (disposed || options.readOnly || !attached || !reconciler.paneId) return;
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) {
      bytes[i] = binary.charCodeAt(i) & 0xff;
    }
    void rpc("session.send", {
      sessionId: reconciler.paneId,
      dataBase64: encodeBase64(bytes),
    }).catch((err) => {
      options.onError?.(err instanceof Error ? err : new ZmuxError(String(err)));
    });
  });

  const resizeDisp = terminal.onResize?.(({ rows, cols }) => {
    if (
      disposed ||
      options.readOnly ||
      options.resizePolicy === "none" ||
      !attached ||
      !reconciler.paneId
    ) {
      return;
    }
    void rpc("session.resize", { sessionId: reconciler.paneId, rows, cols }).catch((err) => {
      options.onError?.(err instanceof Error ? err : new ZmuxError(String(err)));
    });
  });

  connect();

  return {
    get status() {
      return status;
    },
    get clientId() {
      return clientId;
    },
    get paneId() {
      return reconciler.paneId;
    },
    get sessionId() {
      return sessionId;
    },
    get generation() {
      return reconciler.generation;
    },
    get nextOffset() {
      return reconciler.nextOffset;
    },
    async send(text: string, enter = false): Promise<void> {
      if (!reconciler.paneId) throw new ZmuxError("Not attached to a pane");
      await rpc("session.send", { sessionId: reconciler.paneId, text, enter });
    },
    async sendKey(key: string): Promise<void> {
      if (!reconciler.paneId) throw new ZmuxError("Not attached to a pane");
      await rpc("session.sendKey", { sessionId: reconciler.paneId, key });
    },
    async resize(rows: number, cols: number): Promise<void> {
      if (!reconciler.paneId) throw new ZmuxError("Not attached to a pane");
      await rpc("session.resize", { sessionId: reconciler.paneId, rows, cols });
    },
    rpc,
    reconnectNow(): void {
      if (disposed) return;
      attempts = 0;
      if (socket) {
        const current = socket;
        socket = null;
        current.close(1000, "reconnect");
      }
      connect();
    },
    dispose(): void {
      if (disposed) return;
      disposed = true;
      if (reconnectTimer !== null) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }
      disposeLike(dataDisp);
      disposeLike(binaryDisp);
      disposeLike(resizeDisp);
      rejectAllPending(new ZmuxError("XtermAttachment disposed"));
      if (socket) {
        const current = socket;
        socket = null;
        current.close(1000, "disposed");
      }
      setStatus("disposed");
    },
  };
}
