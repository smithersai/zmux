import type { ZmuxErrorCode, ZmuxErrorKind } from "./errors.ts";

export type JsonRpcId = string | number | null;

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id?: JsonRpcId;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcErrorObject {
  code: ZmuxErrorCode | number;
  message: string;
  data?: {
    kind?: ZmuxErrorKind | string;
    [key: string]: unknown;
  };
}

export interface JsonRpcSuccessResponse<T = unknown> {
  jsonrpc: "2.0";
  id: JsonRpcId;
  result: T;
}

export interface JsonRpcErrorResponse {
  jsonrpc: "2.0";
  id: JsonRpcId;
  error: JsonRpcErrorObject;
}

export type JsonRpcResponse<T = unknown> =
  | JsonRpcSuccessResponse<T>
  | JsonRpcErrorResponse;

export interface OkResult {
  ok: true;
}

export type SessionState = "creating" | "running" | "terminated";
export type Axis = "horizontal" | "vertical";
export type AxisInput = "horizontal" | "vertical" | "h" | "v" | "-h" | "-v";
export type ResizePolicy = "latest" | "smallest" | "largest" | "none";
export type ReplayMode = "raw" | "ansi_restore" | "none";
export type PromptState = "unknown" | "prompt" | "input" | "running";
export type AgentStatus = "unknown" | "idle" | "working" | "waiting_for_input" | "done";
export type MouseMode = "none" | "x10" | "button" | "any";
export type DetachReason = "pane_removed" | "session_removed" | "remote_detach";

export interface PingResult {
  version: string;
  pid: number;
  socketPath: string;
  sessions: number;
  panes: number;
  livePanes: number;
  connections: number;
  droppedEvents: number;
  rejectedConnections: number;
}

export interface CreatePaneOptions {
  title?: string;
  name?: string;
  id?: string;
  shell?: string;
  command?: string;
  cwd?: string;
  workingDirectory?: string;
  env?: Record<string, string>;
  environment?: Record<string, string>;
  clearEnv?: boolean;
  rows?: number;
  cols?: number;
  scrollbackBytes?: number;
  /** Additive v0.5.0 pane metadata map. */
  metadata?: Record<string, string>;
}

export type SessionCreateParams = CreatePaneOptions;

export interface SessionInfo {
  id: string;
  title: string;
  pid: number;
  state: SessionState;
  cwd: string | null;
  shell: string | null;
  scrollbackBytes: number;
  exitStatus: number | null;
  exitCode: number | null;
  signal: number | null;
  generation: number;
}

export interface SessionCreateResult extends SessionInfo {
  sessionId: string;
  windowId: string;
  paneId: string;
}

export interface SessionListItem extends SessionInfo {
  sessionId: string;
  sessionName: string;
  windowId: string;
  paneId: string;
  paneTitle: string;
}

export interface PaneHandle {
  sessionId: string;
  windowId: string;
  paneId: string;
  generation: number;
}

export interface SessionTargetParams {
  sessionId?: string;
  id?: string;
}

export interface PaneTargetParams {
  paneId?: string;
  targetPaneId?: string;
  target?: string;
  sessionId?: string;
  id?: string;
}

export interface WindowTargetParams {
  windowId?: string;
  targetWindowId?: string;
  target?: string;
  id?: string;
}

export interface ClientTargetParams {
  clientId?: string;
  targetClientId?: string;
  id?: string;
}

export interface SessionResizeParams extends SessionTargetParams {
  rows?: number;
  cols?: number;
}

export interface SessionCaptureParams extends SessionTargetParams {
  lines?: number;
}

export interface CaptureResult {
  sessionId: string;
  text: string;
  textBase64: string;
}

export interface SessionSendParams extends SessionTargetParams {
  text?: string;
  enter?: boolean;
  dataBase64?: string;
  data_base64?: string;
}

export interface SessionSendKeyParams extends SessionTargetParams {
  key: string;
}

export interface SessionRenameParams extends SessionTargetParams {
  name?: string;
  title?: string;
}

export interface WindowNewParams extends SessionTargetParams, Omit<CreatePaneOptions, "id"> {}

export type WindowSelectParams = WindowTargetParams;

export interface WindowRenameParams extends WindowTargetParams {
  name?: string;
  title?: string;
}

export interface PaneSplitParams extends PaneTargetParams, Omit<CreatePaneOptions, "id"> {
  axis?: AxisInput;
  horizontal?: boolean;
}

export type PaneSelectParams = PaneTargetParams;

export interface PaneRenameParams extends PaneTargetParams {
  title?: string;
  name?: string;
  custom?: boolean;
}

export interface PaneRespawnParams extends PaneTargetParams {
  kill?: boolean;
}

export interface ClientAttachParams extends PaneTargetParams {
  rows?: number;
  cols?: number;
  createIfMissing?: SessionCreateParams;
  /** Additive v0.5.0 offset resumption. */
  resumeFromOffset?: number;
  /** Additive v0.5.0 generation for offset resumption. */
  resumeGeneration?: number;
  /** Additive v0.5.0 read-only attachment flag. */
  readOnly?: boolean;
  /** Additive v0.5.0 resize policy. */
  resizePolicy?: ResizePolicy;
  /** Additive v0.5.0 replay mode. */
  replayMode?: ReplayMode;
}

export interface AttachResult {
  clientId: string;
  sessionId: string;
  windowId: string;
  paneId: string;
  rows: number;
  cols: number;
  created: boolean;
  exited: boolean;
  exitCode: number | null;
  signal: number | null;
  generation: number;
  replayBase64: string;
  replayStartOffset: number;
  replayEndOffset: number;
  replayMode?: ReplayMode;
  readOnly?: boolean;
  resumed?: boolean;
}

export type ClientDetachParams = ClientTargetParams;

export interface ClientSwitchParams extends ClientTargetParams {
  paneId?: string;
  targetPaneId?: string;
  target?: string;
  sessionId?: string;
}

export interface AlertState {
  activity: boolean;
  bell: boolean;
  exited: boolean;
  lastActivityMs: number;
  lastBellMs: number;
}

export interface LayoutLeaf {
  kind: "leaf";
  paneId: string;
}

export interface LayoutSplit {
  kind: "split";
  id: string;
  axis: Axis;
  ratio?: number;
  first: LayoutNode;
  second: LayoutNode;
}

export type LayoutNode = LayoutLeaf | LayoutSplit;

export interface SnapshotPane {
  id: string;
  windowId: string;
  sessionId: string;
  index: number;
  title: string;
  hasCustomTitle: boolean;
  state: SessionState;
  generation: number;
  pid: number;
  rows: number;
  cols: number;
  cwd: string | null;
  command: string;
  alerts: AlertState;
  metadata?: Record<string, string>;
}

export interface SnapshotWindow {
  id: string;
  sessionId: string;
  index: number;
  name: string;
  activePaneId: string;
  layout: LayoutNode;
  panes: SnapshotPane[];
  zoomedPaneId?: string | null;
}

export interface SnapshotSession {
  id: string;
  name: string;
  activeWindowId: string;
  windows: SnapshotWindow[];
}

export interface ClientInfo {
  id: string;
  sessionId: string;
  windowId: string;
  paneId: string;
  rows: number;
  cols: number;
  active: boolean;
  readOnly?: boolean;
  resizePolicy?: ResizePolicy;
}

export interface KeyBinding {
  table: string;
  key: string;
  command: string;
  repeat: boolean;
}

export interface MuxSnapshot {
  sessions: SnapshotSession[];
  clients: ClientInfo[];
  keyBindings: KeyBinding[];
}

export interface SubscribeEventsParams {
  panes: string[];
}

export interface SubscribeEventsResult {
  ok: true;
  all: boolean;
  panes: string[];
}

export interface KeyBindParams {
  key: string;
  command?: string;
  cmd?: string;
  table?: string;
  repeat?: boolean;
}

export interface KeyDispatchParams extends PaneTargetParams {
  key: string;
  table?: string;
}

export type KeyDispatchResult = MuxSnapshot | { handled: false };

export interface CommandExecParams extends PaneTargetParams {
  command?: string;
  line?: string;
}

// ---------------------------------------------------------------------------
// Additive v0.5.0 / v0.6.0 RPC types

export interface SessionScreenParams extends PaneTargetParams {
  includeScrollback?: number;
  includeCells?: boolean;
  includeAnsiRestore?: boolean;
}

export type TerminalColor =
  | null
  | { kind: "indexed"; index: number }
  | { kind: "rgb"; r: number; g: number; b: number };

export interface TerminalCell {
  char: string;
  width: number;
  fg?: TerminalColor;
  bg?: TerminalColor;
  bold?: boolean;
  dim?: boolean;
  italic?: boolean;
  underline?: boolean;
  blink?: boolean;
  inverse?: boolean;
  hidden?: boolean;
  strikethrough?: boolean;
}

export interface TerminalCursor {
  row: number;
  col: number;
  visible: boolean;
}

export interface TerminalModes {
  decckm: boolean;
  origin: boolean;
  autowrap: boolean;
  cursorVisible: boolean;
  altScreen: boolean;
  mouseMode: MouseMode;
  mouseSgr: boolean;
  focusEvents: boolean;
  bracketedPaste: boolean;
  syncOutput: boolean;
  insertMode: boolean;
  linefeedMode: boolean;
  kittyKeyboardFlags?: number;
}

export interface ScreenSnapshot {
  rows: number;
  cols: number;
  cursor: TerminalCursor;
  altScreen: boolean;
  title: string;
  cwd: string | null;
  promptState: PromptState;
  lastCommandExitCode: number | null;
  commandSeq: number;
  agentStatus: AgentStatus;
  modes: TerminalModes;
  text: string;
  lines: string[];
  cells?: TerminalCell[][];
  ansiRestore?: string;
}

export interface PaneWaitParams extends PaneTargetParams {
  pattern?: string;
  regex?: boolean;
  exit?: boolean;
  idleMs?: number;
  promptState?: PromptState;
  agentStatus?: AgentStatus;
  timeoutMs?: number;
}

export interface PaneWaitResult {
  matched: boolean;
  reason: "pattern" | "exit" | "idle" | "prompt" | "status" | "timeout";
  matchText?: string | null;
  exitCode?: number | null;
  signal?: number | null;
  generation: number;
  offset: number;
  screenText?: string;
}

export interface PaneExecParams extends PaneTargetParams {
  command: string;
  timeoutMs?: number;
  captureOutput?: boolean;
}

export interface PaneExecResult {
  paneId: string;
  exitCode: number | null;
  signal: number | null;
  output: string;
  outputBase64: string;
  timedOut: boolean;
  durationMs: number;
}

export interface PaneSignalParams extends PaneTargetParams {
  signal: string | number;
  group?: boolean;
}

export interface PaneSignalResult {
  ok: true;
  paneId: string;
  signal: string;
}

export interface PaneCloseParams extends PaneTargetParams {
  force?: boolean;
}

export interface WindowCloseParams extends WindowTargetParams {
  force?: boolean;
}

export interface PaneResizeSplitParams extends PaneTargetParams {
  splitId?: string;
  ratio?: number;
  delta?: number;
}

export interface PaneZoomParams extends PaneTargetParams {
  zoomed?: boolean;
}

export interface PaneMetadataParams extends PaneTargetParams {
  set?: Record<string, string>;
  remove?: string[];
  replace?: boolean;
}

export interface PaneMetadataResult {
  paneId: string;
  metadata: Record<string, string>;
}

export interface PaneRecordParams extends PaneTargetParams {
  action: "start" | "stop" | "status";
  path?: string;
  format?: "asciicast-v2";
  maxBytes?: number;
}

export interface PaneRecordResult {
  paneId: string;
  recording: boolean;
  path: string | null;
  format: "asciicast-v2";
  bytesWritten: number;
  startedAtMs: number | null;
}

export interface ClientSetModeParams extends ClientTargetParams {
  readOnly?: boolean;
  resizePolicy?: ResizePolicy;
}

// ---------------------------------------------------------------------------
// Server-to-client notifications

export interface PaneOutputParams {
  pane_id: string;
  data_base64: string;
  offset: number;
  generation: number;
}

export interface PaneOutputDroppedParams {
  pane_id: string;
  dropped_bytes: number;
  resume_offset: number;
  generation: number;
}

export interface PaneActivityParams {
  pane_id: string;
  last_activity_ms: number;
  generation: number;
}

export interface PaneBellParams {
  pane_id: string;
  last_bell_ms: number;
  generation: number;
}

export interface SessionExitedParams {
  session_id: string;
  pid: number;
  exit_code: number | null;
  signal: number | null;
  generation: number;
}

export interface ForegroundChangedParams {
  session_id: string;
  pid: number;
  comm: string;
  argv: string[];
  argv_truncated: boolean;
}

export interface PaneRespawnedParams {
  pane_id: string;
  generation: number;
  pid: number;
}

export interface ClientDetachedParams {
  client_id: string;
  reason: DetachReason;
}

export interface ClientSwitchedParams {
  client_id: string;
  pane_id: string;
  generation: number;
  replayBase64: string;
  replayStartOffset: number;
  replayEndOffset: number;
  /** Optional snake-case fallbacks for forward/backward compatibility. */
  replay_base64?: string;
  replay_start_offset?: number;
  replay_end_offset?: number;
}

export interface PaneTitleChangedParams {
  pane_id: string;
  title: string;
  generation: number;
}

export interface PaneCwdChangedParams {
  pane_id: string;
  cwd: string;
  generation: number;
}

export interface PanePromptChangedParams {
  pane_id: string;
  prompt_state: PromptState;
  last_exit_code: number | null;
  command_seq: number;
  generation: number;
}

export interface PaneStatusChangedParams {
  pane_id: string;
  status: AgentStatus;
  message: string | null;
  generation: number;
}

export interface ZmuxNotificationMap {
  pane_output: PaneOutputParams;
  pane_output_dropped: PaneOutputDroppedParams;
  pane_activity: PaneActivityParams;
  pane_bell: PaneBellParams;
  session_exited: SessionExitedParams;
  foreground_changed: ForegroundChangedParams;
  pane_respawned: PaneRespawnedParams;
  client_detached: ClientDetachedParams;
  client_switched: ClientSwitchedParams;
  pane_title_changed: PaneTitleChangedParams;
  pane_cwd_changed: PaneCwdChangedParams;
  pane_prompt_changed: PanePromptChangedParams;
  pane_status_changed: PaneStatusChangedParams;
}

export type ZmuxNotificationMethod = keyof ZmuxNotificationMap;

export type ZmuxNotification = {
  [K in ZmuxNotificationMethod]: {
    method: K;
    params: ZmuxNotificationMap[K];
  };
}[ZmuxNotificationMethod];
