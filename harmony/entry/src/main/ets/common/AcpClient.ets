import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { RpcEnvelope } from './Models';

interface PendingCall {
  onResult: (json: string) => void;
  onError: (message: string) => void;
  timer: number;
}

/**
 * ACP over WebSocket 的最小客户端。
 *
 * 协议是 JSON-RPC 2.0：
 *   - 手机 -> 电脑：request / notification
 *   - 电脑 -> 手机：response / session/update / session/request_permission
 *
 * 这里只做传输和 id 匹配，JSON 的语义交给页面解析。
 */
export class AcpClient {
  private ws: webSocket.WebSocket | null = null;
  private nextId: number = 1;
  private pending: Map<number, PendingCall> = new Map();
  private connected: boolean = false;
  private intentionalClose: boolean = false;

  onUpdate: (json: string) => void = () => {};
  onPermission: (json: string, rpcId: number) => void = () => {};
  onHello: (json: string) => void = () => {};
  onClosed: (reason: string) => void = () => {};

  connect(url: string): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws: webSocket.WebSocket = webSocket.createWebSocket();
      this.ws = ws;
      this.intentionalClose = false;

      ws.on('message', (err: BusinessError, data: string | ArrayBuffer) => {
        if (err) {
          return;
        }
        if (typeof data === 'string') {
          this.handle(data);
        }
      });

      ws.on('close', (err: BusinessError) => {
        this.connected = false;
        this.failPending('连接已断开');
        if (!this.intentionalClose) {
          this.onClosed('连接已断开');
        }
      });

      ws.on('error', (err: BusinessError) => {
        this.connected = false;
        if (!this.intentionalClose) {
          this.onClosed(`WebSocket 错误 ${err.code}`);
        }
      });

      const options: webSocket.WebSocketRequestOptions = {
        header: {
          'ngrok-skip-browser-warning': 'true'
        }
      };
      ws.connect(url, options, (err: BusinessError, ok: boolean) => {
        if (err || !ok) {
          this.connected = false;
          reject(new Error(err ? `连不上 ${err.code}` : '连不上'));
          return;
        }
        this.connected = true;
        resolve();
      });
    });
  }

  isConnected(): boolean {
    return this.connected;
  }

  request(method: string, paramsJson: string, timeoutMs: number,
    onResult: (json: string) => void, onError: (message: string) => void): void {
    if (!this.ws || !this.connected) {
      onError('还没有连接');
      return;
    }
    const id: number = this.nextId++;
    const timer: number = setTimeout(() => {
      const call: PendingCall | undefined = this.pending.get(id);
      if (call) {
        this.pending.delete(id);
        call.onError('请求超时');
      }
    }, timeoutMs);
    this.pending.set(id, { onResult: onResult, onError: onError, timer: timer });
    const msg: string = `{"jsonrpc":"2.0","id":${id},"method":${JSON.stringify(method)},"params":${paramsJson}}`;
    this.ws.send(msg).catch((err: BusinessError) => {
      const call: PendingCall | undefined = this.pending.get(id);
      if (call) {
        clearTimeout(call.timer);
        this.pending.delete(id);
        call.onError(`发送失败 ${err.code}`);
      }
    });
  }

  notify(method: string, paramsJson: string): void {
    if (!this.ws || !this.connected) {
      return;
    }
    const msg: string = `{"jsonrpc":"2.0","method":${JSON.stringify(method)},"params":${paramsJson}}`;
    this.ws.send(msg).catch(() => {});
  }

  respond(id: number, resultJson: string): void {
    if (!this.ws || !this.connected) {
      return;
    }
    const msg: string = `{"jsonrpc":"2.0","id":${id},"result":${resultJson}}`;
    this.ws.send(msg).catch(() => {});
  }

  close(): void {
    this.intentionalClose = true;
    this.connected = false;
    this.failPending('主动断开');
    if (this.ws) {
      try {
        this.ws.close();
      } catch (e) {
        // 忽略
      }
      this.ws = null;
    }
  }

  private failPending(message: string): void {
    this.pending.forEach((call: PendingCall) => {
      clearTimeout(call.timer);
      call.onError(message);
    });
    this.pending.clear();
  }

  private handle(text: string): void {
    let msg: RpcEnvelope;
    try {
      msg = JSON.parse(text) as RpcEnvelope;
    } catch (e) {
      console.info(`[acp] bad json len=${text.length}`);
      return;
    }
    console.info(`[acp] recv len=${text.length} method=${msg.method === undefined ? 'result' : msg.method} id=${msg.id === undefined ? -1 : msg.id}`);

    if (msg.method !== undefined) {
      const params: string = msg.params === undefined ? '{}' : JSON.stringify(msg.params);
      if (msg.method === 'session/update') {
        this.onUpdate(params);
      } else if (msg.method === 'session/request_permission') {
        this.onPermission(params, msg.id === undefined ? 0 : msg.id);
      } else if (msg.method === 'phone/hello') {
        this.onHello(params);
      } else if (msg.method === 'phone/closed') {
        this.onClosed('电脑端已停止');
      }
      return;
    }

    if (msg.id === undefined) {
      return;
    }
    const call: PendingCall | undefined = this.pending.get(msg.id);
    if (!call) {
      return;
    }
    clearTimeout(call.timer);
    this.pending.delete(msg.id);
    if (msg.error !== undefined) {
      call.onError(msg.error.message);
      return;
    }
    call.onResult(msg.result === undefined ? '{}' : JSON.stringify(msg.result));
  }
}
