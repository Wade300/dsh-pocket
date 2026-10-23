#!/usr/bin/env node
/**
 * DSH 随身连 · 原生版电脑端主机
 *
 * 作用：
 *   1. 启动 `dsh --profile acp`（JSON-RPC over stdio）；
 *   2. 在局域网开一个 WebSocket，把 ACP 原样转发给手机；
 *   3. 额外提供 phone/history，把电脑上的会话记录解出来给手机回放。
 *
 * 手机端是原生 ArkUI，不再加载 Web 页面。
 *
 * 依赖：Node 18+；7-Zip（只用于解压历史会话，可选）。
 */

import { spawn, spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { networkInterfaces, homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const VERSION = '2.0.0';
const WS_PATH = '/ws';
const DEFAULT_PORT = 3090;
const isWindows = process.platform === 'win32';
const MAX_CLIENTS = 1;
const MAX_AUTH_FAILS = 10;
const AUTH_FAIL_WINDOW_MS = 10 * 60 * 1000;
const BAN_MS = 60 * 60 * 1000;
const authState = new Map();

// ------------------------------------------------------------------ 参数

function parseArgs(argv) {
  const out = { host: '', port: DEFAULT_PORT, token: '', publicUrl: '', electron: '', dsh: '', cwd: process.cwd(), noOpen: false, listHosts: false, help: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const next = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`${a} 缺少参数`);
      return v;
    };
    if (a === '--host') out.host = next();
    else if (a === '--port') out.port = Number(next());
    else if (a === '--token') out.token = next();
    else if (a === '--public-url') out.publicUrl = next();
    else if (a === '--electron') out.electron = next();
    else if (a === '--dsh') out.dsh = next();
    else if (a === '--cwd') out.cwd = resolve(next());
    else if (a === '--no-open') out.noOpen = true;
    else if (a === '--list-hosts') out.listHosts = true;
    else if (a === '--help' || a === '-h') out.help = true;
    else throw new Error(`未知参数：${a}`);
  }
  if (!Number.isInteger(out.port) || out.port < 1 || out.port > 65535) throw new Error(`端口不合法：${out.port}`);
  return out;
}

const HELP = `
DSH 随身连 · 原生版主机 v${VERSION}

  node dsh-native-host.mjs [选项]

选项
  --host <IPv4>       绑定地址（默认自动选局域网；127.0.0.1 只给隧道用）
  --port <端口>       WebSocket 端口（默认 ${DEFAULT_PORT}）
  --token <令牌>      固定配对令牌（默认读取 ~/.dsh/dsh-pocket-token）
  --public-url <URL>  公网隧道地址，二维码用它（如 https://xxx.trycloudflare.com）
  --cwd <目录>        新会话默认工作目录
  --electron <路径>   DeepSeek Harness.exe
  --dsh <路径>        dsh CLI 的 bin.js
  --no-open           不自动打开扫码页
  --list-hosts        只列出本机局域网地址
`;

// ------------------------------------------------------------------ 地址

function scoreAddress(name, address) {
  let score = 0;
  if (/wi-?fi|wlan|无线|以太网|ethernet/i.test(name)) score += 4;
  if (/vethernet|vmware|virtualbox|hyper-v|wsl|docker|loopback|tailscale|zerotier/i.test(name)) score -= 8;
  if (address.startsWith('192.168.')) score += 3;
  else if (address.startsWith('10.')) score += 1;
  else if (/^172\.(1[6-9]|2\d|3[01])\./.test(address)) score += 1;
  if (address.startsWith('169.254.')) score -= 20;
  if (address.startsWith('100.')) score -= 2;
  return score;
}

function listLanAddresses() {
  const rows = [];
  for (const [name, list] of Object.entries(networkInterfaces())) {
    for (const item of list || []) {
      if (item.family !== 'IPv4' || item.internal) continue;
      rows.push({ name, address: item.address, score: scoreAddress(name, item.address) });
    }
  }
  rows.sort((a, b) => b.score - a.score || a.name.localeCompare(b.name));
  return rows;
}



function clientIp(req) {
  const direct = String(req.socket?.remoteAddress || '').replace(/^::ffff:/, '');
  const loop = direct === '127.0.0.1' || direct === '::1' || direct === '';
  if (loop) {
    const cf = req.headers['cf-connecting-ip'];
    if (typeof cf === 'string' && cf.trim()) return cf.trim();
    const xff = req.headers['x-forwarded-for'];
    if (typeof xff === 'string' && xff.trim()) return xff.split(',')[0].trim();
    const real = req.headers['x-real-ip'];
    if (typeof real === 'string' && real.trim()) return real.trim();
  }
  return direct || 'unknown';
}

function banRemaining(ip) {
  const s = authState.get(ip);
  if (!s) return 0;
  const left = s.bannedUntil - Date.now();
  if (left <= 0) { s.bannedUntil = 0; return 0; }
  return left;
}

function clearAuthFail(ip) {
  authState.delete(ip);
}

function recordAuthFail(ip) {
  const now = Date.now();
  let s = authState.get(ip);
  if (!s) { s = { fails: 0, first: now, bannedUntil: 0 }; authState.set(ip, s); }
  if (now - s.first > AUTH_FAIL_WINDOW_MS) { s.fails = 0; s.first = now; }
  s.fails += 1;
  if (s.fails >= MAX_AUTH_FAILS) {
    s.bannedUntil = now + BAN_MS;
    s.fails = 0;
    console.log(`  封禁 ${ip} 1 小时（10 次密钥错误）`);
  } else {
    console.log(`  密钥错误 ${ip}（${s.fails}/${MAX_AUTH_FAILS}）`);
  }
}

function resolveToken(argv) {
  if (argv.token.length > 0) {
    return { token: argv.token, source: '命令行 --token' };
  }
  const file = join(homedir(), '.dsh', 'dsh-pocket-token');
  try {
    if (existsSync(file)) {
      const saved = readFileSync(file, 'utf8').trim();
      if (/^[A-Za-z0-9_-]{32,128}$/.test(saved)) {
        return { token: saved, source: file };
      }
    }
  } catch {}
  const fresh = randomBytes(32).toString('hex');
  try {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, fresh + '\n', { mode: 0o600 });
  } catch {}
  return { token: fresh, source: file };
}

function normalizePublic(input, token) {
  let text = String(input || '').trim();
  if (!text) return '';
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(text)) text = 'wss://' + text;
  const match = /^(https?|wss?):\/\/([^/?#]+)([^#]*)/i.exec(text);
  if (!match) throw new Error(`--public-url 不是合法 URL：${input}`);
  let scheme = match[1].toLowerCase();
  if (scheme === 'https') scheme = 'wss';
  if (scheme === 'http') scheme = 'ws';
  let rest = match[3] || '';
  let query = '';
  const qi = rest.indexOf('?');
  if (qi >= 0) { query = rest.substring(qi); rest = rest.substring(0, qi); }
  if (!rest || rest === '/') rest = WS_PATH;
  if (!rest.startsWith(WS_PATH)) rest = WS_PATH;
  if (/[?&]token=/.test(query)) {
    query = query.replace(/([?&])token=[^&]*/, `$1token=${encodeURIComponent(token)}`);
  } else {
    query += (query ? '&' : '?') + 'token=' + encodeURIComponent(token);
  }
  return `${scheme}://${match[2]}${rest}${query}`;
}

function pickHost(requested) {
  if (requested === '127.0.0.1' || requested === 'localhost') {
    return { name: 'loopback', address: '127.0.0.1' };
  }
  const rows = listLanAddresses();
  if (rows.length === 0) throw new Error('没有找到局域网 IPv4 地址。');
  if (requested) {
    const hit = rows.find((r) => r.address === requested);
    if (!hit) throw new Error(`本机没有地址 ${requested}。可用：${rows.map((r) => r.address).join(', ')}`);
    return hit;
  }
  return rows[0];
}

// ------------------------------------------------------------------ 找 dsh

function candidateElectronPaths() {
  const out = [];
  if (process.env.DSH_ELECTRON) out.push(process.env.DSH_ELECTRON);
  if (isWindows) {
    const roots = [
      process.env.LOCALAPPDATA && join(process.env.LOCALAPPDATA, 'Programs'),
      process.env.ProgramFiles,
      process.env['ProgramFiles(x86)']
    ].filter(Boolean);
    for (const root of roots) out.push(join(root, 'DeepSeek Harness', 'DeepSeek Harness.exe'));
  }
  return out;
}

function resolveStartMenuShortcut() {
  if (!isWindows) return '';
  const links = [];
  if (process.env.APPDATA) links.push(join(process.env.APPDATA, 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'DeepSeek Harness.lnk'));
  if (process.env.ProgramData) links.push(join(process.env.ProgramData, 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'DeepSeek Harness.lnk'));
  for (const link of links) {
    if (!existsSync(link)) continue;
    const safe = link.replace(/'/g, "''");
    const ps = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', `(New-Object -ComObject WScript.Shell).CreateShortcut('${safe}').TargetPath`], { encoding: 'utf8', timeout: 8000, windowsHide: true });
    const target = (ps.stdout || '').trim();
    if (ps.status === 0 && target && existsSync(target)) return target;
  }
  return '';
}

function resolveDsh(argv) {
  if (argv.dsh) {
    const p = resolve(argv.dsh);
    if (!existsSync(p)) throw new Error(`找不到 --dsh 指定的文件：${p}`);
    return { kind: 'node', cli: p };
  }
  const probe = spawnSync(isWindows ? 'where' : 'which', ['dsh'], { encoding: 'utf8', windowsHide: true });
  if (probe.status === 0) {
    const first = (probe.stdout || '').split(/\r?\n/).map((s) => s.trim()).filter(Boolean)[0];
    if (first) return { kind: 'command', command: first };
  }
  let electron = argv.electron ? resolve(argv.electron) : '';
  if (electron && !existsSync(electron)) throw new Error(`找不到 --electron 指定的文件：${electron}`);
  if (!electron) {
    for (const p of candidateElectronPaths()) if (existsSync(p)) { electron = p; break; }
  }
  if (!electron) electron = resolveStartMenuShortcut();
  if (!electron) throw new Error('没有找到 DeepSeek Harness。请用 --electron 指定 "DeepSeek Harness.exe"。');
  const asar = join(dirname(electron), 'resources', 'app.asar');
  if (!existsSync(asar)) throw new Error(`找到了 ${electron}，但旁边没有 resources/app.asar。`);
  const cli = join(dirname(electron), 'resources', 'app.asar', 'dsh', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js');
  return { kind: 'electron', cli, electron };
}

// ------------------------------------------------------------------ 7z / 历史

function find7z() {
  const cands = [];
  if (process.env.SEVEN_ZIP) cands.push(process.env.SEVEN_ZIP);
  if (isWindows) {
    cands.push('C:\\Program Files\\7-Zip\\7z.exe', 'C:\\Program Files (x86)\\7-Zip\\7z.exe');
  }
  for (const p of cands) if (existsSync(p)) return p;
  const probe = spawnSync(isWindows ? 'where' : 'which', ['7z'], { encoding: 'utf8', windowsHide: true });
  if (probe.status === 0) {
    const first = (probe.stdout || '').split(/\r?\n/).map((s) => s.trim()).filter(Boolean)[0];
    if (first && existsSync(first)) return first;
  }
  return '';
}

const SEVEN_ZIP = find7z();
const historyCache = new Map();

function findSessionFile(sessionId) {
  const root = join(homedir(), '.dsh', 'sessions');
  if (!existsSync(root)) return '';
  let dirs = [];
  try {
    dirs = readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory());
  } catch {
    return '';
  }
  for (const d of dirs) {
    const p = join(root, d.name, sessionId, 'session.v4.jsonl.zstd');
    if (existsSync(p)) return p;
  }
  return '';
}

function readSessionText(file) {
  if (!SEVEN_ZIP) return '';
  const cache = historyCache.get(file);
  try {
    const stat = statSync(file);
    if (cache && cache.mtime === stat.mtimeMs) return cache.text;
    const out = spawnSync(SEVEN_ZIP, ['x', file, '-so'], { maxBuffer: 64 * 1024 * 1024, windowsHide: true });
    if (out.status !== 0 || !out.stdout) return '';
    const text = out.stdout.toString('utf8');
    historyCache.set(file, { mtime: stat.mtimeMs, text });
    return text;
  } catch {
    return '';
  }
}

function blocksText(blocks) {
  if (!Array.isArray(blocks)) return '';
  const parts = [];
  for (const b of blocks) {
    if (b && b.type === 'text' && typeof b.text === 'string') parts.push(b.text);
  }
  return parts.join('');
}

function parseHistory(sessionId, options = {}) {
  const file = findSessionFile(sessionId);
  if (!file) return { sessionId, title: '', cwd: '', messages: [], note: '找不到会话文件' };
  const text = readSessionText(file);
  if (!text) return { sessionId, title: '', cwd: '', messages: [], note: SEVEN_ZIP ? '会话解压失败' : '需要安装 7-Zip 才能回放历史' };

  const messages = [];
  let title = '';
  let cwd = '';
  const toolByCallId = new Map();

  const lines = text.split(String.fromCharCode(10));
  for (const line of lines) {
    if (!line.trim()) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.type === 'session') { cwd = o.cwd || ''; continue; }
    if (o.type === 'session/title') { title = o.data?.title || title; continue; }

    if (o.type === 'user/message') {
      if (o.data?.source?.kind !== 'user') continue;
      const body = blocksText(o.data?.content);
      if (body) messages.push({ role: 'user', text: body.slice(0, 20000), at: o.time || 0 });
      continue;
    }

    if (o.type === 'assistant/message') {
      const content = o.data?.message?.content || [];
      const body = blocksText(content);
      const reason = blocksText(content.filter((b) => b && b.type === 'reasoning'));
      if (body || reason) {
        messages.push({
          role: 'assistant',
          text: body.slice(0, 20000),
          reasoning: reason.slice(0, 20000),
          at: o.time || 0,
          usage: o.data?.usage || null
        });
      }
      continue;
    }

    if (o.type === 'tool/call') {
      const callId = o.data?.callId || '';
      const tool = {
        role: 'tool',
        toolName: o.data?.name || 'tool',
        args: typeof o.data?.arguments === 'string' ? o.data.arguments.slice(0, 4000) : '',
        text: '',
        callId,
        at: o.time || 0,
        status: 'running'
      };
      toolByCallId.set(callId, tool);
      messages.push(tool);
      continue;
    }

    if (o.type === 'tool/result') {
      const callId = o.data?.toolCallId || o.data?.message?.toolCallId || '';
      const body = blocksText(o.data?.message?.content || []);
      const tool = toolByCallId.get(callId);
      if (tool) {
        tool.text = body.slice(0, 12000);
        tool.status = 'done';
      } else {
        messages.push({ role: 'tool', toolName: 'tool', args: '', text: body.slice(0, 12000), callId, at: o.time || 0, status: 'done' });
      }
    }
  }

  const all = messages.slice(-200);
  const limit = Number.isInteger(options.limit) && options.limit > 0 ? Math.min(options.limit, 100) : 0;
  if (limit === 0) {
    return { sessionId, title, cwd, messages: all, note: '', before: 0, hasMore: false, total: all.length };
  }
  let end = Number.isInteger(options.before) ? options.before : all.length;
  end = Math.max(0, Math.min(end, all.length));
  const start = Math.max(0, end - limit);
  return {
    sessionId,
    title,
    cwd,
    messages: all.slice(start, end),
    note: '',
    before: start,
    hasMore: start > 0,
    total: all.length
  };
}


function workspaceFile() {
  return join(homedir(), '.dsh', 'storages', 'workspace.json');
}

function readWorkspaceState() {
  const file = workspaceFile();
  if (!existsSync(file)) {
    return { workspaces: [], archived: [], pinned: [], defaultWorkspaceId: '', note: 'workspace.json 不存在' };
  }
  try {
    const data = JSON.parse(readFileSync(file, 'utf8'));
    const tables = data.tables && data.tables.workspaces ? data.tables.workspaces : {};
    const ids = Array.isArray(data.global?.workspaceIds) ? data.global.workspaceIds : Object.keys(tables);
    const workspaces = [];
    for (const id of ids) {
      const w = tables[id];
      if (!w) continue;
      workspaces.push({
        id,
        title: typeof w.title === 'string' ? w.title : '',
        path: typeof w.path === 'string' ? w.path : '',
        sessionIds: Array.isArray(w.sessionIds) ? w.sessionIds.slice() : []
      });
    }
    return {
      workspaces,
      archived: Array.isArray(data.global?.archivedSessionIds) ? data.global.archivedSessionIds.slice() : [],
      pinned: Array.isArray(data.global?.pinnedSessionIds) ? data.global.pinnedSessionIds.slice() : [],
      defaultWorkspaceId: typeof data.global?.defaultWorkspaceId === 'string' ? data.global.defaultWorkspaceId : '',
      note: ''
    };
  } catch (e) {
    return { workspaces: [], archived: [], pinned: [], defaultWorkspaceId: '', note: `workspace.json 解析失败：${e.message}` };
  }
}

function archiveSession(sessionId, archived) {
  const file = workspaceFile();
  if (!existsSync(file)) throw new Error('workspace.json 不存在');
  const data = JSON.parse(readFileSync(file, 'utf8'));
  if (!data.global || typeof data.global !== 'object') data.global = {};
  const list = Array.isArray(data.global.archivedSessionIds) ? data.global.archivedSessionIds.slice() : [];
  const set = new Set(list);
  if (archived) set.add(sessionId); else set.delete(sessionId);
  data.global.archivedSessionIds = Array.from(set);
  const backup = file + '.dshpocket.bak';
  try { if (!existsSync(backup)) copyFileSync(file, backup); } catch {}
  const tmp = file + '.dshpocket.tmp';
  writeFileSync(tmp, JSON.stringify(data, null, 2) + '\n', 'utf8');
  try { renameSync(tmp, file); }
  catch (e) { writeFileSync(file, JSON.stringify(data, null, 2) + '\n', 'utf8'); try { unlinkSync(tmp); } catch {} }
  return Array.from(set);
}

function sessionTitle(sessionId) {
  const file = findSessionFile(sessionId);
  if (!file) return '';
  const text = readSessionText(file);
  if (!text) return '';
  const lines = text.split(String.fromCharCode(10));
  for (const line of lines) {
    if (!line.trim()) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.type === 'session/title' && o.data && typeof o.data.title === 'string') return o.data.title;
  }
  return '';
}

// ------------------------------------------------------------------ WebSocket 服务

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function sendFrame(socket, text) {
  if (socket.destroyed) return;
  const payload = Buffer.from(text, 'utf8');
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x81, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81; header[1] = 126; header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81; header[1] = 127; header.writeBigUInt64BE(BigInt(len), 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

function sendPing(socket) {
  if (socket.destroyed) return;
  socket.write(Buffer.from([0x89, 0x00]));
}

function closeFrame(socket, code = 1000) {
  if (socket.destroyed) return;
  const buf = Buffer.alloc(4);
  buf[0] = 0x88; buf[1] = 2; buf.writeUInt16BE(code, 2);
  socket.write(buf);
}

function attachWsFrames(socket, onMessage, onClose) {
  let buf = Buffer.alloc(0);
  let frag = '';
  socket.on('data', (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    while (buf.length >= 2) {
      const b0 = buf[0], b1 = buf[1];
      const fin = (b0 & 0x80) !== 0;
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f;
      let off = 2;
      if (len === 126) {
        if (buf.length < 4) return;
        len = buf.readUInt16BE(2); off = 4;
      } else if (len === 127) {
        if (buf.length < 10) return;
        const big = buf.readBigUInt64BE(2);
        if (big > BigInt(64 * 1024 * 1024)) { closeFrame(socket, 1009); socket.end(); return; }
        len = Number(big); off = 10;
      }
      let mask = null;
      if (masked) {
        if (buf.length < off + 4) return;
        mask = buf.subarray(off, off + 4); off += 4;
      }
      if (buf.length < off + len) return;
      let payload = buf.subarray(off, off + len);
      buf = buf.subarray(off + len);
      if (masked) {
        const p = Buffer.allocUnsafe(len);
        for (let i = 0; i < len; i++) p[i] = payload[i] ^ mask[i % 4];
        payload = p;
      }
      if (opcode === 0x1 || opcode === 0x0) {
        if (opcode === 0x1) frag = '';
        frag += payload.toString('utf8');
        if (fin) { const msg = frag; frag = ''; onMessage(msg); }
      } else if (opcode === 0x8) {
        onClose();
        socket.end();
        return;
      } else if (opcode === 0x9) {
        socket.write(Buffer.from([0x8a, 0x00]));
      }
    }
  });
}

// ------------------------------------------------------------------ 主流程

async function main() {
  const argv = parseArgs(process.argv.slice(2));
  if (argv.help) { console.log(HELP); return; }
  if (argv.listHosts) {
    for (const r of listLanAddresses()) console.log(`${r.address}\t${r.name}`);
    return;
  }

  const chosen = pickHost(argv.host);
  const dsh = resolveDsh(argv);
  const tokenInfo = resolveToken(argv);
  const token = tokenInfo.token;
  const publicUrl = argv.publicUrl.length > 0 ? normalizePublic(argv.publicUrl, token) : '';

  const acpEnv = { ...process.env, ELECTRON_RUN_AS_NODE: '1' };
  let acpCmd;
  let acpArgs;
  if (dsh.kind === 'command') {
    acpCmd = dsh.command; acpArgs = ['--profile', 'acp'];
    delete acpEnv.ELECTRON_RUN_AS_NODE;
  } else if (dsh.kind === 'electron') {
    acpCmd = dsh.electron; acpArgs = [dsh.cli, '--profile', 'acp'];
  } else {
    acpCmd = process.execPath; acpArgs = [dsh.cli, '--profile', 'acp'];
    delete acpEnv.ELECTRON_RUN_AS_NODE;
  }

  console.log(`DSH 随身连 · 原生版主机 v${VERSION}`);
  console.log(`  电脑地址：${chosen.address} (${chosen.name})`);
  console.log(`  工作目录：${argv.cwd}`);
  console.log(`  固定令牌：${tokenInfo.source}`);
  console.log(`  连接上限：${MAX_CLIENTS}；密钥错误 ${MAX_AUTH_FAILS} 次封禁 1 小时`);
  console.log(`  正在启动 ACP 服务…`);

  const acp = spawn(acpCmd, acpArgs, { cwd: argv.cwd, env: acpEnv, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });

  let client = null;
  let clientSeq = 0;
  let stopped = false;
  let server = null;

  const stop = (code = 0) => {
    if (stopped) return;
    stopped = true;
    try { closeFrame(client?.socket); } catch {}
    try { acp.kill(); } catch {}
    if (isWindows && acp.pid) spawnSync('taskkill', ['/pid', String(acp.pid), '/T', '/F'], { windowsHide: true, stdio: 'ignore' });
    if (server) server.close();
    setTimeout(() => process.exit(code), 120);
  };
  process.on('SIGINT', () => stop(0));
  process.on('SIGTERM', () => stop(0));

  // ACP -> 手机
  let outBuf = '';
  acp.stdout.setEncoding('utf8');
  acp.stdout.on('data', (chunk) => {
    outBuf += chunk;
    const lines = outBuf.split(/\r?\n/);
    outBuf = lines.pop() || '';
    for (const line of lines) {
      const text = line.trim();
      if (!text) continue;
      let msg;
      try { msg = JSON.parse(text); } catch { console.log(`  acp | ${text.slice(0, 300)}`); continue; }
      if (client && !client.socket.destroyed) sendFrame(client.socket, JSON.stringify(msg));
    }
  });
  acp.stderr.setEncoding('utf8');
  acp.stderr.on('data', (d) => {
    const s = d.toString().trim();
    if (s) console.log(`  acp ! ${s.slice(0, 400)}`);
  });
  acp.on('exit', (code, signal) => {
    console.log(`ACP 退出 code=${code} signal=${signal}`);
    if (client && !client.socket.destroyed) {
      sendFrame(client.socket, JSON.stringify({ jsonrpc: '2.0', method: 'phone/closed', params: { reason: `ACP 退出（${code ?? signal}）` } }));
    }
    stop(code ?? 1);
  });

  // 手机 -> ACP
  function handleClientMessage(text) {
    let msg;
    try { msg = JSON.parse(text); } catch { return; }
    if (msg.method === 'phone/info') {
      const result = { cwd: argv.cwd, home: homedir(), platform: process.platform, bridgeVersion: VERSION };
      if (client) sendFrame(client.socket, JSON.stringify({ jsonrpc: '2.0', id: msg.id, result }));
      return;
    }
    if (msg.method === 'phone/history') {
      const sessionId = msg.params?.sessionId || '';
      const limit = Number(msg.params?.limit);
      const before = Number(msg.params?.before);
      const result = parseHistory(sessionId, {
        limit: Number.isInteger(limit) ? limit : 0,
        before: Number.isInteger(before) ? before : undefined
      });
      if (client) sendFrame(client.socket, JSON.stringify({ jsonrpc: '2.0', id: msg.id, result }));
      return;
    }
    if (msg.method === 'phone/workspaces') {
      const result = readWorkspaceState();
      if (client) sendFrame(client.socket, JSON.stringify({ jsonrpc: '2.0', id: msg.id, result }));
      return;
    }
    if (msg.method === 'phone/archive') {
      const sessionId = msg.params?.sessionId || '';
      const archived = msg.params?.archived === true;
      if (!sessionId) {
        if (client) sendFrame(client.socket, JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32602, message: 'missing sessionId' } }));
        return;
      }
      try {
        const archivedIds = archiveSession(sessionId, archived);
        if (client) sendFrame(client.socket, JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: { archived: archivedIds, sessionId, hidden: archived } }));
      } catch (e) {
        if (client) sendFrame(client.socket, JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32000, message: e.message } }));
      }
      return;
    }
    if (msg.method === 'phone/titles') {
      const ids = Array.isArray(msg.params?.sessionIds) ? msg.params.sessionIds : [];
      const titles = [];
      for (const id of ids.slice(0, 60)) {
        if (typeof id !== 'string' || !id) continue;
        const title = sessionTitle(id);
        if (title) titles.push({ sessionId: id, title });
      }
      if (client) sendFrame(client.socket, JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: { titles } }));
      return;
    }
    acp.stdin.write(JSON.stringify(msg) + '\n');
  }

  server = createServer((req, res) => {
    const url = new URL(req.url || '/', 'http://127.0.0.1');
    if (url.pathname === '/shutdown' && req.method === 'POST') {
      if (url.searchParams.get('key') !== token) {
        res.writeHead(403); res.end('forbidden'); return;
      }
      res.writeHead(200); res.end('stopping'); stop(0); return;
    }
    if (url.pathname === '/' || url.pathname === '/index.html') {
      if (publicUrl.length > 0 && url.searchParams.get('key') !== token) {
        const ip = clientIp(req);
        if (banRemaining(ip) > 0) {
          res.writeHead(403); res.end('banned'); return;
        }
        recordAuthFail(ip);
        res.writeHead(403); res.end('forbidden'); return;
      }
      const wsUrl = publicUrl.length > 0 ? publicUrl : `ws://${chosen.address}:${port}${WS_PATH}?token=${token}`;
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.end(controlPage(wsUrl, publicUrl.length > 0 ? '公网隧道' : chosen.address, port, token, publicUrl.length > 0));
      return;
    }
    res.writeHead(404); res.end('not found');
  });

  server.on('upgrade', (req, socket) => {
    const url = new URL(req.url || '/', 'http://127.0.0.1');
    const ip = clientIp(req);
    if (banRemaining(ip) > 0) {
      socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    if (url.pathname !== WS_PATH || url.searchParams.get('token') !== token) {
      recordAuthFail(ip);
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    clearAuthFail(ip);
    if (client) {
      try { closeFrame(client.socket, 1001); client.socket.destroy(); } catch {}
      console.log(`  替换旧连接（上限 ${MAX_CLIENTS}）`);
    }
    const key = req.headers['sec-websocket-key'];
    if (!key) { socket.destroy(); return; }
    const accept = createHash('sha1').update(key + WS_GUID).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);

    const id = ++clientSeq;
    client = { id, socket };
    console.log(`  手机已连接（#${id}, ${ip}）`);

    attachWsFrames(socket, (text) => handleClientMessage(text), () => {
      if (client && client.id === id) client = null;
      console.log(`  手机断开（#${id}）`);
    });
    socket.on('error', () => { if (client && client.id === id) client = null; });
    socket.on('close', () => { if (client && client.id === id) client = null; });
    sendFrame(socket, JSON.stringify({ jsonrpc: '2.0', method: 'phone/hello', params: { version: VERSION, cwd: argv.cwd } }));
  });

  let port = argv.port;
  const listen = (p) => new Promise((done, fail) => {
    const onError = (err) => { server.off('listening', onListening); fail(err); };
    const onListening = () => { server.off('error', onError); done(); };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(p, chosen.address);
  });
  for (let i = 0; i < 12; i++) {
    try { await listen(port); break; }
    catch (e) {
      if (e.code !== 'EADDRINUSE' || i === 11) throw e;
      port++;
    }
  }
  console.log(`  局域网：  ws://${chosen.address}:${port}${WS_PATH}?token=${token}`);
  if (publicUrl.length > 0) {
    console.log(`  公网：    ${publicUrl}`);
  }
  console.log(`  扫码页：  http://127.0.0.1:${server.address().port}/?key=${token}`);
  console.log('  保持本窗口开着；按 Ctrl+C 停止。');

  if (!argv.noOpen) {
    const url = `http://127.0.0.1:${server.address().port}/?key=${token}`;
    try {
      if (isWindows) spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
      else if (process.platform === 'darwin') spawn('open', [url], { detached: true, stdio: 'ignore' }).unref();
      else spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref();
    } catch {}
  }

  setInterval(() => { if (client) sendPing(client.socket); }, 25000).unref?.();
  setInterval(() => {
    if (!client) return;
    try {
      sendFrame(client.socket, JSON.stringify({ jsonrpc: '2.0', method: 'phone/ping', params: { t: Date.now() } }));
    } catch {}
  }, 3000).unref?.();
}

function controlPage(wsUrl, host, port, key, isPublic) {
  const qr = makeQrSvg(wsUrl);
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>DSH 随身连 · 原生主机</title>
<style>
:root{--paper:#f4efe4;--ink:#17191d;--muted:#6d6a61;--line:#d8d0bf;--accent:#c2410c}
*{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.55 "HarmonyOS Sans SC","Microsoft YaHei",system-ui,sans-serif}
.wrap{max-width:820px;margin:0 auto;padding:48px 28px 64px}.eyebrow{font:600 11px/1.2 ui-monospace,Consolas,monospace;letter-spacing:.22em;color:var(--accent)}
h1{margin:10px 0 6px;font-size:clamp(28px,5vw,44px);line-height:1.08;letter-spacing:-.02em}.lead{margin:0 0 30px;color:var(--muted);max-width:56ch}
.grid{display:grid;grid-template-columns:1fr 300px;gap:28px;border-top:2px solid var(--ink);padding-top:24px}@media(max-width:720px){.grid{grid-template-columns:1fr}}
.qr{background:#fff;border:1px solid var(--line);padding:12px;max-width:300px;line-height:0}.qr svg{width:100%;height:auto;display:block}
.steps{margin:0;padding:0;list-style:none;counter-reset:s}.steps li{counter-increment:s;position:relative;padding:0 0 18px 42px;border-bottom:1px solid var(--line);margin-bottom:18px}
.steps li:last-child{border-bottom:0;margin-bottom:0}.steps li:before{content:counter(s,decimal-leading-zero);position:absolute;left:0;top:1px;font:600 12px/1.4 ui-monospace,Consolas,monospace;color:var(--accent)}
.steps b{display:block;margin-bottom:2px}.steps span{color:var(--muted)}
.urlbox{margin-top:26px;border:1px solid var(--line);background:#fffdf8;padding:12px 14px}.urlbox code{font:12px/1.5 ui-monospace,Consolas,monospace;word-break:break-all}
button{font:600 13px/1 "HarmonyOS Sans SC",system-ui,sans-serif;border:1px solid var(--ink);background:var(--ink);color:#fff8ef;padding:10px 14px;cursor:pointer}
.foot{margin-top:26px;font-size:12px;color:var(--muted)}.meta{display:flex;gap:20px;margin-top:24px;font:12px/1.5 ui-monospace,Consolas,monospace;color:var(--muted)}
</style></head><body><div class="wrap"><div class="eyebrow">DSH / POCKET · NATIVE HOST v${VERSION}</div><h1>用手机扫一下</h1>
<p class="lead">${isPublic ? '公网隧道模式：二维码是公网 wss 地址。手机不用和电脑同一个 Wi-Fi；token 仍然是唯一门禁，别外传。' : '原生版不再加载网页。手机通过 WebSocket 直接连 ACP；二维码里是配对地址和 token，只在局域网内有效。'}</p>
<div class="grid"><div><ol class="steps">
<li><b>${isPublic ? '手机用任意网络' : '手机连同一个 Wi-Fi'}</b><span>${isPublic ? '不需要和电脑同一个 Wi-Fi；隧道出口在公网。' : `电脑在 ${esc(host)}。`}</span></li>
<li><b>打开「DSH 随身连」</b><span>点「扫码连接」，对准右边二维码。</span></li>
<li><b>保持本窗口开着</b><span>关掉终端，手机会断开。</span></li>
</ol><div class="urlbox"><code>${esc(wsUrl)}</code></div>
<div class="meta"><span>端口 <b>${port}</b></span><span>${isPublic ? '公网隧道' : '仅局域网'}</span></div>
<div class="foot">${isPublic ? '公网模式：token 泄露等于电脑上的 agent 被接管；用完请关掉隧道。' : '二维码含 token，不要截图外传。手机端只执行 ACP；工具仍在本机运行。'}</div></div>
<div><div class="qr">${qr}</div></div></div>
<div style="margin-top:30px"><button id="stop">停止主机</button></div></div>
<script>document.getElementById('stop').onclick=async()=>{if(!confirm('停止后手机会断开，确定？'))return;await fetch('/shutdown?key=${encodeURIComponent(key)}',{method:'POST'});document.body.innerHTML='<div class="wrap"><h1>已停止</h1></div>';};</script>
</body></html>`;
}

function makeQrSvg(text) {
  const qrPath = join(HERE, 'vendor', 'qrcode.js');
  const code = readFileSync(qrPath, 'utf8');
  const mod = { exports: {} };
  new Function('module', 'exports', code)(mod, mod.exports);
  const qrcode = mod.exports;
  const qr = qrcode(0, 'M');
  qr.addData(text);
  qr.make();
  return qr.createSvgTag({ cellSize: 5, margin: 4, scalable: true });
}

main().catch((err) => {
  console.error(`出错了：${err.message}`);
  process.exit(1);
});
