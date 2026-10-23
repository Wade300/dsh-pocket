import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME: string = 'dsh_pocket_native';
const KEY_SERVERS: string = 'servers';
const KEY_SETTINGS: string = 'settings';
const KEY_LAST_SESSION: string = 'last_session';
const KEY_LAST_CHAT: string = 'last_chat';
const SERVER_LIMIT: number = 5;

export interface NativeSettings {
  autoConnect: boolean;
}

export interface LastSession {
  sessionId: string;
  title: string;
  cwd: string;
}

const DEFAULT_SETTINGS: NativeSettings = { autoConnect: true };

export class Store {
  private static pref: preferences.Preferences | null = null;

  static async open(context: common.Context): Promise<void> {
    if (Store.pref !== null) {
      return;
    }
    try {
      Store.pref = await preferences.getPreferences(context, STORE_NAME);
    } catch (e) {
      throw new Error('Preferences 打不开');
    }
  }

  private static required(): preferences.Preferences {
    if (Store.pref === null) {
      throw new Error('Store 还没有打开');
    }
    return Store.pref;
  }

  static async servers(): Promise<string[]> {
    const pref: preferences.Preferences = Store.required();
    let raw: string = '[]';
    try {
      raw = pref.getSync(KEY_SERVERS, '[]') as string;
    } catch (e) {
      return [];
    }
    try {
      const parsed: string[] = JSON.parse(raw) as string[];
      if (!Array.isArray(parsed)) {
        return [];
      }
      const clean: string[] = [];
      for (let i = 0; i < parsed.length; i++) {
        if (typeof parsed[i] === 'string' && parsed[i].length > 0) {
          clean.push(parsed[i]);
        }
      }
      return clean;
    } catch (e) {
      return [];
    }
  }

  static async rememberServer(url: string): Promise<void> {
    const old: string[] = await Store.servers();
    const next: string[] = [url];
    for (let i = 0; i < old.length; i++) {
      if (old[i] !== url && next.length < SERVER_LIMIT) {
        next.push(old[i]);
      }
    }
    const pref: preferences.Preferences = Store.required();
    try {
      await pref.put(KEY_SERVERS, JSON.stringify(next));
      await pref.flush();
    } catch (e) {
      console.warn('保存服务器失败');
    }
  }

  static async lastServer(): Promise<string> {
    const list: string[] = await Store.servers();
    return list.length > 0 ? list[0] : '';
  }

  static async saveLastSession(session: LastSession): Promise<void> {
    const pref: preferences.Preferences = Store.required();
    try {
      await pref.put(KEY_LAST_SESSION, JSON.stringify(session));
      await pref.flush();
    } catch (e) {
      console.warn('保存上次会话失败');
    }
  }

  static async lastSession(): Promise<LastSession | null> {
    const pref: preferences.Preferences = Store.required();
    let raw: string = '';
    try {
      raw = pref.getSync(KEY_LAST_SESSION, '') as string;
    } catch (e) {
      return null;
    }
    if (raw.length === 0) {
      return null;
    }
    try {
      const parsed: LastSession = JSON.parse(raw) as LastSession;
      if (typeof parsed.sessionId !== 'string' || parsed.sessionId.length === 0) {
        return null;
      }
      return {
        sessionId: parsed.sessionId,
        title: typeof parsed.title === 'string' ? parsed.title : '',
        cwd: typeof parsed.cwd === 'string' ? parsed.cwd : ''
      };
    } catch (e) {
      return null;
    }
  }

  static async saveLastChat(json: string): Promise<void> {
    const pref: preferences.Preferences = Store.required();
    try {
      await pref.put(KEY_LAST_CHAT, json);
      await pref.flush();
    } catch (e) {
      console.warn('保存上次窗口失败');
    }
  }

  static async lastChat(): Promise<string> {
    const pref: preferences.Preferences = Store.required();
    try {
      return pref.getSync(KEY_LAST_CHAT, '') as string;
    } catch (e) {
      return '';
    }
  }

  static async settings(): Promise<NativeSettings> {
    const pref: preferences.Preferences = Store.required();
    let raw: string = '';
    try {
      raw = pref.getSync(KEY_SETTINGS, '') as string;
    } catch (e) {
      return Store.defaults();
    }
    if (raw.length === 0) {
      return Store.defaults();
    }
    try {
      const parsed: NativeSettings = JSON.parse(raw) as NativeSettings;
      return {
        autoConnect: typeof parsed.autoConnect === 'boolean' ? parsed.autoConnect : DEFAULT_SETTINGS.autoConnect
      };
    } catch (e) {
      return Store.defaults();
    }
  }

  static async saveSettings(settings: NativeSettings): Promise<void> {
    const pref: preferences.Preferences = Store.required();
    try {
      await pref.put(KEY_SETTINGS, JSON.stringify(settings));
      await pref.flush();
    } catch (e) {
      console.warn('保存设置失败');
    }
  }

  private static defaults(): NativeSettings {
    return { autoConnect: DEFAULT_SETTINGS.autoConnect };
  }
}
