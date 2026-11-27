import { ZmuxError } from "./errors.ts";

export type SocketPathErrorCode =
  | "EmptySocketPath"
  | "SocketPathContainsNul"
  | "SocketPathTooLong"
  | "NoSocketDirectory"
  | "CurrentDirUnavailable";

export class SocketPathError extends ZmuxError {
  readonly code: SocketPathErrorCode;
  readonly path?: string;

  constructor(code: SocketPathErrorCode, message: string, socketPath?: string) {
    super(message);
    this.code = code;
    this.path = socketPath;
  }
}

export interface SocketPathOptions {
  env?: Record<string, string | undefined>;
  cwd?: string;
  uid?: number;
  platform?: NodeJS.Platform;
  maxPathLen?: number;
}

const textEncoder = new TextEncoder();

/**
 * Longest UNIX socket path accepted by bind/connect (`sun_path` minus NUL).
 * 103 bytes on Darwin/macOS, 107 bytes on Linux.
 */
export function maxUnixPathLen(platform: NodeJS.Platform = process.platform): number {
  return platform === "darwin" ? 103 : 107;
}

function utf8ByteLength(value: string): number {
  return textEncoder.encode(value).byteLength;
}

function nonEmpty(value: string | undefined): string | null {
  return value !== undefined && value.length > 0 ? value : null;
}

function trimTrailingSlashes(p: string): string {
  let end = p.length;
  while (end > 1 && p.charCodeAt(end - 1) === 47) end -= 1;
  return p.slice(0, end);
}

function joinSegment(dir: string, ...segments: string[]): string {
  let acc = trimTrailingSlashes(dir);
  for (const seg of segments) {
    const clean = seg.replace(/^\/+/, "");
    if (acc === "/") acc = `/${clean}`;
    else acc = `${acc}/${clean}`;
  }
  return acc;
}

function getEffectiveUid(options?: SocketPathOptions): number {
  if (options?.uid !== undefined) return options.uid;
  if (typeof process.geteuid === "function") return process.geteuid();
  if (typeof process.getuid === "function") return process.getuid();
  return 0;
}

function resolveRaw(override: string | null | undefined, options?: SocketPathOptions): string {
  const env = options?.env ?? process.env;
  if (override !== undefined && override !== null) {
    if (override.length === 0) {
      throw new SocketPathError("EmptySocketPath", "socket path override must not be empty");
    }
    return override;
  }
  const zmuxSocket = nonEmpty(env.ZMUX_SOCKET);
  if (zmuxSocket !== null) return zmuxSocket;

  const smithersSocket = nonEmpty(env.SMITHERS_SESSION_SOCKET);
  if (smithersSocket !== null) return smithersSocket;

  const xdgRuntimeDir = nonEmpty(env.XDG_RUNTIME_DIR);
  if (xdgRuntimeDir !== null) {
    return joinSegment(xdgRuntimeDir, "smithers-sessions.sock");
  }

  const home = nonEmpty(env.HOME);
  if (home !== null) {
    return joinSegment(home, ".smithers", "sessions.sock");
  }

  return `/tmp/zmux-${getEffectiveUid(options)}/sessions.sock`;
}

/**
 * Exact parity with `src/socket_path.zig:absolutize`.
 * Keeps absolute paths verbatim, drops leading `./` segments on relative paths,
 * preserves `..` and inner `./` segments for kernel resolution.
 */
export function absolutizeSocketPath(rawPath: string, cwd?: string): string {
  if (rawPath.length === 0) {
    throw new SocketPathError("EmptySocketPath", "socket path must not be empty");
  }
  if (rawPath.includes("\0")) {
    throw new SocketPathError("SocketPathContainsNul", "socket path must not contain NUL bytes", rawPath);
  }
  if (rawPath.startsWith("/")) {
    return rawPath;
  }

  let relative = rawPath;
  while (relative.startsWith("./")) {
    relative = relative.slice(2);
    while (relative.startsWith("/")) relative = relative.slice(1);
  }
  if (relative.length === 0 || relative === ".") {
    throw new SocketPathError(
      "EmptySocketPath",
      "socket path must name a socket file, not the current directory",
      rawPath,
    );
  }

  let resolvedCwd: string;
  try {
    resolvedCwd = cwd ?? process.cwd();
  } catch {
    throw new SocketPathError("CurrentDirUnavailable", "current working directory is unavailable");
  }
  if (resolvedCwd.length === 0 || !resolvedCwd.startsWith("/")) {
    throw new SocketPathError("CurrentDirUnavailable", "current working directory is not absolute");
  }
  return joinSegment(resolvedCwd, relative);
}

/**
 * Exact parity with `src/socket_path.zig:validate`.
 * Checks empty -> NUL -> absolute -> no trailing slash -> sun_path byte length.
 */
export function validateSocketPath(socketPath: string, maxPathLen?: number): void {
  if (socketPath.length === 0) {
    throw new SocketPathError("EmptySocketPath", "socket path must not be empty");
  }
  if (socketPath.includes("\0")) {
    throw new SocketPathError("SocketPathContainsNul", "socket path must not contain NUL bytes", socketPath);
  }
  if (!socketPath.startsWith("/") || socketPath.endsWith("/")) {
    throw new SocketPathError("NoSocketDirectory", "socket path must be an absolute file path", socketPath);
  }
  const limit = maxPathLen ?? maxUnixPathLen();
  const byteLen = utf8ByteLength(socketPath);
  if (byteLen > limit) {
    throw new SocketPathError(
      "SocketPathTooLong",
      `socket path exceeds sun_path limit (${byteLen} > ${limit} bytes): ${socketPath}`,
      socketPath,
    );
  }
}

/**
 * Resolve without validating sun_path length so callers can report the full offending path.
 */
export function resolveSocketPathUnvalidated(
  override?: string | null,
  options?: SocketPathOptions,
): string {
  const raw = resolveRaw(override, options);
  return absolutizeSocketPath(raw, options?.cwd);
}

/**
 * Resolve and validate the zmux daemon UNIX socket path.
 * Precedence: override > ZMUX_SOCKET > SMITHERS_SESSION_SOCKET >
 * XDG_RUNTIME_DIR/smithers-sessions.sock > HOME/.smithers/sessions.sock >
 * /tmp/zmux-<uid>/sessions.sock.
 */
export function resolveSocketPath(
  override?: string | null,
  options?: SocketPathOptions,
): string {
  const resolved = resolveSocketPathUnvalidated(override, options);
  const limit = options?.maxPathLen ?? maxUnixPathLen(options?.platform);
  validateSocketPath(resolved, limit);
  return resolved;
}

/**
 * True when the socket parent directory is daemon-managed (`$HOME/.smithers` or `/tmp/zmux-<uid>`).
 */
export function isDefaultManagedSocketPath(
  socketPath: string,
  options?: SocketPathOptions,
): boolean {
  if (!socketPath.startsWith("/")) return false;
  const lastSlash = socketPath.lastIndexOf("/");
  if (lastSlash <= 0) return false;
  const parent = trimTrailingSlashes(socketPath.slice(0, lastSlash));
  if (parent.length === 0) return false;

  const env = options?.env ?? process.env;
  const home = nonEmpty(env.HOME);
  if (home !== null) {
    const managed = `${trimTrailingSlashes(home)}/.smithers`;
    if (parent === managed) return true;
  }

  const fallback = `/tmp/zmux-${getEffectiveUid(options)}`;
  return parent === fallback;
}
