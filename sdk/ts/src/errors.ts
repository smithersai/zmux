export const ZMUX_ERROR_CODES = {
  PARSE_ERROR: -32700,
  INVALID_REQUEST: -32600,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL_ERROR: -32603,
  SESSION_ERROR: -32000,
} as const;

export type ZmuxErrorCode = (typeof ZMUX_ERROR_CODES)[keyof typeof ZMUX_ERROR_CODES];

export const ZMUX_ERROR_KINDS = [
  "parse",
  "invalid_request",
  "method_not_found",
  "invalid_params",
  "not_found",
  "terminated",
  "conflict",
  "limit",
  "spawn_failed",
  "io",
  "internal",
] as const;

export type ZmuxErrorKind = (typeof ZMUX_ERROR_KINDS)[number];

export function isZmuxErrorKind(value: unknown): value is ZmuxErrorKind {
  return typeof value === "string" && (ZMUX_ERROR_KINDS as readonly string[]).includes(value);
}

export function inferErrorKind(code: number, rawKind?: unknown): ZmuxErrorKind {
  if (isZmuxErrorKind(rawKind)) return rawKind;
  switch (code) {
    case ZMUX_ERROR_CODES.PARSE_ERROR:
      return "parse";
    case ZMUX_ERROR_CODES.INVALID_REQUEST:
      return "invalid_request";
    case ZMUX_ERROR_CODES.METHOD_NOT_FOUND:
      return "method_not_found";
    case ZMUX_ERROR_CODES.INVALID_PARAMS:
      return "invalid_params";
    default:
      return "internal";
  }
}

export class ZmuxError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = new.target.name;
  }
}

export class ZmuxRpcError extends ZmuxError {
  readonly code: number;
  readonly kind: ZmuxErrorKind;
  readonly rpcMessage: string;
  readonly method?: string;

  constructor(params: {
    code: number;
    kind?: ZmuxErrorKind;
    rpcMessage: string;
    method?: string;
  }) {
    const kind = inferErrorKind(params.code, params.kind);
    const prefix = params.method ? `zmux RPC "${params.method}" failed` : "zmux RPC failed";
    super(`${prefix} [${kind}, ${params.code}]: ${params.rpcMessage}`);
    this.code = params.code;
    this.kind = kind;
    this.rpcMessage = params.rpcMessage;
    this.method = params.method;
  }

  isKind(kind: ZmuxErrorKind): boolean {
    return this.kind === kind;
  }
}

export class ZmuxConnectionError extends ZmuxError {
  readonly socketPath?: string;
  readonly code?: string;

  constructor(
    message: string,
    options?: { socketPath?: string; code?: string; cause?: unknown },
  ) {
    super(message, { cause: options?.cause });
    this.socketPath = options?.socketPath;
    this.code = options?.code;
  }
}

export class ZmuxTimeoutError extends ZmuxError {
  readonly timeoutMs: number;
  readonly operation?: string;

  constructor(message: string, timeoutMs: number, operation?: string) {
    super(message);
    this.timeoutMs = timeoutMs;
    this.operation = operation;
  }
}

export class ZmuxFrameError extends ZmuxError {
  readonly byteLength?: number;

  constructor(message: string, byteLength?: number) {
    super(message);
    this.byteLength = byteLength;
  }
}
