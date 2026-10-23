export enum AppScreen {
  Connect = 0,
  Sessions = 1,
  Chat = 2
}

export enum ConnState {
  Idle = 0,
  Connecting = 1,
  Online = 2,
  Error = 3
}

export interface SessionSummary {
  sessionId: string;
  cwd: string;
  title: string;
}

export interface AiChoice {
  value: string;
  name: string;
  description: string;
  group: string;
}

export interface AiConfigOption {
  id: string;
  name: string;
  category: string;
  currentValue: string;
  choices: AiChoice[];
}

export interface ChatMessage {
  id: string;
  role: string;
  text: string;
  reasoning: string;
  toolName: string;
  toolArgs: string;
  toolText: string;
  callId: string;
  status: string;
  at: number;
  expanded: boolean;
  streaming: boolean;
  usage: string;
  rev: number;
}

export interface HistoryMessage {
  role: string;
  text?: string;
  reasoning?: string;
  toolName?: string;
  args?: string;
  callId?: string;
  status?: string;
  at?: number;
  usage?: UsageInfo;
}

export interface UsageInfo {
  inputTokens?: number;
  outputTokens?: number;
  totalTokens?: number;
}

export interface HistoryResult {
  sessionId: string;
  title: string;
  cwd: string;
  messages: HistoryMessage[];
  note: string;
  before?: number;
  hasMore?: boolean;
  total?: number;
}

export interface PermissionOption {
  optionId: string;
  name: string;
  kind: string;
}

export interface PermissionView {
  rpcId: number;
  title: string;
  options: PermissionOption[];
  sessionId: string;
}

export interface AcpContent {
  type: string;
  text?: string;
  content?: AcpContent;
}

export interface AcpUpdate {
  sessionUpdate: string;
  messageId?: string;
  content?: AcpContent | AcpContent[];
  toolCallId?: string;
  title?: string;
  kind?: string;
  status?: string;
  rawInput?: object;
  used?: number;
  size?: number;
}

export interface AcpUpdateParams {
  sessionId: string;
  update: AcpUpdate;
}

export interface PermissionParams {
  sessionId: string;
  toolCall?: object;
  options?: PermissionOption[];
}

export interface RawConfigChoice {
  value?: string;
  name?: string;
  description?: string;
  group?: string;
  options?: RawConfigChoice[];
}

export interface RawConfigOption {
  id: string;
  name: string;
  category: string;
  currentValue: string;
  options?: RawConfigChoice[];
}

export interface RawSession {
  sessionId: string;
  cwd: string;
  title?: string;
}

export interface SessionListResult {
  sessions: RawSession[];
}

export interface SessionTitle {
  sessionId: string;
  title: string;
}

export interface TitlesResult {
  titles: SessionTitle[];
}

export interface PhoneInfo {
  cwd: string;
  home: string;
  platform: string;
  bridgeVersion: string;
}

export interface PhoneHello {
  version: string;
  cwd: string;
}

export interface SessionNewResult {
  sessionId: string;
  configOptions: RawConfigOption[];
}

export interface SessionResumeResult {
  configOptions: RawConfigOption[];
}

export interface PromptResult {
  stopReason: string;
}

export interface FsCapabilities {
  readTextFile: boolean;
  writeTextFile: boolean;
}

export interface ClientCapabilities {
  fs: FsCapabilities;
  terminal: boolean;
}

export interface InitializeParams {
  protocolVersion: number;
  clientCapabilities: ClientCapabilities;
}

export interface PromptContent {
  type: string;
  text: string;
}

export interface PromptParams {
  sessionId: string;
  prompt: PromptContent[];
}

export interface RpcError {
  code: number;
  message: string;
}

export interface RpcEnvelope {
  jsonrpc: string;
  id?: number;
  method?: string;
  params?: object;
  result?: object;
  error?: RpcError;
}

export interface ServerTarget {
  wsUrl: string;
  host: string;
  port: number;
  hostLabel: string;
  token: string;
}

export interface WorkspaceInfo {
  id: string;
  title: string;
  path: string;
  sessionIds: string[];
}

export interface WorkspacesResult {
  workspaces: WorkspaceInfo[];
  archived: string[];
  pinned: string[];
  defaultWorkspaceId: string;
  note: string;
}

export interface SessionRow {
  kind: string;
  key: string;
  title: string;
  path: string;
  workspaceId: string;
  count: number;
  collapsed: boolean;
  session: SessionSummary;
}

export interface ArchivedResult {
  archived: string[];
  sessionId?: string;
  hidden?: boolean;
}
