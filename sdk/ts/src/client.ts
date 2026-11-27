import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";

import { AttachedPane } from "./attached-pane.ts";
import {
  ZmuxConnectionError,
  ZmuxFrameError,
  ZmuxRpcError,
  ZmuxTimeoutError,
  inferErrorKind,
} from "./errors.ts";
import { DEFAULT_MAX_FRAME_BYTES, NdjsonFrameParser } from "./framing.ts";
import { resolveSocketPath } from "./socket-path.ts";
import type {
  AttachResult,
  CaptureResult,
  ClientAttachParams,
  ClientDetachParams,
  ClientInfo,
  ClientSetModeParams,
  ClientSwitchParams,
  CommandExecParams,
  JsonRpcResponse,
  KeyBindParams,
  KeyBinding,
  KeyDispatchParams,
  KeyDispatchResult,
  MuxSnapshot,
  OkResult,
  PaneCloseParams,
  PaneExecParams,
  PaneExecResult,
  PaneHandle,
  PaneMetadataParams,
  PaneMetadataResult,
  PaneRecordParams,
  PaneRecordResult,
  PaneRenameParams,
  PaneResizeSplitParams,
  PaneRespawnParams,
  PaneSelectParams,
  PaneSignalParams,
  PaneSignalResult,
  PaneSplitParams,
  PaneWaitParams,
  PaneWaitResult,
  PaneZoomParams,
  PingResult,
  ScreenSnapshot,
  SessionCaptureParams,
  SessionCreateParams,
  SessionCreateResult,
  SessionInfo,
  SessionListItem,
  SessionRenameParams,
  SessionResizeParams,
  SessionScreenParams,
  SessionSendKeyParams,
  SessionSendParams,
  SessionTargetParams,
  SubscribeEventsParams,
  SubscribeEventsResult,
  WindowCloseParams,
  WindowNewParams,
  WindowRenameParams,
  WindowSelectParams,
  ZmuxNotification,
  ZmuxNotificationMap,
  ZmuxNotificationMethod,
} from "./types.ts";

export interface ZmuxClientOptions {
  /** Override socket path. Defaults to zmux precedence rules. */
  socketPath?: string;
  /** Automatically spawn `zmuxd` if the socket is missing or refused. */
  spawnDaemon?: boolean;
  /** Explicit path to the `zmuxd` binary when `spawnDaemon` is true. */
  daemonBinary?: string;
  /** Idle timeout in seconds passed to auto-spawned `zmuxd`. */
  daemonIdleSeconds?: number;
  /** Max time to wait when connecting or auto-spawning `zmuxd` (default 4000 ms). */
  connectTimeoutMs?: number;
  /** Default per-RPC timeout in milliseconds (default 15000 ms). */
  defaultRequestTimeoutMs?: number;
  /** Maximum NDJSON frame size in bytes (default 16 MiB). */
  maxFrameBytes?: number;
  /** Custom environment map for socket resolution and daemon lookup. */
  env?: Record<string, string | undefined>;
}

export interface RpcCallOptions {
  timeoutMs?: number;
  signal?: AbortSignal;
}

interface PendingRequest {
  method: string;
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout> | null;
  cleanupAbort: (() => void) | null;
}

interface NotificationIteratorState {
  queue: ZmuxNotification[];
  waiting: ((res: IteratorResult<ZmuxNotification>) => void) | null;
  done: boolean;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isExecutableFile(candidate: string): boolean {
  try {
    const st = fs.statSync(candidate);
    if (!st.isFile()) return false;
    fs.accessSync(candidate, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function findDaemonBinary(
  explicit: string | undefined,
  env: Record<string, string | undefined>,
): string | null {
  if (explicit) {
    return isExecutableFile(explicit) ? explicit : null;
  }
  const envBin = env.ZMUXD_BIN;
  if (envBin && isExecutableFile(envBin)) return envBin;

  const pathVar = env.PATH ?? process.env.PATH ?? "";
  const candidates = ["zmuxd", "smithers-session-daemon"];
  for (const dir of pathVar.split(path.delimiter)) {
    if (!dir) continue;
    for (const name of candidates) {
      const full = path.join(dir, name);
      if (isExecutableFile(full)) return full;
    }
  }
  return null;
}

function connectUnixOnce(socketPath: string, timeoutMs: number): Promise<net.Socket> {
  return new Promise<net.Socket>((resolve, reject) => {
    const socket = net.createConnection({ path: socketPath });
    let settled = false;

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(
        new ZmuxTimeoutError(
          `Timed out connecting to zmuxd at ${socketPath} after ${timeoutMs}ms`,
          timeoutMs,
          "connect",
        ),
      );
    }, timeoutMs);

    const onConnect = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.off("error", onError);
      resolve(socket);
    };

    const onError = (err: NodeJS.ErrnoException) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.off("connect", onConnect);
      socket.destroy();
      reject(
        new ZmuxConnectionError(`Failed to connect to zmuxd at ${socketPath}: ${err.message}`, {
          socketPath,
          code: err.code,
          cause: err,
        }),
      );
    };

    socket.once("connect", onConnect);
    socket.once("error", onError);
  });
}

function isRetryableConnectError(err: unknown): boolean {
  if (!(err instanceof ZmuxConnectionError)) return false;
  return err.code === "ENOENT" || err.code === "ECONNREFUSED" || err.code === "EAGAIN";
}

function spawnDetachedDaemon(
  binary: string,
  socketPath: string,
  idleSeconds: number | undefined,
  env: Record<string, string | undefined>,
): void {
  const args = ["--socket", socketPath];
  if (idleSeconds !== undefined) {
    args.push("--idle-seconds", String(idleSeconds));
  }
  const child = spawn(binary, args, {
    detached: true,
    stdio: "ignore",
    env: env as NodeJS.ProcessEnv,
  });
  child.unref();
}

export class ZmuxClient {
  readonly socketPath: string;
  private readonly socket: net.Socket;
  private readonly parser: NdjsonFrameParser;
  private readonly defaultRequestTimeoutMs: number;
  private readonly pending = new Map<number, PendingRequest>();
  private readonly anyListeners = new Set<(notification: ZmuxNotification) => void>();
  private readonly methodListeners = new Map<
    ZmuxNotificationMethod,
    Set<(params: unknown) => void>
  >();
  private readonly closeListeners = new Set<(err?: Error) => void>();
  private readonly iterators = new Set<NotificationIteratorState>();
  private nextId = 1;
  private _closed = false;

  private constructor(
    socket: net.Socket,
    socketPath: string,
    defaultRequestTimeoutMs: number,
    maxFrameBytes: number,
  ) {
    this.socket = socket;
    this.socketPath = socketPath;
    this.defaultRequestTimeoutMs = defaultRequestTimeoutMs;
    this.parser = new NdjsonFrameParser(maxFrameBytes);

    this.socket.on("data", (chunk: Buffer) => this.handleChunk(chunk));
    this.socket.on("error", (err: Error) => this.handleClose(err));
    this.socket.on("close", () => this.handleClose());
  }

  static async connect(options?: ZmuxClientOptions): Promise<ZmuxClient> {
    const env = options?.env ?? process.env;
    const socketPath = resolveSocketPath(options?.socketPath, { env });
    const connectTimeoutMs = options?.connectTimeoutMs ?? 4_000;
    const defaultRequestTimeoutMs = options?.defaultRequestTimeoutMs ?? 15_000;
    const maxFrameBytes = options?.maxFrameBytes ?? DEFAULT_MAX_FRAME_BYTES;

    let socket: net.Socket;
    try {
      socket = await connectUnixOnce(socketPath, connectTimeoutMs);
    } catch (err) {
      if (!options?.spawnDaemon || !isRetryableConnectError(err)) {
        throw err;
      }
      const binary = findDaemonBinary(options.daemonBinary, env);
      if (!binary) {
        throw new ZmuxConnectionError(
          `Unable to auto-spawn zmuxd: neither zmuxd nor smithers-session-daemon found in PATH`,
          { socketPath, cause: err },
        );
      }

      spawnDetachedDaemon(binary, socketPath, options.daemonIdleSeconds, env);
      const deadline = Date.now() + connectTimeoutMs;
      let backoffMs = 15;
      let connected: net.Socket | null = null;
      let lastErr: unknown = err;

      while (Date.now() < deadline) {
        await sleep(Math.min(backoffMs, Math.max(1, deadline - Date.now())));
        backoffMs = Math.min(backoffMs * 2, 120);
        try {
          connected = await connectUnixOnce(socketPath, Math.max(50, deadline - Date.now()));
          break;
        } catch (retryErr) {
          lastErr = retryErr;
          if (!isRetryableConnectError(retryErr)) {
            throw retryErr;
          }
        }
      }

      if (!connected) {
        throw new ZmuxTimeoutError(
          `Auto-spawned zmuxd at ${socketPath} did not become ready within ${connectTimeoutMs}ms`,
          connectTimeoutMs,
          "spawnDaemon",
        );
      }
      void lastErr;
      socket = connected;
    }

    return new ZmuxClient(socket, socketPath, defaultRequestTimeoutMs, maxFrameBytes);
  }

  get closed(): boolean {
    return this._closed;
  }

  /** Send a JSON-RPC 2.0 request and await its correlated response. */
  call<T = unknown>(
    method: string,
    params?: Record<string, unknown>,
    options?: RpcCallOptions,
  ): Promise<T> {
    if (this._closed) {
      return Promise.reject(
        new ZmuxConnectionError(`Cannot call "${method}": client connection is closed`, {
          socketPath: this.socketPath,
        }),
      );
    }

    const signal = options?.signal;
    if (signal?.aborted) {
      return Promise.reject(
        signal.reason instanceof Error
          ? signal.reason
          : new ZmuxConnectionError(`RPC "${method}" aborted`),
      );
    }

    const id = this.nextId++;
    const timeoutMs = options?.timeoutMs ?? this.defaultRequestTimeoutMs;
    const payload =
      params !== undefined
        ? JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n"
        : JSON.stringify({ jsonrpc: "2.0", id, method }) + "\n";

    return new Promise<T>((resolve, reject) => {
      let timer: ReturnType<typeof setTimeout> | null = null;
      let cleanupAbort: (() => void) | null = null;

      const finishReject = (err: Error) => {
        const entry = this.pending.get(id);
        if (!entry) return;
        this.pending.delete(id);
        if (entry.timer !== null) clearTimeout(entry.timer);
        entry.cleanupAbort?.();
        reject(err);
      };

      if (timeoutMs > 0 && Number.isFinite(timeoutMs)) {
        timer = setTimeout(() => {
          finishReject(
            new ZmuxTimeoutError(
              `zmux RPC "${method}" timed out after ${timeoutMs}ms`,
              timeoutMs,
              method,
            ),
          );
        }, timeoutMs);
      }

      if (signal) {
        const onAbort = () => {
          finishReject(
            signal.reason instanceof Error
              ? signal.reason
              : new ZmuxConnectionError(`RPC "${method}" aborted`),
          );
        };
        signal.addEventListener("abort", onAbort, { once: true });
        cleanupAbort = () => signal.removeEventListener("abort", onAbort);
      }

      this.pending.set(id, {
        method,
        resolve: resolve as (value: unknown) => void,
        reject,
        timer,
        cleanupAbort,
      });

      this.socket.write(payload, (writeErr) => {
        if (writeErr) {
          finishReject(
            new ZmuxConnectionError(`Failed writing "${method}": ${writeErr.message}`, {
              socketPath: this.socketPath,
              cause: writeErr,
            }),
          );
        }
      });
    });
  }

  /** Send a JSON-RPC 2.0 notification (no `id`, no response expected). */
  notify(method: string, params?: Record<string, unknown>): void {
    if (this._closed) {
      throw new ZmuxConnectionError(`Cannot notify "${method}": client connection is closed`, {
        socketPath: this.socketPath,
      });
    }
    const payload =
      params !== undefined
        ? JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n"
        : JSON.stringify({ jsonrpc: "2.0", method }) + "\n";
    this.socket.write(payload);
  }

  // -------------------------------------------------------------------------
  // Typed v0.4.0 RPC methods (all 28 methods)

  ping(options?: RpcCallOptions): Promise<PingResult> {
    return this.call<PingResult>("daemon.ping", {}, options);
  }

  shutdown(options?: RpcCallOptions): Promise<OkResult> {
    return this.call<OkResult>("daemon.shutdown", {}, options);
  }

  snapshot(options?: RpcCallOptions): Promise<MuxSnapshot> {
    return this.call<MuxSnapshot>("mux.snapshot", {}, options);
  }

  createSession(
    params: SessionCreateParams = {},
    options?: RpcCallOptions,
  ): Promise<SessionCreateResult> {
    return this.call<SessionCreateResult>(
      "session.create",
      params as Record<string, unknown>,
      options,
    );
  }

  terminateSession(
    params: string | SessionTargetParams,
    options?: RpcCallOptions,
  ): Promise<OkResult> {
    const body = typeof params === "string" ? { sessionId: params } : params;
    return this.call<OkResult>("session.terminate", body as Record<string, unknown>, options);
  }

  listSessions(options?: RpcCallOptions): Promise<SessionListItem[]> {
    return this.call<SessionListItem[]>("session.list", {}, options);
  }

  infoSession(
    params: string | SessionTargetParams,
    options?: RpcCallOptions,
  ): Promise<SessionInfo> {
    const body = typeof params === "string" ? { sessionId: params } : params;
    return this.call<SessionInfo>("session.info", body as Record<string, unknown>, options);
  }

  resizeSession(params: SessionResizeParams, options?: RpcCallOptions): Promise<OkResult> {
    return this.call<OkResult>("session.resize", params as Record<string, unknown>, options);
  }

  captureSession(
    params: string | SessionCaptureParams,
    options?: RpcCallOptions,
  ): Promise<CaptureResult> {
    const body = typeof params === "string" ? { sessionId: params } : params;
    return this.call<CaptureResult>("session.capture", body as Record<string, unknown>, options);
  }

  send(params: SessionSendParams, options?: RpcCallOptions): Promise<OkResult> {
    return this.call<OkResult>("session.send", params as Record<string, unknown>, options);
  }

  sendKey(params: SessionSendKeyParams, options?: RpcCallOptions): Promise<OkResult> {
    return this.call<OkResult>("session.sendKey", params as Record<string, unknown>, options);
  }

  renameSession(params: SessionRenameParams, options?: RpcCallOptions): Promise<MuxSnapshot> {
    return this.call<MuxSnapshot>("session.rename", params as Record<string, unknown>, options);
  }

  newWindow(params: WindowNewParams, options?: RpcCallOptions): Promise<PaneHandle> {
    return this.call<PaneHandle>("window.new", params as Record<string, unknown>, options);
  }

  selectWindow(
    params: string | WindowSelectParams,
    options?: RpcCallOptions,
  ): Promise<MuxSnapshot> {
    const body = typeof params === "string" ? { windowId: params } : params;
    return this.call<MuxSnapshot>("window.select", body as Record<string, unknown>, options);
  }

  renameWindow(params: WindowRenameParams, options?: RpcCallOptions): Promise<MuxSnapshot> {
    return this.call<MuxSnapshot>("window.rename", params as Record<string, unknown>, options);
  }

  splitPane(params: PaneSplitParams, options?: RpcCallOptions): Promise<PaneHandle> {
    return this.call<PaneHandle>("pane.split", params as Record<string, unknown>, options);
  }

  selectPane(params: string | PaneSelectParams, options?: RpcCallOptions): Promise<MuxSnapshot> {
    const body = typeof params === "string" ? { paneId: params } : params;
    return this.call<MuxSnapshot>("pane.select", body as Record<string, unknown>, options);
  }

  renamePane(params: PaneRenameParams, options?: RpcCallOptions): Promise<MuxSnapshot> {
    return this.call<MuxSnapshot>("pane.rename", params as Record<string, unknown>, options);
  }

  respawnPane(
    params: string | PaneRespawnParams,
    options?: RpcCallOptions,
  ): Promise<MuxSnapshot> {
    const body = typeof params === "string" ? { paneId: params } : params;
    return this.call<MuxSnapshot>("pane.respawn", body as Record<string, unknown>, options);
  }

  attach(params: ClientAttachParams, options?: RpcCallOptions): Promise<AttachResult> {
    return this.call<AttachResult>("client.attach", params as Record<string, unknown>, options);
  }

  /** High-level helper that attaches and returns a streaming `AttachedPane`. */
  attachPane(params: string | ClientAttachParams): Promise<AttachedPane> {
    const body = typeof params === "string" ? { paneId: params } : params;
    return AttachedPane.attach(this, body);
  }

  detach(params: string | ClientDetachParams, options?: RpcCallOptions): Promise<OkResult> {
    const body = typeof params === "string" ? { clientId: params } : params;
    return this.call<OkResult>("client.detach", body as Record<string, unknown>, options);
  }

  switchClient(params: ClientSwitchParams, options?: RpcCallOptions): Promise<MuxSnapshot> {
    return this.call<MuxSnapshot>("client.switch", params as Record<string, unknown>, options);
  }

  listClients(options?: RpcCallOptions): Promise<ClientInfo[]> {
    return this.call<ClientInfo[]>("client.list", {}, options);
  }

  subscribeEvents(
    params: string[] | SubscribeEventsParams,
    options?: RpcCallOptions,
  ): Promise<SubscribeEventsResult> {
    const body = Array.isArray(params) ? { panes: params } : params;
    return this.call<SubscribeEventsResult>(
      "events.subscribe",
      body as Record<string, unknown>,
      options,
    );
  }

  bindKey(params: KeyBindParams, options?: RpcCallOptions): Promise<KeyBinding[]> {
    return this.call<KeyBinding[]>("key.bind", params as Record<string, unknown>, options);
  }

  dispatchKey(params: KeyDispatchParams, options?: RpcCallOptions): Promise<KeyDispatchResult> {
    return this.call<KeyDispatchResult>(
      "key.dispatch",
      params as Record<string, unknown>,
      options,
    );
  }

  listKeys(options?: RpcCallOptions): Promise<KeyBinding[]> {
    return this.call<KeyBinding[]>("key.list", {}, options);
  }

  execCommand(params: CommandExecParams, options?: RpcCallOptions): Promise<MuxSnapshot> {
    return this.call<MuxSnapshot>("command.exec", params as Record<string, unknown>, options);
  }

  // -------------------------------------------------------------------------
  // Additive v0.5.0 / v0.6.0 forward-compatible RPC helpers

  screen(
    params: string | SessionScreenParams,
    options?: RpcCallOptions,
  ): Promise<ScreenSnapshot> {
    const body = typeof params === "string" ? { sessionId: params } : params;
    return this.call<ScreenSnapshot>("session.screen", body as Record<string, unknown>, options);
  }

  waitPane(params: PaneWaitParams, options?: RpcCallOptions): Promise<PaneWaitResult> {
    return this.call<PaneWaitResult>("pane.wait", params as Record<string, unknown>, options);
  }

  execPane(params: PaneExecParams, options?: RpcCallOptions): Promise<PaneExecResult> {
    return this.call<PaneExecResult>("pane.exec", params as Record<string, unknown>, options);
  }

  signalPane(params: PaneSignalParams, options?: RpcCallOptions): Promise<PaneSignalResult> {
    return this.call<PaneSignalResult>("pane.signal", params as Record<string, unknown>, options);
  }

  closePane(params: string | PaneCloseParams, options?: RpcCallOptions): Promise<MuxSnapshot> {
    const body = typeof params === "string" ? { paneId: params } : params;
    return this.call<MuxSnapshot>("pane.close", body as Record<string, unknown>, options);
  }

  closeWindow(
    params: string | WindowCloseParams,
    options?: RpcCallOptions,
  ): Promise<MuxSnapshot> {
    const body = typeof params === "string" ? { windowId: params } : params;
    return this.call<MuxSnapshot>("window.close", body as Record<string, unknown>, options);
  }

  resizeSplit(params: PaneResizeSplitParams, options?: RpcCallOptions): Promise<MuxSnapshot> {
    return this.call<MuxSnapshot>("pane.resizeSplit", params as Record<string, unknown>, options);
  }

  zoomPane(params: string | PaneZoomParams, options?: RpcCallOptions): Promise<MuxSnapshot> {
    const body = typeof params === "string" ? { paneId: params } : params;
    return this.call<MuxSnapshot>("pane.zoom", body as Record<string, unknown>, options);
  }

  setMetadata(
    params: PaneMetadataParams,
    options?: RpcCallOptions,
  ): Promise<PaneMetadataResult> {
    return this.call<PaneMetadataResult>(
      "pane.metadata",
      params as Record<string, unknown>,
      options,
    );
  }

  setClientMode(params: ClientSetModeParams, options?: RpcCallOptions): Promise<ClientInfo> {
    return this.call<ClientInfo>("client.setMode", params as Record<string, unknown>, options);
  }

  recordPane(params: PaneRecordParams, options?: RpcCallOptions): Promise<PaneRecordResult> {
    return this.call<PaneRecordResult>("pane.record", params as Record<string, unknown>, options);
  }

  // -------------------------------------------------------------------------
  // Event subscriptions & lifecycle

  onNotification(listener: (notification: ZmuxNotification) => void): () => void {
    this.anyListeners.add(listener);
    return () => {
      this.anyListeners.delete(listener);
    };
  }

  on<K extends ZmuxNotificationMethod>(
    method: K,
    listener: (params: ZmuxNotificationMap[K]) => void,
  ): () => void {
    let set = this.methodListeners.get(method);
    if (!set) {
      set = new Set();
      this.methodListeners.set(method, set);
    }
    const wrapped = listener as (params: unknown) => void;
    set.add(wrapped);
    return () => {
      set?.delete(wrapped);
    };
  }

  onClose(listener: (err?: Error) => void): () => void {
    this.closeListeners.add(listener);
    return () => {
      this.closeListeners.delete(listener);
    };
  }

  notifications(options?: { signal?: AbortSignal }): AsyncIterable<ZmuxNotification> {
    const signal = options?.signal;
    const client = this;

    return {
      [Symbol.asyncIterator](): AsyncIterator<ZmuxNotification> {
        const state: NotificationIteratorState = {
          queue: [],
          waiting: null,
          done: client._closed,
        };
        if (!state.done) {
          client.iterators.add(state);
        }

        const finish = () => {
          if (state.done) return;
          state.done = true;
          client.iterators.delete(state);
          if (state.waiting) {
            const resolve = state.waiting;
            state.waiting = null;
            resolve({ value: undefined, done: true });
          }
        };

        if (signal) {
          if (signal.aborted) finish();
          else signal.addEventListener("abort", finish, { once: true });
        }

        return {
          next(): Promise<IteratorResult<ZmuxNotification>> {
            if (state.queue.length > 0) {
              const value = state.queue.shift()!;
              return Promise.resolve({ value, done: false });
            }
            if (state.done) {
              return Promise.resolve({ value: undefined, done: true });
            }
            return new Promise<IteratorResult<ZmuxNotification>>((resolve) => {
              state.waiting = resolve;
            });
          },
          return(): Promise<IteratorResult<ZmuxNotification>> {
            finish();
            return Promise.resolve({ value: undefined, done: true });
          },
        };
      },
    };
  }

  close(): void {
    if (this._closed) return;
    this.socket.destroy();
    this.handleClose();
  }

  async [Symbol.asyncDispose](): Promise<void> {
    this.close();
  }

  private handleChunk(chunk: Buffer): void {
    let frames: string[];
    try {
      frames = this.parser.push(chunk);
    } catch (err) {
      const frameErr =
        err instanceof ZmuxFrameError
          ? err
          : new ZmuxFrameError(`Invalid NDJSON frame: ${(err as Error).message}`);
      this.socket.destroy(frameErr);
      this.handleClose(frameErr);
      return;
    }

    for (const line of frames) {
      this.handleFrame(line);
    }
  }

  private handleFrame(line: string): void {
    let msg: Record<string, unknown>;
    try {
      const parsed: unknown = JSON.parse(line);
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
        return;
      }
      msg = parsed as Record<string, unknown>;
    } catch {
      return;
    }

    if ("id" in msg && ("result" in msg || "error" in msg)) {
      const id = msg.id;
      if (typeof id !== "number") return;
      const entry = this.pending.get(id);
      if (!entry) return;
      this.pending.delete(id);
      if (entry.timer !== null) clearTimeout(entry.timer);
      entry.cleanupAbort?.();

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
      const notification = {
        method: msg.method,
        params: msg.params ?? {},
      } as ZmuxNotification;

      for (const listener of this.anyListeners) {
        listener(notification);
      }
      const typedListeners = this.methodListeners.get(notification.method);
      if (typedListeners) {
        for (const listener of typedListeners) {
          listener(notification.params);
        }
      }
      for (const iter of this.iterators) {
        if (iter.done) continue;
        if (iter.waiting) {
          const resolve = iter.waiting;
          iter.waiting = null;
          resolve({ value: notification, done: false });
        } else {
          iter.queue.push(notification);
        }
      }
    }
  }

  private handleClose(err?: Error): void {
    if (this._closed) return;
    this._closed = true;

    const closeError =
      err instanceof ZmuxConnectionError || err instanceof ZmuxFrameError
        ? err
        : new ZmuxConnectionError(
            err ? `zmux connection closed: ${err.message}` : "zmux connection closed",
            { socketPath: this.socketPath, cause: err },
          );

    for (const [, entry] of this.pending) {
      if (entry.timer !== null) clearTimeout(entry.timer);
      entry.cleanupAbort?.();
      entry.reject(closeError);
    }
    this.pending.clear();

    for (const iter of this.iterators) {
      iter.done = true;
      if (iter.waiting) {
        const resolve = iter.waiting;
        iter.waiting = null;
        resolve({ value: undefined, done: true });
      }
    }
    this.iterators.clear();

    for (const listener of this.closeListeners) {
      listener(err);
    }
  }
}
