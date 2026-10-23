import { ServerTarget } from './Models';

/**
 * 只解析原生版的配对地址：
 *   ws://192.168.1.10:3090/ws?token=...
 *   http://192.168.1.10:3090/          （自动转成 ws，并补 /ws）
 */
export function parseServer(input: string): ServerTarget | null {
  let text: string = input.trim();
  if (text.length === 0) {
    return null;
  }

  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(text)) {
    text = 'ws://' + text;
  }

  const match = /^(ws|wss|http|https):\/\/([^/?#]+)([^#]*)/i.exec(text);
  if (match === null) {
    return null;
  }

  let scheme: string = match[1].toLowerCase();
  const authority: string = match[2];
  let rest: string = match[3];
  if (rest.length === 0) {
    rest = '/';
  }
  if (scheme === 'http') {
    scheme = 'ws';
  } else if (scheme === 'https') {
    scheme = 'wss';
  }

  let hostPort: string = authority;
  const at: number = hostPort.lastIndexOf('@');
  if (at >= 0) {
    hostPort = hostPort.substring(at + 1);
  }

  let host: string = hostPort;
  let port: number = scheme === 'wss' ? 443 : 80;
  const colon: number = hostPort.lastIndexOf(':');
  if (colon >= 0) {
    host = hostPort.substring(0, colon);
    const parsed: number = Number(hostPort.substring(colon + 1));
    if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
      return null;
    }
    port = parsed;
  }
  host = host.trim();
  if (host.length === 0 || !/^[A-Za-z0-9._-]+$/.test(host)) {
    return null;
  }

  let path: string = rest;
  if (path.indexOf('?') === 0) {
    path = '/' + path;
  }
  if (path === '/' || path.length === 0) {
    path = '/ws';
  }
  const defaultPort: boolean = (scheme === 'wss' && port === 443) || (scheme === 'ws' && port === 80);
  const hostLabel: string = defaultPort ? host : `${host}:${port}`;
  const wsUrl: string = `${scheme}://${hostLabel}${path}`;
  const token: string = /[?&]token=([^&\s]+)/.exec(path) !== null
    ? (/[?&]token=([^&\s]+)/.exec(path) as RegExpExecArray)[1]
    : '';

  const result: ServerTarget = {
    wsUrl: wsUrl,
    host: host,
    port: port,
    hostLabel: hostLabel,
    token: token
  };
  return result;
}

export function serverIssue(target: ServerTarget): string {
  if (target.host === 'localhost' || target.host === '::1' || target.host.startsWith('127.')) {
    return '手机上的 localhost 指向手机自己。请填电脑的局域网 IP。';
  }
  if (target.token.length === 0) {
    return '地址里没有 token。请在电脑上重新打开扫码页，扫完整二维码。';
  }
  return '';
}
