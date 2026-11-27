import { ZmuxError, ZmuxRpcError, ZmuxTimeoutError } from "./errors.ts";
import { decodeBase64, encodeBase64 } from "./framing.ts";
import type {
  AttachResult,
  ClientAttachParams,
  ClientDetachedParams,
  ClientSwitchedParams,
  DetachReason,
  OkResult,
  PaneOutputDroppedParams,
  PaneOutputParams,
  PaneRespawnedParams,
  ReplayMode,
  SessionExitedParams,
  SessionResizeParams,
  SessionSendKeyParams,
  SessionSendParams,
  ZmuxNotification,
} from "./types.ts";

export interface DroppedOutputEvent {
  paneId: string;
  droppedBytes: number;
  resumeOffset: number;
  generation: number;
}

export interface PaneExitedEvent {
  paneId: string;
  pid: number;
  exitCode: number | null;
  signal: number | null;
  generation: number;
}

export interface PaneRespawnedEvent {
  paneId: string;
  generation: number;
  pid: number;
}

export interface PaneSwitchedEvent {
  clientId: string;
  paneId: string;
  generation: number;
  replayBytes: Uint8Array;
}

export interface PaneDetachedEvent {
  clientId: string;
  reason: DetachReason | string;
}

export interface AttachedPaneEventMap {
  data: Uint8Array;
  dropped: DroppedOutputEvent;
  exited: PaneExitedEvent;
  respawned: PaneRespawnedEvent;
  switched: PaneSwitchedEvent;
  detached: PaneDetachedEvent;
}

export type AttachedPaneEventName = keyof AttachedPaneEventMap;

export interface WaitForOptions {
  pattern?: string | RegExp;
  exit?: boolean;
  idleMs?: number;
  timeoutMs?: number;
  /** When true, pattern matching ignores output received before waitFor() was called. */
  fromNow?: boolean;
  signal?: AbortSignal;
}

export interface WaitForResult {
  reason: "pattern" | "exit" | "idle";
  match?: string;
  groups?: string[];
  text: string;
  exitCode?: number | null;
  signal?: number | null;
}

export interface ReconnectOptions {
  rows?: number;
  cols?: number;
  replayMode?: ReplayMode;
  readOnly?: boolean;
}

export interface ZmuxPaneTransport {
  attach(params: ClientAttachParams): Promise<AttachResult>;
  detach(params: { clientId: string }): Promise<OkResult>;
  send(params: SessionSendParams): Promise<OkResult>;
  sendKey(params: SessionSendKeyParams): Promise<OkResult>;
  resizeSession(params: SessionResizeParams): Promise<OkResult>;
  onNotification(listener: (notification: ZmuxNotification) => void): () => void;
}

/**
 * Pure offset-and-generation byte-stream reconciler shared by `AttachedPane`
 * and `@smithers/zmux/xterm`. Guarantees zero duplicate or dropped bytes across
 * attach replays, concurrent live notifications, drops, respawns, and reconnects.
 */
export class PaneStreamReconciler {
  paneId = "";
  generation = 0;
  nextOffset: number | null = null;

  applyAttach(result: AttachResult): { bytes: Uint8Array; dropped?: DroppedOutputEvent } {
    const raw = decodeBase64(result.replayBase64);
    const sameStream =
      this.paneId.length > 0 &&
      result.paneId === this.paneId &&
      result.generation === this.generation &&
      this.nextOffset !== null;

    if (!sameStream) {
      this.paneId = result.paneId;
      this.generation = result.generation;
      this.nextOffset = result.replayEndOffset;
      return { bytes: raw };
    }

    const prev = this.nextOffset as number;
    if (result.replayEndOffset <= prev) {
      return { bytes: new Uint8Array(0) };
    }

    if (result.replayStartOffset <= prev) {
      const skip = prev - result.replayStartOffset;
      this.nextOffset = result.replayEndOffset;
      if (skip >= raw.byteLength) {
        return { bytes: new Uint8Array(0) };
      }
      return { bytes: skip === 0 ? raw : raw.subarray(skip) };
    }

    // Scrollback wrapped past our previous cursor while disconnected.
    const droppedBytes = result.replayStartOffset - prev;
    this.nextOffset = result.replayEndOffset;
    return {
      bytes: raw,
      dropped: {
        paneId: this.paneId,
        droppedBytes,
        resumeOffset: result.replayStartOffset,
        generation: this.generation,
      },
    };
  }

  applyOutput(params: PaneOutputParams): Uint8Array {
    if (params.pane_id !== this.paneId) return new Uint8Array(0);
    if (params.generation < this.generation) return new Uint8Array(0);

    if (params.generation > this.generation) {
      this.generation = params.generation;
      this.nextOffset = null;
    }

    const raw = decodeBase64(params.data_base64);
    const previous = this.nextOffset ?? params.offset;
    const skip = Math.min(Math.max(0, previous - params.offset), raw.byteLength);
    this.nextOffset = Math.max(previous, params.offset + raw.byteLength);

    if (skip >= raw.byteLength) return new Uint8Array(0);
    return skip === 0 ? raw : raw.subarray(skip);
  }

  applyDropped(params: PaneOutputDroppedParams): DroppedOutputEvent | null {
    if (params.pane_id !== this.paneId) return null;
    if (params.generation < this.generation) return null;

    if (params.generation > this.generation) {
      this.generation = params.generation;
      this.nextOffset = params.resume_offset;
    } else {
      this.nextOffset = Math.max(this.nextOffset ?? 0, params.resume_offset);
    }

    return {
      paneId: params.pane_id,
      droppedBytes: params.dropped_bytes,
      resumeOffset: params.resume_offset,
      generation: params.generation,
    };
  }

  applyRespawned(params: PaneRespawnedParams): boolean {
    if (params.pane_id !== this.paneId) return false;
    if (params.generation < this.generation) return false;
    if (params.generation !== this.generation) {
      this.generation = params.generation;
      this.nextOffset = null;
    }
    return true;
  }

  applySwitched(params: ClientSwitchedParams): { paneId: string; generation: number; bytes: Uint8Array } {
    const replayB64 = params.replayBase64 ?? params.replay_base64 ?? "";
    const endOffset = params.replayEndOffset ?? params.replay_end_offset ?? null;
    this.paneId = params.pane_id;
    this.generation = params.generation;
    this.nextOffset = endOffset;
    return {
      paneId: this.paneId,
      generation: this.generation,
      bytes: decodeBase64(replayB64),
    };
  }
}

interface OutputIteratorState {
  queue: Uint8Array[];
  waiting: ((result: IteratorResult<Uint8Array>) => void) | null;
  done: boolean;
}

const MAX_RETAINED_TEXT_CHARS = 2 * 1024 * 1024;

export class AttachedPane {
  private readonly transport: ZmuxPaneTransport;
  private readonly reconciler = new PaneStreamReconciler();
  private readonly decoder = new TextDecoder("utf-8", { fatal: false });
  private readonly listeners: {
    [K in AttachedPaneEventName]: Set<(payload: AttachedPaneEventMap[K]) => void>;
  } = {
    data: new Set(),
    dropped: new Set(),
    exited: new Set(),
    respawned: new Set(),
    switched: new Set(),
    detached: new Set(),
  };
  private readonly iterators = new Set<OutputIteratorState>();
  private unsubscribeTransport: (() => void) | null = null;
  private retainedText = "";
  private replayData: Uint8Array = new Uint8Array(0);
  private _clientId = "";
  private _sessionId = "";
  private _windowId = "";
  private _rows = 24;
  private _cols = 80;
  private _created = false;
  private _exited = false;
  private _exitCode: number | null = null;
  private _signal: number | null = null;
  private _detached = false;
  private _disposed = false;

  private constructor(transport: ZmuxPaneTransport) {
    this.transport = transport;
  }

  static async attach(
    transport: ZmuxPaneTransport,
    params: ClientAttachParams,
  ): Promise<AttachedPane> {
    const pane = new AttachedPane(transport);
    await pane.performInitialAttach(params);
    return pane;
  }

  get clientId(): string {
    return this._clientId;
  }

  get sessionId(): string {
    return this._sessionId;
  }

  get windowId(): string {
    return this._windowId;
  }

  get paneId(): string {
    return this.reconciler.paneId;
  }

  get rows(): number {
    return this._rows;
  }

  get cols(): number {
    return this._cols;
  }

  get created(): boolean {
    return this._created;
  }

  get exited(): boolean {
    return this._exited;
  }

  get exitCode(): number | null {
    return this._exitCode;
  }

  get signal(): number | null {
    return this._signal;
  }

  get generation(): number {
    return this.reconciler.generation;
  }

  get nextOffset(): number | null {
    return this.reconciler.nextOffset;
  }

  get detached(): boolean {
    return this._detached;
  }

  /** Decoded bytes from the initial attach replay. */
  get replayBytes(): Uint8Array {
    return this.replayData;
  }

  /** Accumulated UTF-8 text received since attach (bounded to 2 MiB). */
  get bufferedText(): string {
    return this.retainedText;
  }

  on<K extends AttachedPaneEventName>(
    event: K,
    listener: (payload: AttachedPaneEventMap[K]) => void,
  ): () => void {
    const set = this.listeners[event];
    set.add(listener);
    return () => {
      set.delete(listener);
    };
  }

  /**
   * Async iterable of deduplicated raw PTY output chunks.
   * By default yields the initial replay chunk first (if non-empty) unless `includeReplay: false`.
   */
  output(options?: { includeReplay?: boolean; signal?: AbortSignal }): AsyncIterable<Uint8Array> {
    const includeReplay = options?.includeReplay ?? true;
    const signal = options?.signal;
    const pane = this;

    return {
      [Symbol.asyncIterator](): AsyncIterator<Uint8Array> {
        const state: OutputIteratorState = {
          queue: [],
          waiting: null,
          done: pane._disposed || pane._detached,
        };
        if (includeReplay && pane.replayData.byteLength > 0) {
          state.queue.push(pane.replayData);
        }
        if (!state.done) {
          pane.iterators.add(state);
        }

        const finish = () => {
          if (state.done) return;
          state.done = true;
          pane.iterators.delete(state);
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
          next(): Promise<IteratorResult<Uint8Array>> {
            if (state.queue.length > 0) {
              const value = state.queue.shift()!;
              return Promise.resolve({ value, done: false });
            }
            if (state.done) {
              return Promise.resolve({ value: undefined, done: true });
            }
            return new Promise<IteratorResult<Uint8Array>>((resolve) => {
              state.waiting = resolve;
            });
          },
          return(): Promise<IteratorResult<Uint8Array>> {
            finish();
            return Promise.resolve({ value: undefined, done: true });
          },
        };
      },
    };
  }

  async send(text: string, enter = false): Promise<void> {
    await this.transport.send({ sessionId: this.paneId, text, enter });
  }

  async sendBytes(bytes: Uint8Array): Promise<void> {
    await this.transport.send({ sessionId: this.paneId, dataBase64: encodeBase64(bytes) });
  }

  async sendKey(key: string): Promise<void> {
    await this.transport.sendKey({ sessionId: this.paneId, key });
  }

  async resize(rows: number, cols: number): Promise<void> {
    await this.transport.resizeSession({ sessionId: this.paneId, rows, cols });
    this._rows = rows;
    this._cols = cols;
  }

  /**
   * Wait until a pattern appears in pane output, the process exits, or output stays idle.
   */
  waitFor(options: WaitForOptions): Promise<WaitForResult> {
    const { pattern, exit = false, idleMs, timeoutMs = 30_000, fromNow = false, signal } = options;
    if (pattern === undefined && !exit && idleMs === undefined) {
      return Promise.reject(
        new ZmuxError("waitFor requires at least one of pattern, exit, or idleMs"),
      );
    }

    const matchPattern = (haystack: string): { match: string; groups?: string[] } | null => {
      if (pattern === undefined) return null;
      if (typeof pattern === "string") {
        return haystack.includes(pattern) ? { match: pattern } : null;
      }
      const re = new RegExp(pattern.source, pattern.flags.replace(/g/g, ""));
      const m = re.exec(haystack);
      if (!m) return null;
      return { match: m[0], groups: m.slice(1) };
    };

    if (exit && this._exited) {
      return Promise.resolve({
        reason: "exit",
        text: this.retainedText,
        exitCode: this._exitCode,
        signal: this._signal,
      });
    }

    let windowText = fromNow ? "" : this.retainedText;
    if (pattern !== undefined && !fromNow) {
      const immediate = matchPattern(windowText);
      if (immediate) {
        return Promise.resolve({
          reason: "pattern",
          match: immediate.match,
          groups: immediate.groups,
          text: windowText,
        });
      }
    }

    if (signal?.aborted) {
      return Promise.reject(
        signal.reason instanceof Error ? signal.reason : new ZmuxError("waitFor aborted"),
      );
    }

    return new Promise<WaitForResult>((resolve, reject) => {
      let settled = false;
      let timeoutTimer: ReturnType<typeof setTimeout> | null = null;
      let idleTimer: ReturnType<typeof setTimeout> | null = null;
      const waitDecoder = new TextDecoder("utf-8", { fatal: false });

      const cleanup = () => {
        if (timeoutTimer !== null) clearTimeout(timeoutTimer);
        if (idleTimer !== null) clearTimeout(idleTimer);
        offData();
        offExited();
        offDetached();
        signal?.removeEventListener("abort", onAbort);
      };

      const finishResolve = (result: WaitForResult) => {
        if (settled) return;
        settled = true;
        cleanup();
        resolve(result);
      };

      const finishReject = (err: Error) => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(err);
      };

      const resetIdle = () => {
        if (idleMs === undefined) return;
        if (idleTimer !== null) clearTimeout(idleTimer);
        idleTimer = setTimeout(() => {
          finishResolve({ reason: "idle", text: windowText });
        }, idleMs);
      };

      const onAbort = () => {
        finishReject(
          signal?.reason instanceof Error ? signal.reason : new ZmuxError("waitFor aborted"),
        );
      };

      const offData = this.on("data", (chunk) => {
        if (chunk.byteLength === 0) return;
        const decoded = waitDecoder.decode(chunk, { stream: true });
        if (decoded.length > 0) {
          windowText += decoded;
          if (windowText.length > MAX_RETAINED_TEXT_CHARS) {
            windowText = windowText.slice(windowText.length - MAX_RETAINED_TEXT_CHARS);
          }
        }
        if (pattern !== undefined) {
          const hit = matchPattern(windowText);
          if (hit) {
            finishResolve({
              reason: "pattern",
              match: hit.match,
              groups: hit.groups,
              text: windowText,
            });
            return;
          }
        }
        resetIdle();
      });

      const offExited = this.on("exited", (ev) => {
        if (exit) {
          finishResolve({
            reason: "exit",
            text: windowText,
            exitCode: ev.exitCode,
            signal: ev.signal,
          });
        }
      });

      const offDetached = this.on("detached", (ev) => {
        finishReject(new ZmuxError(`pane detached while waiting (${ev.reason})`));
      });

      if (signal) {
        signal.addEventListener("abort", onAbort, { once: true });
      }

      timeoutTimer = setTimeout(() => {
        finishReject(new ZmuxTimeoutError(`waitFor timed out after ${timeoutMs}ms`, timeoutMs, "waitFor"));
      }, timeoutMs);

      resetIdle();
    });
  }

  async detach(): Promise<void> {
    if (this._detached || this._disposed) return;
    this._detached = true;
    const id = this._clientId;
    try {
      if (id.length > 0) {
        await this.transport.detach({ clientId: id });
      }
    } finally {
      this.closeIterators();
      this.unsubscribeTransport?.();
      this.unsubscribeTransport = null;
    }
  }

  /**
   * Re-attach to the current pane using `resumeFromOffset` and `resumeGeneration`
   * when available, falling back gracefully on v0.4.0 daemons and deduplicating
   * any overlapping replay bytes via `PaneStreamReconciler`.
   */
  async reconnect(options?: ReconnectOptions): Promise<AttachResult> {
    if (this._disposed) {
      throw new ZmuxError("Cannot reconnect a disposed AttachedPane");
    }

    const previousClientId = this._clientId;
    if (!this._detached && previousClientId.length > 0) {
      try {
        await this.transport.detach({ clientId: previousClientId });
      } catch {
        // Previous client may already be gone after a transport drop.
      }
    }

    this.unsubscribeTransport?.();
    const buffered: ZmuxNotification[] = [];
    let ready = false;
    this.unsubscribeTransport = this.transport.onNotification((n) => {
      if (!ready) buffered.push(n);
      else this.handleNotification(n);
    });

    const baseParams: ClientAttachParams = {
      paneId: this.paneId,
      rows: options?.rows ?? this._rows,
      cols: options?.cols ?? this._cols,
    };
    const resumeParams: ClientAttachParams = {
      ...baseParams,
      ...(this.reconciler.nextOffset !== null
        ? {
            resumeFromOffset: this.reconciler.nextOffset,
            resumeGeneration: this.reconciler.generation,
          }
        : {}),
      ...(options?.replayMode !== undefined ? { replayMode: options.replayMode } : {}),
      ...(options?.readOnly !== undefined ? { readOnly: options.readOnly } : {}),
    };

    let result: AttachResult;
    try {
      result = await this.transport.attach(resumeParams);
    } catch (err) {
      if (err instanceof ZmuxRpcError && err.kind === "invalid_params") {
        // Fallback cleanly for strict v0.4.0 daemons rejecting additive params.
        result = await this.transport.attach(baseParams);
      } else {
        this.unsubscribeTransport?.();
        this.unsubscribeTransport = null;
        throw err;
      }
    }

    this._detached = false;
    this.applyAttachResult(result, false);
    ready = true;
    for (const queued of buffered) {
      this.handleNotification(queued);
    }
    return result;
  }

  dispose(): void {
    if (this._disposed) return;
    this._disposed = true;
    this.unsubscribeTransport?.();
    this.unsubscribeTransport = null;
    this.closeIterators();
  }

  async [Symbol.asyncDispose](): Promise<void> {
    try {
      await this.detach();
    } finally {
      this.dispose();
    }
  }

  private async performInitialAttach(params: ClientAttachParams): Promise<void> {
    const buffered: ZmuxNotification[] = [];
    let ready = false;

    this.unsubscribeTransport = this.transport.onNotification((notification) => {
      if (!ready) buffered.push(notification);
      else this.handleNotification(notification);
    });

    let result: AttachResult;
    try {
      result = await this.transport.attach(params);
    } catch (err) {
      this.unsubscribeTransport?.();
      this.unsubscribeTransport = null;
      throw err;
    }

    this.applyAttachResult(result, true);
    ready = true;
    for (const queued of buffered) {
      this.handleNotification(queued);
    }
  }

  private applyAttachResult(result: AttachResult, isInitial: boolean): void {
    this._clientId = result.clientId;
    this._sessionId = result.sessionId;
    this._windowId = result.windowId;
    this._rows = result.rows;
    this._cols = result.cols;
    this._created = result.created;
    this._exited = result.exited;
    this._exitCode = result.exitCode;
    this._signal = result.signal;

    const { bytes, dropped } = this.reconciler.applyAttach(result);
    if (isInitial) {
      this.replayData = bytes;
    }
    if (dropped) {
      this.emit("dropped", dropped);
    }
    if (bytes.byteLength > 0) {
      this.appendRetainedText(bytes);
      if (!isInitial) {
        this.deliverData(bytes);
      }
    }
  }

  private handleNotification(notification: ZmuxNotification): void {
    switch (notification.method) {
      case "pane_output": {
        const bytes = this.reconciler.applyOutput(notification.params);
        if (bytes.byteLength > 0) {
          this.appendRetainedText(bytes);
          this.deliverData(bytes);
        }
        break;
      }
      case "pane_output_dropped": {
        const dropped = this.reconciler.applyDropped(notification.params);
        if (dropped) this.emit("dropped", dropped);
        break;
      }
      case "session_exited": {
        const p: SessionExitedParams = notification.params;
        if (p.session_id !== this.paneId) return;
        if (p.generation < this.reconciler.generation) return;
        this._exited = true;
        this._exitCode = p.exit_code;
        this._signal = p.signal;
        this.emit("exited", {
          paneId: p.session_id,
          pid: p.pid,
          exitCode: p.exit_code,
          signal: p.signal,
          generation: p.generation,
        });
        break;
      }
      case "pane_respawned": {
        const p: PaneRespawnedParams = notification.params;
        if (!this.reconciler.applyRespawned(p)) return;
        this._exited = false;
        this._exitCode = null;
        this._signal = null;
        this.emit("respawned", {
          paneId: p.pane_id,
          generation: p.generation,
          pid: p.pid,
        });
        break;
      }
      case "client_switched": {
        const p: ClientSwitchedParams = notification.params;
        if (p.client_id !== this._clientId) return;
        const switched = this.reconciler.applySwitched(p);
        this._exited = false;
        this._exitCode = null;
        this._signal = null;
        this.emit("switched", {
          clientId: p.client_id,
          paneId: switched.paneId,
          generation: switched.generation,
          replayBytes: switched.bytes,
        });
        if (switched.bytes.byteLength > 0) {
          this.appendRetainedText(switched.bytes);
          this.deliverData(switched.bytes);
        }
        break;
      }
      case "client_detached": {
        const p: ClientDetachedParams = notification.params;
        if (p.client_id !== this._clientId) return;
        this._detached = true;
        this.emit("detached", { clientId: p.client_id, reason: p.reason });
        this.closeIterators();
        break;
      }
      default:
        break;
    }
  }

  private appendRetainedText(bytes: Uint8Array): void {
    const chunk = this.decoder.decode(bytes, { stream: true });
    if (chunk.length === 0) return;
    this.retainedText += chunk;
    if (this.retainedText.length > MAX_RETAINED_TEXT_CHARS) {
      this.retainedText = this.retainedText.slice(this.retainedText.length - MAX_RETAINED_TEXT_CHARS);
    }
  }

  private deliverData(bytes: Uint8Array): void {
    this.emit("data", bytes);
    for (const iter of this.iterators) {
      if (iter.done) continue;
      if (iter.waiting) {
        const resolve = iter.waiting;
        iter.waiting = null;
        resolve({ value: bytes, done: false });
      } else {
        iter.queue.push(bytes);
      }
    }
  }

  private emit<K extends AttachedPaneEventName>(event: K, payload: AttachedPaneEventMap[K]): void {
    for (const listener of this.listeners[event]) {
      listener(payload);
    }
  }

  private closeIterators(): void {
    for (const iter of this.iterators) {
      iter.done = true;
      if (iter.waiting) {
        const resolve = iter.waiting;
        iter.waiting = null;
        resolve({ value: undefined, done: true });
      }
    }
    this.iterators.clear();
  }
}
