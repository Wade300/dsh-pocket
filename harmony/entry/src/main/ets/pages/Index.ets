import { MdBlock, MdItem, MdRow, MdSpan, parseMarkdown, plainInline } from '../common/Markdown';
import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import {
  AcpUpdateParams, AiChoice, AiConfigOption, AppScreen, ArchivedResult, ChatMessage, ClientCapabilities, ConnState, FsCapabilities, HistoryResult, InitializeParams, PromptContent, PromptParams,
  PermissionOption, PermissionParams, PermissionView, PhoneHello, PhoneInfo, PromptResult,
  RawConfigOption, RawSession, SessionListResult, SessionNewResult, SessionResumeResult, SessionRow, SessionSummary, SessionTitle, ServerTarget, TitlesResult, WorkspaceInfo, WorkspacesResult
} from '../common/Models';
import { parseServer, serverIssue } from '../common/ServerUrl';
import { Store, NativeSettings, LastSession } from '../common/Store';
import { AcpClient } from '../common/AcpClient';
import {
  clampText, contentText, copyMessage, currentModelName, findPreferredModel, fromHistory,
  newMessage, parseConfigOptions, shortCwd, shortSessionId, timeLabel, usageLabel
} from '../common/ChatTools';

const BG: string = '#F4EFE4';
const PANEL: string = '#FFFDF6';
const INK: string = '#17191D';
const MUTED: string = '#6D6A61';
const SOFT: string = '#9B9587';
const LINE: string = '#D8D0BF';
const ACCENT: string = '#C2410C';
const OK: string = '#2F6B4F';
const DANGER: string = '#B42318';
const TRANSPARENT: string = '#00000000';
const CODE_BG: string = '#1C1E22';
const CODE_FG: string = '#EDE8DE';
const USER_FG: string = '#FFF8EF';
const USER_MUTED: string = '#FFE3D0';
const USER_LINK: string = '#FFE0B2';
const USER_LINE: string = '#E06A35';
const USER_CODE_BG: string = '#7C2D12';
const USER_HEADER_BG: string = '#A8380A';

interface CachedChat {
  session: LastSession;
  messages: ChatMessage[];
}

@Entry
@Component
struct Index {
  @State screen: AppScreen = AppScreen.Connect;
  @State conn: ConnState = ConnState.Idle;
  @State status: string = '还没有连接';
  @State serverInput: string = '';
  @State servers: string[] = [];
  @State sessions: SessionSummary[] = [];
  @State activeSessionId: string = '';
  @State activeTitle: string = '';
  @State activeCwd: string = '';
  @State messages: ChatMessage[] = [];
  @State input: string = '';
  @State streaming: boolean = false;
  @State busy: boolean = false;
  @State configs: AiConfigOption[] = [];
  @State modelName: string = '模型';
  @State showModels: boolean = false;
  @State showNewSession: boolean = false;
  @State showSettings: boolean = false;
  @State showMore: boolean = false;
  @State sheetOpen: boolean = false;
  @State sheetKind: string = 'more';
  @State sheetHeight: number = 480;
  @State historyNote: string = '';
  @State expanded: boolean = false;
  @State viewWidth: number = 0;
  @State viewHeight: number = 0;
  @State defaultCwd: string = '';
  @State sessionQuery: string = '';
  @State sessionReady: boolean = false;
  @State lastSession: LastSession | null = null;
  @State workspaces: WorkspaceInfo[] = [];
  @State archivedIds: string[] = [];
  @State pinnedIds: string[] = [];
  @State showArchived: boolean = false;
  @State collapsedWorkspaces: string[] = [];
  @State sessionRowsState: SessionRow[] = [];
  private restorePending: boolean = false;
  private cachedRestored: boolean = false;
  @State historyHasMore: boolean = false;
  @State historyLoading: boolean = false;
  @State historyReady: boolean = false;
  @State historyBefore: number = 0;
  private firstVisibleIndex: number = 0;
  @State newCwd: string = '';
  @State autoConnect: boolean = true;
  @State bridgeVersion: string = '';
  @State permissionVisible: boolean = false;
  @State permissionTitle: string = '';
  @State permissionOptions: PermissionOption[] = [];
  @State permissionRpcId: number = 0;
  @State permissionSessionId: string = '';

  private client: AcpClient | null = null;
  private mainWindow: window.Window | null = null;
  private scroller: Scroller = new Scroller();
  private currentAssistantId: string = '';
  private toolByCallId: Map<string, string> = new Map();
  private autoModelDone: boolean = false;

  aboutToAppear(): void {
    this.observeWindow();
    this.boot();
  }

  aboutToDisappear(): void {
    this.saveCachedChat();
    if (this.mainWindow !== null) {
      this.mainWindow.off('windowSizeChange');
      this.mainWindow = null;
    }
    if (this.client !== null) {
      this.client.close();
      this.client = null;
    }
  }

  onBackPress(): boolean {
    if (this.permissionVisible) {
      this.respondPermission('');
      return true;
    }
    if (this.screen === AppScreen.Chat) {
      this.screen = AppScreen.Sessions;
      return true;
    }
    if (this.screen === AppScreen.Sessions) {
      this.screen = AppScreen.Connect;
      return true;
    }
    return false;
  }

  // ------------------------------------------------------------ 启动 / 窗口

  private boot(): void {
    this.doBoot();
  }

  private async doBoot(): Promise<void> {
    try {
      await Store.open(this.getUIContext().getHostContext() as common.UIAbilityContext);
      const settings: NativeSettings = await Store.settings();
      this.autoConnect = settings.autoConnect;
      this.servers = await Store.servers();
      this.lastSession = await Store.lastSession();
      const cachedRaw: string = await Store.lastChat();
      if (cachedRaw.length > 0) {
        try {
          const cached: CachedChat = JSON.parse(cachedRaw) as CachedChat;
          if (cached.session !== undefined && cached.session.sessionId.length > 0 && Array.isArray(cached.messages)) {
            this.lastSession = cached.session;
            this.activeSessionId = cached.session.sessionId;
            this.activeTitle = cached.session.title;
            this.activeCwd = cached.session.cwd;
            this.messages = cached.messages;
            this.screen = AppScreen.Chat;
            this.status = '恢复上次窗口';
            this.historyNote = '上次窗口已恢复；连上电脑后可继续发。';
            this.sessionReady = false;
            this.historyHasMore = false;
            this.cachedRestored = true;
            setTimeout(() => this.scrollToBottom(), 350);
          }
        } catch (e) {
          // 缓存坏了就正常启动
        }
      }
      const last: string = await Store.lastServer();
      if (last.length > 0) {
        this.serverInput = last;
        if (this.autoConnect) {
          this.restorePending = !this.cachedRestored;
          this.connectTo(last);
        }
      }
    } catch (e) {
      this.conn = ConnState.Error;
      this.status = '本地存储打不开';
    }
  }

  private observeWindow(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(context).then((win: window.Window) => {
        this.mainWindow = win;
        const rect: window.Rect = win.getWindowProperties().windowRect;
        this.viewWidth = this.getUIContext().px2vp(rect.width);
        this.viewHeight = this.getUIContext().px2vp(rect.height);
        this.expanded = this.viewWidth >= 840;
        win.on('windowSizeChange', (size: window.Size) => {
          this.viewWidth = this.getUIContext().px2vp(size.width);
          this.viewHeight = this.getUIContext().px2vp(size.height);
          this.expanded = this.viewWidth >= 840;
        });
      }).catch((error: BusinessError) => {
        console.warn(`observe window failed: ${error.code}`);
      });
    } catch (e) {
      console.warn('observe window unavailable');
    }
  }

  // ------------------------------------------------------------ 连接

  private connectFromInput(): void {
    const target: ServerTarget | null = parseServer(this.serverInput);
    if (target === null) {
      this.toast('地址格式不对，示例：ws://192.168.1.10:3090/ws?token=…');
      return;
    }
    const issue: string = serverIssue(target);
    if (issue.length > 0) {
      this.conn = ConnState.Error;
      this.status = issue;
      this.toast(issue);
      return;
    }
    this.connectTo(target.wsUrl);
  }

  private connectTo(url: string): void {
    if (this.client !== null) {
      this.client.close();
      this.client = null;
    }
    this.conn = ConnState.Connecting;
    this.status = '正在连接电脑…';
    this.serverInput = url;

    const client: AcpClient = new AcpClient();
    this.client = client;
    client.onHello = (json: string): void => {
      console.info('[acp] hello');
      try {
        const hello: PhoneHello = JSON.parse(json) as PhoneHello;
        if (hello.cwd.length > 0) {
          this.defaultCwd = hello.cwd;
        }
      } catch (e) {
        // 忽略
      }
    };
    client.onUpdate = (json: string): void => this.handleUpdate(json);
    client.onPermission = (json: string, id: number): void => this.handlePermission(json, id);
    client.onClosed = (reason: string): void => {
      console.info(`[acp] closed ${reason}`);
      if (this.conn === ConnState.Online) {
        this.conn = ConnState.Error;
        this.status = reason;
        this.sessionReady = false;
        this.toast(reason);
      }
    };

    client.connect(url).then(() => {
      this.conn = ConnState.Online;
      this.sessionReady = false;
      this.status = '已连接，正在加载会话…';
      this.rememberServer(url);
      this.initialize();
    }).catch((error: Error) => {
      this.conn = ConnState.Error;
      this.status = `连不上：${error.message}`;
    });
  }

  private async rememberServer(url: string): Promise<void> {
    try {
      await Store.rememberServer(url);
      this.servers = await Store.servers();
    } catch (e) {
      // 忽略
    }
  }

  private initialize(): void {
    const client: AcpClient | null = this.client;
    if (client === null) {
      return;
    }
    const fs: FsCapabilities = { readTextFile: false, writeTextFile: false };
    const caps: ClientCapabilities = { fs: fs, terminal: false };
    const init: InitializeParams = { protocolVersion: 1, clientCapabilities: caps };
    const params: string = JSON.stringify(init);
    client.request('initialize', params, 30000, (json: string) => {
      this.loadPhoneInfo();
    }, (message: string) => {
      this.conn = ConnState.Error;
      this.status = `握手失败：${message}`;
    });
  }

  private loadPhoneInfo(): void {
    const client: AcpClient | null = this.client;
    if (client === null) {
      return;
    }
    client.request('phone/info', '{}', 10000, (json: string) => {
      try {
        const info: PhoneInfo = JSON.parse(json) as PhoneInfo;
        this.defaultCwd = info.cwd;
        this.bridgeVersion = info.bridgeVersion;
        if (this.newCwd.length === 0) {
          this.newCwd = info.cwd;
        }
      } catch (e) {
        // 忽略
      }
      this.refreshSessions();
    }, (message: string) => {
      this.refreshSessions();
    });
  }

  private refreshSessions(): void {
    const client: AcpClient | null = this.client;
    if (client === null) {
      return;
    }
    this.busy = true;
    console.info('[acp] sessions request');
    client.request('session/list', '{}', 20000, (json: string) => {
      this.busy = false;
      console.info(`[acp] sessions json len=${json.length}`);
      try {
        const result: SessionListResult = JSON.parse(json) as SessionListResult;
        const old: Map<string, SessionSummary> = new Map();
        for (let i = 0; i < this.sessions.length; i++) {
          old.set(this.sessions[i].sessionId, this.sessions[i]);
        }
        const list: SessionSummary[] = [];
        for (let i = 0; i < result.sessions.length; i++) {
          const raw: RawSession = result.sessions[i];
          const previous: SessionSummary | undefined = old.get(raw.sessionId);
          list.push({
            sessionId: raw.sessionId,
            cwd: raw.cwd,
            title: previous !== undefined ? previous.title : (raw.title !== undefined ? raw.title : '')
          });
        }
        console.info(`[acp] sessions parsed n=${list.length}`);
        this.sessions = list;
        if (this.activeSessionId.length > 0) {
          for (let i = 0; i < list.length; i++) {
            if (list[i].sessionId === this.activeSessionId && list[i].title.length > 0) {
              if (list[i].title !== this.activeTitle) {
                this.activeTitle = list[i].title;
                this.saveCachedChat();
              }
              break;
            }
          }
        }
        const keepChat: boolean = this.cachedRestored && this.activeSessionId.length > 0;
        if (!keepChat) {
          this.screen = AppScreen.Sessions;
        }
        console.info('[acp] screen -> sessions');
        this.status = `已连接 · ${list.length} 个会话`;
        this.loadTitles();
        this.loadWorkspaces();
        this.rebuildRows();
        this.restoreLastSession();
        if (keepChat) {
          this.cachedRestored = false;
          this.resumeSession();
        }
      } catch (e) {
        console.info('[acp] sessions parse fail');
        this.status = '会话列表解析失败';
      }
    }, (message: string) => {
      this.busy = false;
      console.info(`[acp] sessions fail ${message}`);
      this.status = `拉会话失败：${message}`;
    });
  }

  private disconnect(): void {
    if (this.client !== null) {
      this.client.close();
      this.client = null;
    }
    this.conn = ConnState.Idle;
    this.status = '已断开';
    this.screen = AppScreen.Connect;
    this.sessions = [];
    this.messages = [];
    this.activeSessionId = '';
    this.activeTitle = '';
    this.activeCwd = '';
    this.streaming = false;
    this.sessionReady = false;
    this.historyHasMore = false;
    this.historyReady = false;
    this.historyBefore = 0;
    this.sessionRowsState = [];
    this.sheetOpen = false;
  }

  // ------------------------------------------------------------ 会话

  private openSession(session: SessionSummary): void {
    if (this.client === null) {
      return;
    }
    this.activeSessionId = session.sessionId;
    this.activeTitle = session.title;
    this.activeCwd = session.cwd;
    this.rebuildRows();
    this.historyNote = '';
    this.messages = [];
    this.sessionReady = false;
    this.historyHasMore = false;
    this.historyLoading = false;
    this.historyReady = false;
    this.historyBefore = 0;
    this.firstVisibleIndex = 0;
    this.busy = true;
    this.status = '读取历史…';
    Store.saveLastSession({
      sessionId: session.sessionId,
      title: session.title,
      cwd: session.cwd
    }).catch(() => {});
    this.autoModelDone = false;

    this.client.request('phone/history', JSON.stringify({ sessionId: session.sessionId, limit: 10 }), 30000,
      (json: string) => {
        try {
          const history: HistoryResult = JSON.parse(json) as HistoryResult;
          const list: ChatMessage[] = [];
          for (let i = 0; i < history.messages.length; i++) {
            list.push(fromHistory(history.messages[i]));
          }
          this.messages = list;
          this.historyHasMore = history.hasMore === true;
          this.historyBefore = typeof history.before === 'number' ? history.before : 0;
          this.historyReady = false;
          this.scrollToBottom();
          setTimeout(() => { this.historyReady = true; }, 650);
          if (history.title.length > 0) {
            this.activeTitle = history.title;
            this.updateSessionTitle(session.sessionId, history.title);
          }
          if (history.cwd.length > 0) {
            this.activeCwd = history.cwd;
          }
          this.historyNote = history.note;
          this.saveCachedChat();
        } catch (e) {
          this.historyNote = '历史解析失败';
        }
        this.resumeSession();
      },
      (message: string) => {
        this.historyNote = `历史没读到：${message}`;
        this.resumeSession();
      });
  }

  private resumeSession(): void {
    const client: AcpClient | null = this.client;
    if (client === null) {
      return;
    }
    const cwd: string = this.activeCwd.length > 0 ? this.activeCwd : this.defaultCwd;
    const params: string = JSON.stringify({
      sessionId: this.activeSessionId,
      cwd: cwd,
      mcpServers: []
    });
    client.request('session/resume', params, 30000, (json: string) => {
      this.busy = false;
      try {
        const result: SessionResumeResult = JSON.parse(json) as SessionResumeResult;
        this.applyConfigs(result.configOptions, true);
      } catch (e) {
        // 恢复成功但配置没解析出来
      }
      this.screen = AppScreen.Chat;
      this.status = '会话已就绪';
      this.sessionReady = true;
      this.scrollToBottom();
    }, (message: string) => {
      this.busy = false;
      this.historyNote = `会话没能恢复（${message}）。可以先看历史，或新建会话。`;
      this.screen = AppScreen.Chat;
      this.status = '只读历史';
      this.sessionReady = false;
      this.scrollToBottom();
    });
  }

  private createSession(cwd: string): void {
    const client: AcpClient | null = this.client;
    if (client === null) {
      return;
    }
    const useCwd: string = cwd.trim().length > 0 ? cwd.trim() : (this.defaultCwd.length > 0 ? this.defaultCwd : this.activeCwd);
    if (useCwd.length === 0) {
      this.toast('先填工作目录');
      return;
    }
    this.busy = true;
    this.status = '新建会话…';
    client.request('session/new', JSON.stringify({ cwd: useCwd, mcpServers: [] }), 30000,
      (json: string) => {
        this.busy = false;
        try {
          const created: SessionNewResult = JSON.parse(json) as SessionNewResult;
          this.activeSessionId = created.sessionId;
          this.activeTitle = '新会话';
          this.activeCwd = useCwd;
          this.messages = [];
          this.historyNote = '';
          this.historyHasMore = false;
          this.historyBefore = 0;
          this.historyReady = false;
          this.streaming = false;
          this.autoModelDone = false;
          this.applyConfigs(created.configOptions, true);
          this.sessions.unshift({ sessionId: created.sessionId, cwd: useCwd, title: '新会话' });
          this.sessions = this.sessions.slice();
          Store.saveLastSession({
            sessionId: created.sessionId,
            title: '新会话',
            cwd: useCwd
          }).catch(() => {});
          this.screen = AppScreen.Chat;
          this.sheetOpen = false;
          this.status = '新会话已创建';
          this.sessionReady = true;
        } catch (e) {
          this.toast('新会话解析失败');
        }
      },
      (message: string) => {
        this.busy = false;
        this.sessionReady = false;
        this.toast(`新建失败：${message}`);
        this.status = '新建会话失败';
      });
  }

  private visibleSessions(): SessionSummary[] {
    const q: string = this.sessionQuery.trim().toLowerCase();
    const out: SessionSummary[] = [];
    for (let i = 0; i < this.sessions.length; i++) {
      const item: SessionSummary = this.sessions[i];
      if (!this.showArchived && this.isArchived(item.sessionId)) {
        continue;
      }
      if (q.length === 0) {
        out.push(item);
        continue;
      }
      const title: string = item.title.toLowerCase();
      const cwd: string = item.cwd.toLowerCase();
      if (title.indexOf(q) >= 0 || cwd.indexOf(q) >= 0) {
        out.push(item);
      }
    }
    return out;
  }

  private rebuildRows(): void {
    this.sessionRowsState = this.sessionRows();
  }

  private isArchived(sessionId: string): boolean {
    return this.archivedIds.indexOf(sessionId) >= 0;
  }

  private loadWorkspaces(): void {
    const client: AcpClient | null = this.client;
    if (client === null) {
      return;
    }
    client.request('phone/workspaces', '{}', 15000, (json: string) => {
      try {
        const result: WorkspacesResult = JSON.parse(json) as WorkspacesResult;
        this.workspaces = Array.isArray(result.workspaces) ? result.workspaces : [];
        this.archivedIds = Array.isArray(result.archived) ? result.archived : [];
        this.pinnedIds = Array.isArray(result.pinned) ? result.pinned : [];
        const known: string[] = [];
        for (let i = 0; i < this.sessions.length; i++) {
          known.push(this.sessions[i].sessionId);
        }
        const merged: SessionSummary[] = this.sessions.slice();
        let changed: boolean = false;
        for (let i = 0; i < this.workspaces.length; i++) {
          const w: WorkspaceInfo = this.workspaces[i];
          for (let k = 0; k < w.sessionIds.length; k++) {
            const sid: string = w.sessionIds[k];
            if (this.archivedIds.indexOf(sid) >= 0 && known.indexOf(sid) < 0) {
              merged.push({ sessionId: sid, cwd: w.path, title: '' });
              known.push(sid);
              changed = true;
            }
          }
        }
        for (let i = 0; i < this.archivedIds.length; i++) {
          const sid: string = this.archivedIds[i];
          if (known.indexOf(sid) < 0) {
            merged.push({ sessionId: sid, cwd: '', title: '' });
            known.push(sid);
            changed = true;
          }
        }
        if (changed) {
          this.sessions = merged;
          this.loadTitles();
        }
        this.rebuildRows();
      } catch (e) {
        // 旧桥没有这个接口，保持扁平列表
      }
    }, (message: string) => {
      // 忽略，不影响 ACP 会话列表
    });
  }

  private toggleWorkspace(id: string): void {
    const idx: number = this.collapsedWorkspaces.indexOf(id);
    const next: string[] = this.collapsedWorkspaces.slice();
    if (idx >= 0) {
      next.splice(idx, 1);
    } else {
      next.push(id);
    }
    this.collapsedWorkspaces = next;
    this.rebuildRows();
  }

  private toggleArchive(session: SessionSummary): void {
    const client: AcpClient | null = this.client;
    if (client === null) {
      return;
    }
    const archived: boolean = !this.isArchived(session.sessionId);
    client.request('phone/archive', JSON.stringify({
      sessionId: session.sessionId,
      archived: archived
    }), 15000, (json: string) => {
      try {
        const result: ArchivedResult = JSON.parse(json) as ArchivedResult;
        if (Array.isArray(result.archived)) {
          this.archivedIds = result.archived;
        }
      } catch (e) {
        // 忽略
      }
      this.rebuildRows();
      this.toast(archived ? '已隐藏（电脑端同步）' : '已取消隐藏');
    }, (message: string) => {
      this.toast(`同步失败：${message}`);
    });
  }

  private sessionRows(): SessionRow[] {
    const rows: SessionRow[] = [];
    const visible: SessionSummary[] = this.visibleSessions();
    const assigned: string[] = [];
    const emptySession: SessionSummary = { sessionId: '', cwd: '', title: '' };
    for (let i = 0; i < this.workspaces.length; i++) {
      const w: WorkspaceInfo = this.workspaces[i];
      const items: SessionSummary[] = [];
      for (let k = 0; k < visible.length; k++) {
        if (w.sessionIds.indexOf(visible[k].sessionId) >= 0) {
          items.push(visible[k]);
        }
      }
      if (items.length === 0) {
        continue;
      }
      const collapsed: boolean = this.collapsedWorkspaces.indexOf(w.id) >= 0;
      rows.push({
        kind: 'header',
        key: 'w-' + w.id,
        title: w.title.length > 0 ? w.title : shortCwd(w.path),
        path: w.path,
        workspaceId: w.id,
        count: items.length,
        collapsed: collapsed,
        session: emptySession
      });
      if (!collapsed) {
        for (let k = 0; k < items.length; k++) {
          rows.push({
            kind: 'session',
            key: 's-' + items[k].sessionId,
            title: items[k].title,
            path: items[k].cwd,
            workspaceId: w.id,
            count: 1,
            collapsed: false,
            session: items[k]
          });
          assigned.push(items[k].sessionId);
        }
      } else {
        for (let k = 0; k < items.length; k++) {
          assigned.push(items[k].sessionId);
        }
      }
    }
    const rest: SessionSummary[] = [];
    for (let i = 0; i < visible.length; i++) {
      if (assigned.indexOf(visible[i].sessionId) < 0) {
        rest.push(visible[i]);
      }
    }
    if (rest.length > 0 && this.workspaces.length > 0) {
      rows.push({
        kind: 'header',
        key: 'w-ungrouped',
        title: '未分组',
        path: '',
        workspaceId: 'ungrouped',
        count: rest.length,
        collapsed: this.collapsedWorkspaces.indexOf('ungrouped') >= 0,
        session: emptySession
      });
    }
    if (rest.length > 0 && this.collapsedWorkspaces.indexOf('ungrouped') < 0) {
      for (let i = 0; i < rest.length; i++) {
        rows.push({
          kind: 'session',
          key: 's-' + rest[i].sessionId,
          title: rest[i].title,
          path: rest[i].cwd,
          workspaceId: 'ungrouped',
          count: 1,
          collapsed: false,
          session: rest[i]
        });
      }
    }
    return rows;
  }

  private restoreLastSession(): void {
    if (!this.restorePending || this.lastSession === null) {
      return;
    }
    const target: LastSession = this.lastSession;
    this.restorePending = false;
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].sessionId === target.sessionId) {
        this.openSession(this.sessions[i]);
        return;
      }
    }
    const ghost: SessionSummary = {
      sessionId: target.sessionId,
      cwd: target.cwd,
      title: target.title
    };
    this.openSession(ghost);
  }

  private loadTitles(): void {
    const client: AcpClient | null = this.client;
    if (client === null) {
      return;
    }
    const ids: string[] = [];
    if (this.activeSessionId.length > 0) {
      ids.push(this.activeSessionId);
    }
    for (let i = 0; i < this.sessions.length && ids.length < 40; i++) {
      if (this.sessions[i].title.length === 0 && ids.indexOf(this.sessions[i].sessionId) < 0) {
        ids.push(this.sessions[i].sessionId);
      }
    }
    if (ids.length === 0) {
      return;
    }
    client.request('phone/titles', JSON.stringify({ sessionIds: ids }), 30000, (json: string) => {
      try {
        const result: TitlesResult = JSON.parse(json) as TitlesResult;
        const map: Map<string, string> = new Map();
        for (let i = 0; i < result.titles.length; i++) {
          const item: SessionTitle = result.titles[i];
          if (item.title.length > 0) {
            map.set(item.sessionId, item.title);
          }
        }
        if (map.size === 0) {
          return;
        }
        const activeTitle: string | undefined = map.get(this.activeSessionId);
        if (activeTitle !== undefined && activeTitle.length > 0 && activeTitle !== this.activeTitle) {
          this.activeTitle = activeTitle;
          this.saveCachedChat();
        }
        const next: SessionSummary[] = [];
        for (let i = 0; i < this.sessions.length; i++) {
          const old: SessionSummary = this.sessions[i];
          const title: string | undefined = map.get(old.sessionId);
          next.push({ sessionId: old.sessionId, cwd: old.cwd, title: title !== undefined ? title : old.title });
        }
        this.sessions = next;
        this.rebuildRows();
      } catch (e) {
        // 标题只是锦上添花
      }
    }, (message: string) => {
      // 忽略
    });
  }

  private updateSessionTitle(sessionId: string, title: string): void {
    for (let i = 0; i < this.sessions.length; i++) {
      if (this.sessions[i].sessionId === sessionId) {
        this.sessions[i].title = title;
        break;
      }
    }
    this.sessions = this.sessions.slice();
    if (sessionId === this.activeSessionId) {
      this.activeTitle = title;
      this.saveCachedChat();
    }
    this.rebuildRows();
  }

  private refreshActiveTitle(): void {
    const client: AcpClient | null = this.client;
    if (client === null || this.activeSessionId.length === 0) {
      return;
    }
    client.request('phone/titles', JSON.stringify({ sessionIds: [this.activeSessionId] }), 15000,
      (json: string) => {
        try {
          const result: TitlesResult = JSON.parse(json) as TitlesResult;
          if (result.titles.length > 0 && result.titles[0].title.length > 0) {
            this.updateSessionTitle(this.activeSessionId, result.titles[0].title);
          }
        } catch (e) {
          // 忽略
        }
      }, (message: string) => {
        // 标题同步失败不影响对话
      });
  }

  private recentCwds(): string[] {
    const out: string[] = [];
    if (this.defaultCwd.length > 0) {
      out.push(this.defaultCwd);
    }
    for (let i = 0; i < this.sessions.length && out.length < 6; i++) {
      const cwd: string = this.sessions[i].cwd;
      if (cwd.length > 0 && out.indexOf(cwd) < 0) {
        out.push(cwd);
      }
    }
    return out;
  }

  // ------------------------------------------------------------ 对话

  private sendPrompt(): void {
    const client: AcpClient | null = this.client;
    if (client === null || this.activeSessionId.length === 0) {
      return;
    }
    const text: string = this.input.trim();
    if (text.length === 0 || this.streaming) {
      return;
    }
    if (!this.sessionReady) {
      this.toast('会话没有恢复，先刷新或新建会话');
      this.status = '会话未就绪';
      return;
    }

    const user: ChatMessage = newMessage('user');
    user.text = text;
    const assistant: ChatMessage = newMessage('assistant');
    assistant.streaming = true;
    this.messages.push(user);
    this.messages.push(assistant);
    this.currentAssistantId = assistant.id;
    this.toolByCallId.clear();
    this.input = '';
    this.streaming = true;
    this.historyNote = '';
    this.messages = this.messages.slice();
    this.scrollToBottom();

    console.info(`[acp] prompt sid=${this.activeSessionId} chars=${text.length}`);
    const content: PromptContent = { type: 'text', text: text };
    const prompt: PromptParams = { sessionId: this.activeSessionId, prompt: [content] };
    const params: string = JSON.stringify(prompt);
    client.request('session/prompt', params, 600000, (json: string) => {
      this.streaming = false;
      this.finishAssistant('');
      try {
        const result: PromptResult = JSON.parse(json) as PromptResult;
        if (result.stopReason === 'cancelled') {
          this.status = '已停止';
        } else {
          this.status = '完成';
        }
      } catch (e) {
        this.status = '完成';
      }
      this.scrollToBottom();
    }, (message: string) => {
      this.streaming = false;
      if (message.indexOf('unknown session') >= 0) {
        this.sessionReady = false;
        this.historyNote = '会话已失效：电脑端重启过。刷新会话列表，或新建会话。';
      }
      this.finishAssistant(`请求失败：${message}`);
      this.status = '请求失败';
      this.scrollToBottom();
    });
  }

  private stopPrompt(): void {
    const client: AcpClient | null = this.client;
    if (client === null || !this.streaming) {
      return;
    }
    client.notify('session/cancel', JSON.stringify({ sessionId: this.activeSessionId }));
    this.status = '正在停止…';
  }

  private saveCachedChat(): void {
    if (this.activeSessionId.length === 0) {
      return;
    }
    const cached: ChatMessage[] = [];
    const start: number = Math.max(0, this.messages.length - 10);
    for (let i = start; i < this.messages.length; i++) {
      const item: ChatMessage = copyMessage(this.messages[i]);
      item.text = item.text.slice(0, 4000);
      item.reasoning = item.reasoning.slice(0, 2000);
      item.toolText = item.toolText.slice(0, 2000);
      item.toolArgs = item.toolArgs.slice(0, 2000);
      item.streaming = false;
      cached.push(item);
    }
    const session: LastSession = {
      sessionId: this.activeSessionId,
      title: this.activeTitle,
      cwd: this.activeCwd
    };
    const payload: CachedChat = { session: session, messages: cached };
    Store.saveLastChat(JSON.stringify(payload)).catch(() => {});
  }

  private finishAssistant(errorText: string): void {
    for (let i = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].id === this.currentAssistantId) {
        const updated: ChatMessage = copyMessage(this.messages[i]);
        updated.streaming = false;
        if (errorText.length > 0 && updated.text.length === 0) {
          updated.text = errorText;
        }
        this.messages[i] = updated;
        break;
      }
    }
    this.messages = this.messages.slice();
    this.saveCachedChat();
    this.refreshActiveTitle();
  }

  private handleUpdate(json: string): void {
    let params: AcpUpdateParams;
    try {
      params = JSON.parse(json) as AcpUpdateParams;
    } catch (e) {
      return;
    }
    console.info(`[acp] update kind=${params.update === undefined ? 'none' : params.update.sessionUpdate} sid=${params.sessionId} active=${this.activeSessionId}`);
    if (params.sessionId !== this.activeSessionId || params.update === undefined) {
      return;
    }
    const kind: string = params.update.sessionUpdate;

    if (kind === 'agent_message_chunk') {
      const text: string = contentText(params.update.content);
      if (text.length === 0) {
        return;
      }
      let found: boolean = false;
      for (let i = this.messages.length - 1; i >= 0; i--) {
        if (this.messages[i].id === this.currentAssistantId) {
          const updated: ChatMessage = copyMessage(this.messages[i]);
          updated.text += text;
          this.messages[i] = updated;
          found = true;
          break;
        }
      }
      if (!found) {
        const msg: ChatMessage = newMessage('assistant');
        msg.text = text;
        msg.streaming = true;
        this.currentAssistantId = msg.id;
        this.messages.push(msg);
      }
    } else if (kind === 'agent_thought_chunk') {
      const text: string = contentText(params.update.content);
      if (text.length === 0) {
        return;
      }
      let found: boolean = false;
      for (let i = this.messages.length - 1; i >= 0; i--) {
        if (this.messages[i].id === this.currentAssistantId) {
          const updated: ChatMessage = copyMessage(this.messages[i]);
          updated.reasoning += text;
          this.messages[i] = updated;
          found = true;
          break;
        }
      }
      if (!found) {
        const msg: ChatMessage = newMessage('assistant');
        msg.reasoning = text;
        msg.streaming = true;
        this.currentAssistantId = msg.id;
        this.messages.push(msg);
      }
    } else if (kind === 'tool_call') {
      const msg: ChatMessage = newMessage('tool');
      msg.toolName = params.update.title !== undefined ? params.update.title : (params.update.kind !== undefined ? params.update.kind : 'tool');
      msg.callId = params.update.toolCallId !== undefined ? params.update.toolCallId : '';
      msg.status = params.update.status !== undefined ? params.update.status : 'in_progress';
      if (params.update.rawInput !== undefined) {
        msg.toolArgs = JSON.stringify(params.update.rawInput);
      }
      this.messages.push(msg);
      if (msg.callId.length > 0) {
        this.toolByCallId.set(msg.callId, msg.id);
      }
    } else if (kind === 'tool_call_update') {
      const callId: string = params.update.toolCallId !== undefined ? params.update.toolCallId : '';
      const id: string | undefined = this.toolByCallId.get(callId);
      if (id !== undefined) {
        for (let i = 0; i < this.messages.length; i++) {
          if (this.messages[i].id === id) {
            const updated: ChatMessage = copyMessage(this.messages[i]);
            if (params.update.status !== undefined) {
              updated.status = params.update.status;
            }
            const text: string = contentText(params.update.content);
            if (text.length > 0) {
              updated.toolText = text;
            }
            this.messages[i] = updated;
            break;
          }
        }
      }
    } else if (kind === 'usage_update') {
      const used: number = params.update.used !== undefined ? params.update.used : 0;
      const size: number = params.update.size !== undefined ? params.update.size : 0;
      for (let i = this.messages.length - 1; i >= 0; i--) {
        if (this.messages[i].id === this.currentAssistantId) {
          const updated: ChatMessage = copyMessage(this.messages[i]);
          updated.usage = size > 0 ? `${Math.round(used / 100) / 10}k / ${Math.round(size / 100) / 10}k` : '';
          this.messages[i] = updated;
          break;
        }
      }
    } else {
      return;
    }

    this.messages = this.messages.slice();
    this.scrollToBottom();
  }

  private handlePermission(json: string, rpcId: number): void {
    let params: PermissionParams;
    try {
      params = JSON.parse(json) as PermissionParams;
    } catch (e) {
      return;
    }
    this.permissionRpcId = rpcId;
    this.permissionSessionId = params.sessionId;
    this.permissionOptions = params.options !== undefined ? params.options : [];
    let title: string = '需要授权';
    if (params.toolCall !== undefined) {
      const tool: PermissionTool = params.toolCall as PermissionTool;
      if (tool.title !== undefined && tool.title.length > 0) {
        title = tool.title;
      }
    }
    this.permissionTitle = title;
    this.permissionVisible = true;
  }

  private respondPermission(optionId: string): void {
    const client: AcpClient | null = this.client;
    if (client === null) {
      this.permissionVisible = false;
      return;
    }
    const result: string = optionId.length === 0
      ? '{"outcome":{"outcome":"cancelled"}}'
      : `{"outcome":{"outcome":"selected","optionId":${JSON.stringify(optionId)}}}`;
    client.respond(this.permissionRpcId, result);
    this.permissionVisible = false;
  }

  // ------------------------------------------------------------ 模型 / 配置

  private applyConfigs(raw: RawConfigOption[], autoModel: boolean): void {
    this.configs = parseConfigOptions(raw);
    this.modelName = currentModelName(this.configs);
    if (autoModel && !this.autoModelDone) {
      const preferred: string = findPreferredModel(this.configs);
      if (preferred.length > 0 && preferred !== this.currentValue('model')) {
        this.autoModelDone = true;
        this.applyConfig('model', preferred);
      }
    }
  }

  private currentValue(id: string): string {
    for (let i = 0; i < this.configs.length; i++) {
      if (this.configs[i].id === id) {
        return this.configs[i].currentValue;
      }
    }
    return '';
  }

  private applyConfig(id: string, value: string): void {
    const client: AcpClient | null = this.client;
    if (client === null || this.activeSessionId.length === 0) {
      return;
    }
    this.autoModelDone = true;
    const params: string = JSON.stringify({
      sessionId: this.activeSessionId,
      configId: id,
      value: value
    });
    client.request('session/set_config_option', params, 20000, (json: string) => {
      try {
        const result: SessionResumeResult = JSON.parse(json) as SessionResumeResult;
        if (result.configOptions !== undefined) {
          this.configs = parseConfigOptions(result.configOptions);
          this.modelName = currentModelName(this.configs);
          return;
        }
      } catch (e) {
        // 回退到本地状态
      }
      for (let i = 0; i < this.configs.length; i++) {
        if (this.configs[i].id === id) {
          this.configs[i].currentValue = value;
          break;
        }
      }
      this.modelName = currentModelName(this.configs);
      this.configs = this.configs.slice();
    }, (message: string) => {
      this.toast(`切换失败：${message}`);
    });
  }

  // ------------------------------------------------------------ 扫码

  private async scan(): Promise<void> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      this.toast('拿不到页面上下文');
      return;
    }
    const options: scanBarcode.ScanOptions = {
      scanTypes: [scanCore.ScanType.ALL],
      enableMultiMode: false,
      enableAlbum: true
    };
    try {
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(context, options);
      const text: string = result.originalValue;
      if (text.length === 0) {
        this.toast('二维码里没有内容');
        return;
      }
      this.serverInput = text.trim();
      this.connectFromInput();
    } catch (e) {
      const error: BusinessError = e as BusinessError;
      if (error.code === 1000500002) {
        return;
      }
      this.toast(`扫码失败：${error.code}`);
    }
  }

  // ------------------------------------------------------------ 工具

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2200 });
    } catch (e) {
      // 忽略
    }
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 忽略
      }
    }, 60);
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        // 长历史布局晚一拍，再滚一次
      }
    }, 260);
  }

  private loadOlder(): void {
    const client: AcpClient | null = this.client;
    if (client === null || this.activeSessionId.length === 0) {
      return;
    }
    if (!this.historyReady || !this.historyHasMore || this.historyLoading) {
      return;
    }
    const before: number = this.historyBefore;
    if (before <= 0) {
      this.historyHasMore = false;
      return;
    }
    this.historyLoading = true;
    const anchor: number = this.firstVisibleIndex;
    client.request('phone/history', JSON.stringify({
      sessionId: this.activeSessionId,
      limit: 10,
      before: before
    }), 30000, (json: string) => {
      this.historyLoading = false;
      try {
        const olderResult: HistoryResult = JSON.parse(json) as HistoryResult;
        const older: ChatMessage[] = [];
        for (let i = 0; i < olderResult.messages.length; i++) {
          older.push(fromHistory(olderResult.messages[i]));
        }
        if (older.length === 0) {
          this.historyHasMore = false;
          return;
        }
        this.historyBefore = typeof olderResult.before === 'number'
          ? olderResult.before : Math.max(0, before - older.length);
        this.historyHasMore = olderResult.hasMore === true;
        this.messages = older.concat(this.messages);
        setTimeout(() => {
          try {
            this.scroller.scrollToIndex(older.length + anchor, false, ScrollAlign.START);
          } catch (e) {
            // 忽略
          }
        }, 80);
        this.toast(`已加载 ${older.length} 条更早消息`);
      } catch (e) {
        this.historyHasMore = false;
        this.toast('更早的历史解析失败');
      }
    }, (message: string) => {
      this.historyLoading = false;
      this.toast('更早的历史没读到');
    });
  }

  private connColor(): string {
    if (this.conn === ConnState.Online) {
      return OK;
    }
    if (this.conn === ConnState.Error) {
      return DANGER;
    }
    if (this.conn === ConnState.Connecting) {
      return ACCENT;
    }
    return SOFT;
  }

  private openSheet(kind: string, height: number): void {
    this.sheetKind = kind;
    this.sheetHeight = height;
    this.sheetOpen = true;
  }

  private setAutoConnect(value: boolean): void {
    this.autoConnect = value;
    const settings: NativeSettings = { autoConnect: value };
    Store.saveSettings(settings).catch(() => {});
  }

  // ------------------------------------------------------------ 首页

  @Builder
  brandRow() {
    Row() {
      Text('DSH / POCKET')
        .fontSize(11)
        .fontWeight(600)
        .letterSpacing(2.4)
        .fontColor(ACCENT)
      Blank()
      Text('NATIVE')
        .fontSize(10)
        .letterSpacing(1.8)
        .fontColor(SOFT)
    }
    .width('100%')
  }

  @Builder
  statusRow() {
    Row({ space: 10 }) {
      Row()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(this.connColor())
      Text(this.status)
        .fontSize(13)
        .fontColor(MUTED)
        .layoutWeight(1)
        .maxLines(2)
    }
    .width('100%')
    .padding({ top: 18, bottom: 18 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  connectPane() {
    Scroll() {
      Row() {
        Column() {
          this.brandRow()

          Text('电脑上的 DSH\n现在在手机上')
            .fontSize(this.expanded ? 42 : 30)
            .fontWeight(700)
            .lineHeight(this.expanded ? 50 : 38)
            .letterSpacing(-0.6)
            .fontColor(INK)
            .margin({ top: 20 })

          Text('原生界面。聊天、会话、工具、权限都走 ACP，不再加载网页。')
            .fontSize(14)
            .lineHeight(22)
            .fontColor(MUTED)
            .margin({ top: 10 })

          this.statusRow()

          Column() {
            Row() {
              Text('01')
                .fontSize(11)
                .fontWeight(600)
                .fontColor(ACCENT)
              Text('配对地址')
                .fontSize(11)
                .letterSpacing(1.6)
                .fontColor(MUTED)
                .margin({ left: 10 })
              Blank()
              this.linkButton('扫码连接', () => this.scan())
            }
            .width('100%')

            TextInput({ text: $$this.serverInput, placeholder: 'ws://192.168.1.10:3090/ws?token=…' })
              .fontSize(13)
              .fontColor(INK)
              .placeholderColor(SOFT)
              .backgroundColor(PANEL)
              .border({ width: 1, color: LINE })
              .borderRadius(0)
              .padding({ left: 12, right: 12 })
              .height(52)
              .margin({ top: 10 })
              .caretColor(ACCENT)

            Row({ space: 8 }) {
              Button(this.conn === ConnState.Connecting ? '连接中…' : '连接')
                .type(ButtonType.Normal)
                .borderRadius(0)
                .height(48)
                .layoutWeight(1)
                .fontSize(15)
                .fontWeight(600)
                .fontColor('#FFF8EF')
                .backgroundColor(ACCENT)
                .enabled(this.conn !== ConnState.Connecting)
                .onClick(() => this.connectFromInput())
            }
            .width('100%')
            .margin({ top: 10 })
          }
          .width('100%')
          .padding({ top: 14 })
          .border({ width: { top: 2 }, color: INK })

          Row() {
            Text('02')
              .fontSize(11)
              .fontWeight(600)
              .fontColor(ACCENT)
            Text('最近连接')
              .fontSize(11)
              .letterSpacing(1.6)
              .fontColor(MUTED)
              .margin({ left: 10 })
          }
          .width('100%')
          .margin({ top: 26, bottom: 6 })

          if (this.servers.length === 0) {
            Text('还没有记录。第一次连上后会出现在这里。')
              .fontSize(13)
              .fontColor(SOFT)
              .width('100%')
              .padding({ top: 8, bottom: 14 })
          } else {
            ForEach(this.servers, (url: string) => {
              Row() {
                Column() {
                  Text(this.serverLabel(url))
                    .fontSize(15)
                    .fontWeight(500)
                    .fontColor(INK)
                  Text('点一下重新连接')
                    .fontSize(11)
                    .fontColor(SOFT)
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text('删除')
                  .fontSize(12)
                  .fontColor(SOFT)
                  .onClick(() => this.removeServer(url))
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .border({ width: { bottom: 1 }, color: LINE })
              .onClick(() => {
                this.serverInput = url;
                this.connectFromInput();
              })
            }, (url: string) => url)
          }

          Row() {
            Text('03')
              .fontSize(11)
              .fontWeight(600)
              .fontColor(ACCENT)
            Text('电脑上还没有主机？')
              .fontSize(15)
              .fontWeight(500)
              .fontColor(INK)
              .margin({ left: 10 })
          }
          .width('100%')
          .margin({ top: 26 })

          Text('在电脑上双击 host\\start-native-host.cmd，会打开一个带二维码的页面。手机和电脑要连同一个 Wi-Fi。')
            .fontSize(13)
            .lineHeight(21)
            .fontColor(MUTED)
            .width('100%')
            .margin({ top: 8 })

          Row() {
            this.linkButton('设置', () => {
              this.openSheet('settings', 380);
            })
            Blank()
            Text('原生 ACP · 不加载网页')
              .fontSize(11)
              .fontColor(SOFT)
          }
          .width('100%')
          .margin({ top: 30, bottom: 20 })
        }
        .width('100%')
        .constraintSize({ maxWidth: this.expanded ? 760 : 2000 })
        .padding({ left: this.expanded ? 40 : 20, right: this.expanded ? 40 : 20, top: 20, bottom: 24 })
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .scrollBar(BarState.Off)
  }

  private serverLabel(url: string): string {
    const target: ServerTarget | null = parseServer(url);
    if (target === null) {
      return url;
    }
    return target.hostLabel;
  }

  private removeServer(url: string): void {
    const next: string[] = [];
    for (let i = 0; i < this.servers.length; i++) {
      if (this.servers[i] !== url) {
        next.push(this.servers[i]);
      }
    }
    this.servers = next;
  }

  // ------------------------------------------------------------ 会话列表

  @Builder
  workspaceHeader(row: SessionRow) {
    Row({ space: 8 }) {
      Row()
        .width(4)
        .height(38)
        .backgroundColor(ACCENT)
      Column() {
        Text(row.title)
          .fontSize(15)
          .fontWeight(700)
          .fontColor(INK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (row.path.length > 0) {
          Text(shortCwd(row.path))
            .fontSize(10)
            .fontColor(MUTED)
            .margin({ top: 2 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(`${row.count}`)
        .fontSize(11)
        .fontWeight(700)
        .fontColor('#FFF8EF')
        .backgroundColor(ACCENT)
        .padding({ left: 7, right: 7, top: 2, bottom: 2 })
      Text(row.collapsed ? '+' : '−')
        .fontSize(15)
        .fontWeight(700)
        .fontColor(ACCENT)
        .width(16)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding({ left: 10, right: 8, top: 9, bottom: 9 })
    .backgroundColor('#E8DCC8')
    .border({ width: { bottom: 1 }, color: '#D6C5A8' })
    .margin({ top: 8 })
    .onClick(() => this.toggleWorkspace(row.workspaceId))
  }

  @Builder
  sessionRow(session: SessionSummary, selected: boolean) {
    Row() {
      Column() {
        Text(session.title.length > 0 ? session.title : `会话 ${shortSessionId(session.sessionId)}`)
          .fontSize(15)
          .fontWeight(500)
          .fontColor(INK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text((this.isArchived(session.sessionId) ? '已隐藏 · ' : '') + shortCwd(session.cwd))
          .fontSize(11)
          .fontColor(this.isArchived(session.sessionId) ? ACCENT : SOFT)
          .margin({ top: 3 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('›')
        .fontSize(18)
        .fontColor(selected ? ACCENT : SOFT)
    }
    .width('100%')
    .padding({ top: 11, bottom: 11, left: 4, right: 4 })
    .border({ width: { bottom: 1 }, color: LINE })
    .backgroundColor(selected ? '#F0E8D8' : TRANSPARENT)
    .onClick(() => this.openSession(session))
    .gesture(LongPressGesture().onAction(() => this.toggleArchive(session)))
  }

  @Builder
  sessionsPane() {
    Column() {
      Row({ space: 6 }) {
        Button('‹')
          .type(ButtonType.Normal)
          .borderRadius(0)
          .width(40)
          .height(42)
          .fontSize(26)
          .fontColor(INK)
          .backgroundColor(TRANSPARENT)
          .onClick(() => {
            this.screen = AppScreen.Connect;
          })
        Column() {
          Text('会话')
            .fontSize(18)
            .fontWeight(700)
            .fontColor(INK)
          Text(this.conn === ConnState.Online ? '已连接' : '未连接')
            .fontSize(10)
            .fontColor(SOFT)
            .margin({ top: 1 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('+')
          .type(ButtonType.Normal)
          .borderRadius(0)
          .width(40)
          .height(42)
          .fontSize(24)
          .fontColor(ACCENT)
          .backgroundColor(TRANSPARENT)
          .onClick(() => {
            this.newCwd = this.defaultCwd;
            this.openSheet('new', 520);
          })
        Button('刷新')
          .type(ButtonType.Normal)
          .borderRadius(0)
          .width(56)
          .height(42)
          .fontSize(12)
          .fontColor(INK)
          .backgroundColor(TRANSPARENT)
          .onClick(() => this.refreshSessions())
      }
      .width('100%')
      .height(46)
      .padding({ left: 2, right: 2 })
      .border({ width: { bottom: 1 }, color: LINE })

      TextInput({ text: $$this.sessionQuery, placeholder: '搜索会话…' })
        .onChange(() => this.rebuildRows())
        .fontSize(13)
        .fontColor(INK)
        .placeholderColor(SOFT)
        .backgroundColor(PANEL)
        .border({ width: 1, color: LINE })
        .borderRadius(0)
        .height(38)
        .padding({ left: 10, right: 10 })
        .margin({ left: 20, right: 20, top: 8 })

      if (this.sessionQuery.length > 0 && this.visibleSessions().length === 0) {
        Text('没有匹配的会话')
          .fontSize(13)
          .fontColor(SOFT)
          .width('100%')
          .padding({ left: 20, top: 12 })
      }
      Row() {
        Text(this.showArchived ? '隐藏已隐藏会话' : `显示隐藏会话（${this.archivedIds.length}）`)
          .fontSize(11)
          .fontColor(ACCENT)
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 4, bottom: 2 })
      .onClick(() => {
        this.showArchived = !this.showArchived;
        this.rebuildRows();
      })


      if (this.busy) {
        Row() {
          Text('加载中…')
            .fontSize(13)
            .fontColor(SOFT)
        }
        .width('100%')
        .padding(16)
      }

      List() {
        ForEach(this.sessionRowsState, (row: SessionRow) => {
          ListItem() {
            if (row.kind === 'header') {
              this.workspaceHeader(row)
            } else {
              this.sessionRow(row.session, row.session.sessionId === this.activeSessionId)
            }
          }
        }, (row: SessionRow) => row.key + '-' + row.collapsed + '-' + (row.session.sessionId === this.activeSessionId))
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 20, right: 20 })
      .scrollBar(BarState.Off)

      if (this.sessions.length === 0 && !this.busy) {
        Column() {
          Text('还没有会话')
            .fontSize(18)
            .fontWeight(600)
            .fontColor(INK)
          Text('新建一个，开始和电脑上的 DSH 对话。')
            .fontSize(13)
            .fontColor(MUTED)
            .margin({ top: 6 })
          Button('新建会话')
            .type(ButtonType.Normal)
            .borderRadius(0)
            .height(46)
            .fontSize(15)
            .fontWeight(600)
            .fontColor('#FFF8EF')
            .backgroundColor(ACCENT)
            .margin({ top: 16 })
            .onClick(() => {
              this.newCwd = this.defaultCwd;
              this.openSheet('new', 520);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      Row() {
        Text('设置')
          .fontSize(13)
          .fontColor(ACCENT)
          .onClick(() => {
            this.openSheet('settings', 380);
          })
        Blank()
        Text(this.bridgeVersion.length > 0 ? `桥 ${this.bridgeVersion}` : 'ACP')
          .fontSize(11)
          .fontColor(SOFT)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 10, bottom: 14 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }

  @Builder
  sideRail() {
    Column() {
      Row() {
        Text('会话')
          .fontSize(11)
          .fontWeight(600)
          .letterSpacing(2)
          .fontColor(ACCENT)
        Blank()
        Button('+')
          .type(ButtonType.Normal)
          .borderRadius(0)
          .width(36)
          .height(36)
          .fontSize(22)
          .fontColor(ACCENT)
          .backgroundColor(TRANSPARENT)
          .onClick(() => {
            this.newCwd = this.defaultCwd;
            this.openSheet('new', 520);
          })
      }
      .width('100%')
      .padding({ top: 14, bottom: 10 })

      Text(this.status)
        .fontSize(11)
        .fontColor(MUTED)
        .width('100%')
        .maxLines(2)
        .margin({ bottom: 8 })

      TextInput({ text: $$this.sessionQuery, placeholder: '搜索会话…' })
        .onChange(() => this.rebuildRows())
        .fontSize(12)
        .fontColor(INK)
        .placeholderColor(SOFT)
        .backgroundColor(PANEL)
        .border({ width: 1, color: LINE })
        .borderRadius(0)
        .height(36)
        .padding({ left: 8, right: 8 })
        .margin({ bottom: 8 })
      Row() {
        Text(this.showArchived ? '隐藏已隐藏' : `显示隐藏（${this.archivedIds.length}）`)
          .fontSize(10)
          .fontColor(ACCENT)
        Blank()
      }
      .width('100%')
      .padding({ bottom: 4 })
      .onClick(() => {
        this.showArchived = !this.showArchived;
        this.rebuildRows();
      })

      List() {
        ForEach(this.sessionRowsState, (row: SessionRow) => {
          ListItem() {
            if (row.kind === 'header') {
              this.workspaceHeader(row)
            } else {
              this.sessionRow(row.session, row.session.sessionId === this.activeSessionId)
            }
          }
        }, (row: SessionRow) => row.key + '-' + row.collapsed + '-' + (row.session.sessionId === this.activeSessionId))
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)

      Row() {
        this.linkButton('设置', () => {
          this.openSheet('settings', 380);
        })
        Blank()
        Text('断开')
          .fontSize(12)
          .fontColor(SOFT)
          .onClick(() => this.disconnect())
      }
      .width('100%')
      .padding({ top: 10, bottom: 14 })
    }
    .width(320)
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor('#EFE7D8')
    .border({ width: { right: 1 }, color: LINE })
  }

  @Builder
  welcomePane() {
    Column() {
      Text('DSH / POCKET')
        .fontSize(11)
        .letterSpacing(2.4)
        .fontColor(ACCENT)
      Text('选一个会话')
        .fontSize(30)
        .fontWeight(700)
        .fontColor(INK)
        .margin({ top: 12 })
      Text('左边是电脑上的会话。点一个继续，或新建。')
        .fontSize(14)
        .fontColor(MUTED)
        .margin({ top: 8 })
      Button('新建会话')
        .type(ButtonType.Normal)
        .borderRadius(0)
        .height(46)
        .fontSize(15)
        .fontWeight(600)
        .fontColor('#FFF8EF')
        .backgroundColor(ACCENT)
        .margin({ top: 20 })
        .onClick(() => {
          this.newCwd = this.defaultCwd;
          this.openSheet('new', 520);
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Start)
    .padding(40)
    .backgroundColor(BG)
  }

  // ------------------------------------------------------------ 对话

  @Builder
  chatTopBar() {
    Row({ space: 4 }) {
      if (!this.expanded) {
        Button('‹')
          .type(ButtonType.Normal)
          .borderRadius(0)
          .width(40)
          .height(44)
          .fontSize(26)
          .fontColor(INK)
          .backgroundColor(TRANSPARENT)
          .onClick(() => {
            this.screen = AppScreen.Sessions;
          })
      }
      Column() {
        Text(this.activeTitle.length > 0 ? this.activeTitle : '会话')
          .fontSize(15)
          .fontWeight(600)
          .fontColor(INK)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(shortCwd(this.activeCwd))
          .fontSize(10)
          .fontColor(SOFT)
          .margin({ top: 1 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .onClick(() => {
        this.openSheet('models', 560);
      })
      Button(this.modelName)
        .type(ButtonType.Normal)
        .borderRadius(0)
        .height(30)
        .fontSize(11)
        .fontColor(INK)
        .backgroundColor(TRANSPARENT)
        .padding({ left: 8, right: 8 })
        .border({ width: 1, color: LINE })
        .onClick(() => {
          this.openSheet('models', 560);
        })
      Button('更多')
        .type(ButtonType.Normal)
        .borderRadius(0)
        .width(52)
        .height(44)
        .fontSize(11)
        .fontColor(INK)
        .backgroundColor(TRANSPARENT)
        .onClick(() => {
          this.openSheet('more', 480);
        })
    }
    .width('100%')
    .height(48)
    .padding({ left: 2, right: 2 })
    .border({ width: { bottom: 1 }, color: LINE })
    .backgroundColor(BG)
  }

  @Builder
  smallAction(label: string, color: string, action: () => void) {
    Button(label)
      .type(ButtonType.Normal)
      .borderRadius(0)
      .height(24)
      .fontSize(10)
      .fontColor(color)
      .backgroundColor(TRANSPARENT)
      .padding({ left: 4, right: 4 })
      .onClick(action)
  }

  @Builder
  codeBlock(text: string, bg: string, fg: string, lang: string, user: boolean) {
    Column() {
      Row() {
        Text(lang.length > 0 ? lang : '代码')
          .fontSize(10)
          .fontColor(user ? USER_MUTED : SOFT)
          .layoutWeight(1)
        this.smallAction('复制', user ? USER_LINK : ACCENT, () => {
          this.copyText(text, '代码已复制');
        })
      }
      .width('100%')
      .padding({ left: 10, right: 6, top: 6 })

      Text(text)
        .fontSize(12)
        .fontFamily('monospace')
        .lineHeight(18)
        .fontColor(fg)
        .padding({ left: 10, right: 10, bottom: 10 })
        .width('100%')
        .copyOption(CopyOptions.LocalDevice)
    }
    .width('100%')
    .backgroundColor(bg)
  }

  @Builder
  inlineSpans(spans: MdSpan[], size: number, color: string, linkColor: string) {
    Text() {
      ForEach(spans, (span: MdSpan) => {
        Span(span.text)
          .fontSize(size)
          .fontColor(span.link ? linkColor : color)
          .fontWeight(span.bold ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(span.code ? 'monospace' : 'HarmonyOS Sans')
          .decoration({
            type: span.strike ? TextDecorationType.LineThrough :
              (span.link ? TextDecorationType.Underline : TextDecorationType.None)
          })
      }, (span: MdSpan, index: number) => `${index}-${span.text.length}-${span.bold ? 1 : 0}-${span.code ? 1 : 0}-${span.link ? 1 : 0}`)
    }
    .width('100%')
    .lineHeight(size + 8)
    .copyOption(CopyOptions.LocalDevice)
  }

  @Builder
  mdHeading(block: MdBlock, color: string) {
    Text(plainInline(block.text))
      .fontSize(block.level === 1 ? 23 : (block.level === 2 ? 19 : 16))
      .fontWeight(700)
      .fontColor(color)
      .width('100%')
      .lineHeight(block.level === 1 ? 31 : 25)
      .margin({ top: 12, bottom: 4 })
      .copyOption(CopyOptions.LocalDevice)
  }

  @Builder
  mdList(block: MdBlock, textColor: string, markerColor: string) {
    Column() {
      ForEach(block.items, (item: MdItem) => {
        Row({ space: 8 }) {
          Text(item.ordered ? item.marker : '•')
            .fontSize(14)
            .fontColor(markerColor)
            .width(26)
            .textAlign(TextAlign.End)
          Column() {
            this.inlineSpans(item.spans, 15, textColor, markerColor)
          }
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
        .padding({ left: item.indent * 12, top: 2, bottom: 2 })
      }, (item: MdItem, index: number) => `${index}-${item.text.length}-${item.marker}`)
    }
    .width('100%')
  }

  @Builder
  mdTable(block: MdBlock, textColor: string, lineColor: string, headerBg: string) {
    Column() {
      ForEach(block.rows, (row: MdRow, rowIndex: number) => {
        Row() {
          ForEach(row.cells, (cell: string, cellIndex: number) => {
            Text(plainInline(cell))
              .fontSize(12)
              .lineHeight(17)
              .fontWeight(row.header ? 600 : 400)
              .fontColor(textColor)
              .layoutWeight(1)
              .padding(6)
              .border({ width: { right: 1, bottom: 1 }, color: lineColor })
          }, (cell: string, cellIndex: number) => `${rowIndex}-${cellIndex}-${cell.length}`)
        }
        .width('100%')
        .backgroundColor(row.header ? headerBg : TRANSPARENT)
      }, (row: MdRow, rowIndex: number) => `${rowIndex}-${row.header ? 1 : 0}-${row.cells.length}`)
    }
    .width('100%')
    .border({ width: 1, color: lineColor })
    .margin({ top: 6, bottom: 6 })
  }

  @Builder
  mdQuote(block: MdBlock, color: string, lineColor: string) {
    Column() {
      this.inlineSpans(block.spans, 14, color, lineColor)
    }
    .width('100%')
    .padding({ left: 12, top: 4, bottom: 4 })
    .border({ width: { left: 3 }, color: lineColor })
    .margin({ top: 6, bottom: 6 })
  }

  @Builder
  messageActions(msg: ChatMessage, user: boolean) {
    Row({ space: 10 }) {
      Text(timeLabel(msg.at))
        .fontSize(10)
        .fontColor(user ? USER_MUTED : SOFT)
      Blank()
      this.smallAction('复制', user ? USER_LINK : ACCENT, () => {
        this.copyText(msg.text, '已复制');
      })
      if (msg.role === 'user') {
        this.smallAction('编辑', user ? USER_LINK : ACCENT, () => {
          this.useAsInput(msg.text);
        })
      } else {
        this.smallAction('引用', user ? USER_LINK : ACCENT, () => {
          this.quoteText(msg.text);
        })
      }
    }
    .width('100%')
    .padding({ top: 4 })
  }

  @Builder
  markdownView(text: string, user: boolean) {
    ForEach(parseMarkdown(text), (block: MdBlock, index: number) => {
      if (block.kind === 'heading') {
        this.mdHeading(block, user ? USER_FG : INK)
      } else if (block.kind === 'code') {
        this.codeBlock(block.text, user ? USER_CODE_BG : CODE_BG, user ? USER_FG : CODE_FG, block.lang, user)
      } else if (block.kind === 'list') {
        this.mdList(block, user ? USER_FG : INK, user ? USER_LINK : ACCENT)
      } else if (block.kind === 'table') {
        this.mdTable(block, user ? USER_FG : INK, user ? USER_LINE : LINE, user ? USER_HEADER_BG : '#EFE7D8')
      } else if (block.kind === 'quote') {
        this.mdQuote(block, user ? USER_MUTED : MUTED, user ? USER_LINE : ACCENT)
      } else if (block.kind === 'hr') {
        Divider()
          .strokeWidth(1)
          .color(user ? USER_LINE : LINE)
          .margin({ top: 10, bottom: 10 })
      } else {
        Column() {
          this.inlineSpans(block.spans, 15, user ? USER_FG : INK, user ? USER_LINK : ACCENT)
        }
        .width('100%')
        .margin({ top: 4, bottom: 4 })
      }
    }, (block: MdBlock, index: number) => `${index}-${block.kind}-${block.text.length}-${block.rows.length}-${block.items.length}`)
  }

  @Builder
  reasoningBlock(msg: ChatMessage) {
    Column() {
      Row() {
        Text(msg.expanded ? '收起思考' : '思考')
          .fontSize(11)
          .fontColor(ACCENT)
        Blank()
        Text(msg.expanded ? '−' : '+')
          .fontSize(14)
          .fontColor(SOFT)
      }
      .width('100%')
      .onClick(() => {
        for (let i = 0; i < this.messages.length; i++) {
          if (this.messages[i].id === msg.id) {
            const updated: ChatMessage = copyMessage(this.messages[i]);
            updated.expanded = !updated.expanded;
            this.messages[i] = updated;
            break;
          }
        }
        this.messages = this.messages.slice();
      })
      if (msg.expanded && msg.reasoning.length > 0) {
        Text(clampText(msg.reasoning, 6000))
          .fontSize(12)
          .lineHeight(19)
          .fontColor(MUTED)
          .width('100%')
          .padding({ top: 8 })
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .border({ width: { bottom: 1 }, color: LINE })
  }

  @Builder
  toolCard(msg: ChatMessage) {
    Column() {
      Row() {
        Text('⚙')
          .fontSize(12)
          .fontColor(ACCENT)
        Text(msg.toolName)
          .fontSize(12)
          .fontWeight(600)
          .fontColor(INK)
          .margin({ left: 6 })
        Blank()
        Text(msg.status)
          .fontSize(10)
          .fontColor(msg.status === 'completed' ? OK : SOFT)
        Text(msg.expanded ? ' −' : ' +')
          .fontSize(12)
          .fontColor(SOFT)
      }
      .width('100%')
      .onClick(() => {
        for (let i = 0; i < this.messages.length; i++) {
          if (this.messages[i].id === msg.id) {
            const updated: ChatMessage = copyMessage(this.messages[i]);
            updated.expanded = !updated.expanded;
            this.messages[i] = updated;
            break;
          }
        }
        this.messages = this.messages.slice();
      })
      if (msg.expanded) {
        if (msg.toolArgs.length > 0) {
          Text(clampText(msg.toolArgs, 2000))
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor(MUTED)
            .width('100%')
            .padding({ top: 8 })
            .copyOption(CopyOptions.LocalDevice)
        }
        if (msg.toolText.length > 0) {
          Text(clampText(msg.toolText, 4000))
            .fontSize(11)
            .lineHeight(17)
            .fontColor(INK)
            .width('100%')
            .padding({ top: 8 })
            .copyOption(CopyOptions.LocalDevice)
        }
      }
      Row() {
        Text(timeLabel(msg.at))
          .fontSize(10)
          .fontColor(SOFT)
        Blank()
        this.smallAction('复制', ACCENT, () => {
          const body: string = msg.toolText.length > 0 ? msg.toolText : msg.toolArgs;
          this.copyText(body, '工具内容已复制');
        })
      }
      .width('100%')
      .padding({ top: 4 })
    }
    .width('100%')
    .padding(10)
    .backgroundColor('#F8F2E6')
    .border({ width: 1, color: LINE })
  }

  @Builder
  assistantMessage(msg: ChatMessage) {
    Column() {
      Row() {
        Text('DSH')
          .fontSize(10)
          .fontWeight(600)
          .letterSpacing(1.4)
          .fontColor(ACCENT)
        if (msg.streaming) {
          Text('生成中…')
            .fontSize(10)
            .fontColor(SOFT)
            .margin({ left: 8 })
        }
      }
      .width('100%')
      .margin({ bottom: 6 })

      if (msg.reasoning.length > 0) {
        this.reasoningBlock(msg)
      }
      if (msg.text.length > 0) {
        this.markdownView(msg.text, false)
      }
      if (msg.usage.length > 0) {
        Text(msg.usage)
          .fontSize(10)
          .fontColor(SOFT)
          .margin({ top: 6 })
      }
      this.messageActions(msg, false)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 10 })
  }

  @Builder
  userMessage(msg: ChatMessage) {
    Row() {
      Blank()
      Column() {
        this.markdownView(msg.text, true)
        this.messageActions(msg, true)
      }
      .constraintSize({ maxWidth: this.expanded ? 760 : '92%' })
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .backgroundColor(ACCENT)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  messageItem(msg: ChatMessage) {
    if (msg.role === 'user') {
      this.userMessage(msg)
    } else if (msg.role === 'tool') {
      this.toolCard(msg)
    } else {
      this.assistantMessage(msg)
    }
  }

  @Builder
  composer() {
    Row({ space: 8 }) {
      TextArea({ text: $$this.input, placeholder: this.sessionReady ? '问点什么…' : '会话未就绪，先刷新或新建…' })
        .fontSize(15)
        .fontColor(INK)
        .placeholderColor(SOFT)
        .backgroundColor(PANEL)
        .border({ width: 1, color: LINE })
        .borderRadius(0)
        .padding({ left: 12, right: 12, top: 8, bottom: 8 })
        .height(56)
        .layoutWeight(1)
        .maxLines(4)
      Button(this.streaming ? '停止' : '发送')
        .enabled(this.streaming || this.sessionReady)
        .type(ButtonType.Normal)
        .borderRadius(0)
        .height(56)
        .width(76)
        .fontSize(14)
        .fontWeight(600)
        .fontColor(this.streaming ? DANGER : '#FFF8EF')
        .backgroundColor(this.streaming ? '#F3DFD9' : ACCENT)
        .border({ width: 1, color: this.streaming ? DANGER : ACCENT })
        .onClick(() => {
          if (this.streaming) {
            this.stopPrompt();
          } else {
            this.sendPrompt();
          }
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 10 })
    .backgroundColor(BG)
    .border({ width: { top: 1 }, color: LINE })
  }

  @Builder
  permissionOverlay() {
    Column() {
      Column() {
        Text('权限请求')
          .fontSize(11)
          .letterSpacing(2)
          .fontColor(ACCENT)
        Text(this.permissionTitle)
          .fontSize(19)
          .fontWeight(700)
          .fontColor(INK)
          .margin({ top: 8 })
        Text('电脑上的 DSH 要执行一个工具。允许这一次？')
          .fontSize(13)
          .fontColor(MUTED)
          .margin({ top: 8 })
        ForEach(this.permissionOptions, (option: PermissionOption) => {
          Button(option.name)
            .type(ButtonType.Normal)
            .borderRadius(0)
            .width('100%')
            .height(44)
            .fontSize(14)
            .fontColor(INK)
            .backgroundColor(PANEL)
            .border({ width: 1, color: INK })
            .margin({ top: 8 })
            .onClick(() => this.respondPermission(option.optionId))
        }, (option: PermissionOption) => option.optionId)
        Button('拒绝')
          .type(ButtonType.Normal)
          .borderRadius(0)
          .width('100%')
          .height(44)
          .fontSize(14)
          .fontColor(DANGER)
          .backgroundColor(TRANSPARENT)
          .border({ width: 1, color: DANGER })
          .margin({ top: 10 })
          .onClick(() => this.respondPermission(''))
      }
      .width('100%')
      .constraintSize({ maxWidth: 420 })
      .padding(22)
      .backgroundColor(BG)
      .border({ width: 1, color: INK })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(24)
    .backgroundColor('#8A000000')
  }

  @Builder
  chatPane() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.chatTopBar()

        if (this.historyNote.length > 0) {
          Row() {
            Text(this.historyNote)
              .fontSize(11)
              .fontColor(MUTED)
              .layoutWeight(1)
            Text('×')
              .fontSize(14)
              .fontColor(SOFT)
              .onClick(() => {
                this.historyNote = '';
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor('#F0E8D8')
        }

        if (this.messages.length === 0) {
          Column() {
            Text('开始对话')
              .fontSize(22)
              .fontWeight(600)
              .fontColor(INK)
            Text('消息会流式出现在这里。工具调用会显示成卡片。')
              .fontSize(13)
              .fontColor(MUTED)
              .margin({ top: 6 })
          }
          .layoutWeight(1)
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .padding(24)
        } else {
          List({ space: 2, scroller: this.scroller }) {
            ForEach(this.messages, (msg: ChatMessage) => {
              ListItem() {
                this.messageItem(msg)
              }
            }, (msg: ChatMessage) => msg.id + '-' + msg.rev)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: this.expanded ? 24 : 14, right: this.expanded ? 24 : 14, top: 8 })
          .scrollBar(BarState.Off)
          .onScrollIndex((start: number, end: number) => {
            this.firstVisibleIndex = start;
          })
          .onReachStart(() => {
            this.loadOlder();
          })
        }

        this.composer()
      }
      .width('100%')
      .height('100%')

      if (this.permissionVisible) {
        this.permissionOverlay()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
  }

  // ------------------------------------------------------------ 弹层

  @Builder
  choiceRow(option: AiConfigOption, choice: AiChoice) {
    Row() {
      Column() {
        Text(choice.name)
          .fontSize(14)
          .fontColor(INK)
        if (choice.description.length > 0) {
          Text(choice.description)
            .fontSize(10)
            .fontColor(SOFT)
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (option.currentValue === choice.value) {
        Text('✓')
          .fontSize(15)
          .fontColor(ACCENT)
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .border({ width: { bottom: 1 }, color: LINE })
    .onClick(() => {
      this.applyConfig(option.id, choice.value);
      this.sheetOpen = false;
    })
  }

  @Builder
  modelsSheet() {
    Column() {
      Text('模型与推理')
        .fontSize(20)
        .fontWeight(700)
        .fontColor(INK)
        .width('100%')
        .margin({ bottom: 6 })
      if (this.configs.length === 0) {
        Text('连上会话后，这里会列出电脑上可用的模型。')
          .fontSize(13)
          .fontColor(MUTED)
          .width('100%')
          .margin({ top: 12 })
      } else {
        Scroll() {
          Column() {
            ForEach(this.configs, (option: AiConfigOption) => {
              Text(option.name)
                .fontSize(11)
                .letterSpacing(1.4)
                .fontColor(ACCENT)
                .width('100%')
                .margin({ top: 14, bottom: 2 })
              ForEach(option.choices, (choice: AiChoice) => {
                this.choiceRow(option, choice)
              }, (choice: AiChoice) => option.id + choice.value)
            }, (option: AiConfigOption) => option.id)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: this.expanded ? 560 : 2000 })
    .padding({ left: 22, right: 22, top: 18, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(BG)
  }

  @Builder
  newSessionSheet() {
    Column() {
      Text('新建会话')
        .fontSize(20)
        .fontWeight(700)
        .fontColor(INK)
        .width('100%')
      Text('在电脑上的哪个目录里工作？')
        .fontSize(12)
        .fontColor(MUTED)
        .width('100%')
        .margin({ top: 4, bottom: 10 })
      TextInput({ text: $$this.newCwd, placeholder: 'D:\\项目\\demo' })
        .fontSize(13)
        .fontColor(INK)
        .backgroundColor(PANEL)
        .border({ width: 1, color: LINE })
        .borderRadius(0)
        .height(48)
        .padding({ left: 12, right: 12 })
      Text('最近目录')
        .fontSize(11)
        .letterSpacing(1.4)
        .fontColor(ACCENT)
        .width('100%')
        .margin({ top: 16, bottom: 6 })
      ForEach(this.recentCwds(), (cwd: string) => {
        Text(cwd)
          .fontSize(12)
          .fontColor(INK)
          .width('100%')
          .padding({ top: 8, bottom: 8 })
          .border({ width: { bottom: 1 }, color: LINE })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .onClick(() => {
            this.newCwd = cwd;
          })
      }, (cwd: string) => cwd)
      Button('创建')
        .type(ButtonType.Normal)
        .borderRadius(0)
        .width('100%')
        .height(46)
        .fontSize(15)
        .fontWeight(600)
        .fontColor('#FFF8EF')
        .backgroundColor(ACCENT)
        .margin({ top: 18 })
        .onClick(() => this.createSession(this.newCwd))
    }
    .width('100%')
    .constraintSize({ maxWidth: this.expanded ? 560 : 2000 })
    .padding({ left: 22, right: 22, top: 18, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(BG)
  }

  @Builder
  settingsSheet() {
    Column() {
      Text('设置')
        .fontSize(20)
        .fontWeight(700)
        .fontColor(INK)
        .width('100%')
        .margin({ bottom: 8 })

      Row() {
        Column() {
          Text('启动时自动连接')
            .fontSize(15)
            .fontColor(INK)
          Text('用最近一次地址重连')
            .fontSize(11)
            .fontColor(SOFT)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.autoConnect })
          .onChange((on: boolean) => {
            this.setAutoConnect(on);
          })
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .border({ width: { bottom: 1 }, color: LINE })

      Button('断开连接')
        .type(ButtonType.Normal)
        .borderRadius(0)
        .width('100%')
        .height(38)
        .fontSize(14)
        .fontColor(DANGER)
        .backgroundColor(TRANSPARENT)
        .margin({ top: 18 })
        .onClick(() => {
          this.sheetOpen = false;
          this.disconnect();
        })

      Text('原生版走 ACP。工具在电脑上执行；手机只负责界面和协议。')
        .fontSize(11)
        .lineHeight(18)
        .fontColor(SOFT)
        .width('100%')
        .margin({ top: 14 })
      if (this.bridgeVersion.length > 0) {
        Text(`主机桥版本 ${this.bridgeVersion}`)
          .fontSize(10)
          .fontColor(SOFT)
          .width('100%')
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .constraintSize({ maxWidth: this.expanded ? 560 : 2000 })
    .padding({ left: 22, right: 22, top: 18, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(BG)
  }

  @Builder
  moreSheet() {
    Column() {
      Text('会话')
        .fontSize(20)
        .fontWeight(700)
        .fontColor(INK)
        .width('100%')
        .margin({ bottom: 6 })
      this.sheetRow('刷新会话列表', () => this.refreshSessions())
      this.sheetRow('新建会话', () => {
        this.newCwd = this.defaultCwd;
        this.openSheet('new', 520);
      })
      this.sheetRow('切换模型', () => {
        this.openSheet('models', 560);
      })
      this.sheetRow('设置', () => {
        this.openSheet('settings', 380);
      })
      this.sheetRow('复制当前消息', () => this.copyTranscript())
      this.sheetRow('断开连接', () => this.disconnect())
    }
    .width('100%')
    .constraintSize({ maxWidth: this.expanded ? 560 : 2000 })
    .padding({ left: 22, right: 22, top: 18, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(BG)
  }

  @Builder
  linkButton(label: string, action: () => void) {
    Button(label)
      .type(ButtonType.Normal)
      .borderRadius(0)
      .height(30)
      .fontSize(13)
      .fontColor(ACCENT)
      .backgroundColor(TRANSPARENT)
      .padding({ left: 0, right: 0 })
      .onClick(action)
  }

  @Builder
  sheetRow(label: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor(INK)
        .width('100%')
        .padding({ top: 14, bottom: 14 })
    }
    .width('100%')
    .border({ width: { bottom: 1 }, color: LINE })
    .onClick(() => {
      const before: string = this.sheetKind;
      action();
      if (this.sheetKind === before) {
        this.sheetOpen = false;
      }
    })
  }

  private async copyText(text: string, label: string): Promise<void> {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.toast(label);
    } catch (e) {
      this.toast('复制失败');
    }
  }

  private useAsInput(text: string): void {
    this.input = text;
    this.toast('已填入输入框');
  }

  private quoteText(text: string): void {
    const lines: string[] = text.split('\n');
    let quoted: string = '';
    for (let i = 0; i < lines.length; i++) {
      quoted += '> ' + lines[i] + '\n';
    }
    this.input = quoted + '\n' + this.input;
    this.toast('已引用');
  }

  private async copyTranscript(): Promise<void> {
    let text: string = '';
    for (let i = 0; i < this.messages.length; i++) {
      const msg: ChatMessage = this.messages[i];
      text += `${msg.role}: ${msg.role === 'tool' ? msg.toolText : msg.text}\n\n`;
    }
    await this.copyText(text, '对话已复制');
  }

  // ------------------------------------------------------------ 根布局

  @Builder
  sheetContent() {
    if (this.sheetKind === 'models') {
      this.modelsSheet()
    } else if (this.sheetKind === 'new') {
      this.newSessionSheet()
    } else if (this.sheetKind === 'settings') {
      this.settingsSheet()
    } else {
      this.moreSheet()
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.conn === ConnState.Online && this.expanded) {
        Row() {
          this.sideRail()
          Column() {
            if (this.screen === AppScreen.Chat) {
              this.chatPane()
            } else {
              this.welcomePane()
            }
          }
          .layoutWeight(1)
          .height('100%')
        }
        .width('100%')
        .height('100%')
      } else if (this.screen === AppScreen.Connect) {
        this.connectPane()
      } else if (this.screen === AppScreen.Sessions) {
        this.sessionsPane()
      } else {
        this.chatPane()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(BG)
    .bindSheet($$this.sheetOpen, this.sheetContent(), {
      height: this.sheetHeight,
      showClose: true,
      backgroundColor: BG,
      preferType: this.expanded ? SheetType.CENTER : SheetType.BOTTOM,
      onDisappear: () => {
        this.sheetOpen = false;
      }
    })
  }
}

interface PermissionTool {
  title?: string;
}
