export {
  AttachedPane,
  PaneStreamReconciler,
  type AttachedPaneEventMap,
  type AttachedPaneEventName,
  type DroppedOutputEvent,
  type PaneDetachedEvent,
  type PaneExitedEvent,
  type PaneRespawnedEvent,
  type PaneSwitchedEvent,
  type ReconnectOptions,
  type WaitForOptions,
  type WaitForResult,
  type ZmuxPaneTransport,
} from "./attached-pane.ts";

export {
  ZmuxClient,
  type RpcCallOptions,
  type ZmuxClientOptions,
} from "./client.ts";

export {
  ZMUX_ERROR_CODES,
  ZMUX_ERROR_KINDS,
  ZmuxConnectionError,
  ZmuxError,
  ZmuxFrameError,
  ZmuxRpcError,
  ZmuxTimeoutError,
  inferErrorKind,
  isZmuxErrorKind,
  type ZmuxErrorCode,
  type ZmuxErrorKind,
} from "./errors.ts";

export {
  DEFAULT_MAX_FRAME_BYTES,
  NdjsonFrameParser,
  decodeBase64,
  encodeBase64,
} from "./framing.ts";

export {
  SocketPathError,
  absolutizeSocketPath,
  isDefaultManagedSocketPath,
  maxUnixPathLen,
  resolveSocketPath,
  resolveSocketPathUnvalidated,
  validateSocketPath,
  type SocketPathErrorCode,
  type SocketPathOptions,
} from "./socket-path.ts";

export type * from "./types.ts";
