# DSH Pocket · 随身连

Native HarmonyOS client for DeepSeek Harness (DSH), written in ArkTS/ArkUI. No WebView.

The phone talks to a small Node bridge over WebSocket. The bridge speaks ACP JSON-RPC to `dsh --profile acp` on the PC, so the phone can list sessions, stream replies, show tool cards and answer permission requests.

> Status: experimental. Tested on HarmonyOS NEXT (API 26) and a foldable phone. Expect rough edges.

[使用手册](docs/USAGE.md) · [安装](docs/INSTALL.md) · [架构](docs/ARCHITECTURE.md) · [排错](docs/TROUBLESHOOTING.md) · [安全](SECURITY.md)

## Features

- Native ArkUI chat, no embedded browser.
- Session list, resume, new session, model selection.
- Streaming Markdown: headings, lists, quotes, fenced code, tables, inline styles and links.
- Tool calls as cards, permission prompts, usage line.
- Copy a message, quote a reply, edit a sent prompt, copy code blocks.
- Session search and timestamps.
- History pagination: first open loads the latest 10 messages; scroll to the top for older pages.
- Last opened window and its latest 10 messages are cached locally; after a restart the window comes back before the network is ready.
- Auto-connect to the last working URL after the first successful connection.
- Session folders and hidden sessions follow the PC's `~/.dsh/storages/workspace.json`.
  Long-press a session to hide or unhide it; the change is written back to the PC file.
- Tri-fold layout: compact rail, medium split view, expanded list + chat.
- Fixed bridge token, one active connection, 10 bad tokens from one IP bans it for an hour.

## How it works

```
┌──────────────────────┐        WebSocket / JSON-RPC        ┌──────────────────────┐
│  HarmonyOS app       │  ws:// or wss:// .../ws?token=...  │  Node bridge         │
│  ArkTS + ArkUI       │ ─────────────────────────────────► │  dsh-native-host.mjs │
└──────────────────────┘                                    └──────────┬───────────┘
                                                                       │ stdio JSON-RPC (ACP)
                                                                       ▼
                                                            ┌──────────────────────┐
                                                            │  dsh --profile acp   │
                                                            │  DeepSeek Harness    │
                                                            └──────────────────────┘
```

The bridge adds a few private methods on top of ACP:

| Method | Purpose |
| --- | --- |
| `phone/hello` | Bridge version and working directory |
| `phone/info` | Default cwd and platform |
| `phone/history` | Replay a session log, with `limit` / `before` pagination |
| `phone/titles` | Read titles from session logs |
| `phone/workspaces` | Read workspace folders and hidden sessions |
| `phone/archive` | Hide or unhide a session, written back to `workspace.json` |

ACP methods used by the app: `initialize`, `session/list`, `session/new`, `session/resume`, `session/set_config_option`, `session/prompt`, `session/cancel`, plus `session/update` notifications.

## Requirements

- PC: Node.js 22 or newer; DeepSeek Harness installed and logged in; 7-Zip on `PATH` for history replay (optional but recommended).
- Phone: HarmonyOS NEXT / API 12 or newer. The project uses compile SDK 26 and target API 12.
- Build: DevEco Studio with the HarmonyOS SDK. Signing is done with your own Huawei developer certificate.
- Network: phone and PC on the same LAN, or a TLS tunnel for remote use.

## Quick start

### 1. Start the PC bridge

From the repository root:

```bash
node host/dsh-native-host.mjs --port 3090
```

On Windows you can double-click `host\start-native-host.cmd`.

The bridge prints a LAN URL, a public URL when configured, and a QR page. The fixed token is stored at:

```text
~/.dsh/dsh-pocket-token
```

Delete that file to rotate the token, or pass `--token <value>`.

Options:

```text
--host <addr>          bind address (default: auto-detected LAN address)
--port <port>          default 3090
--public-url <url>     public tunnel URL; forces loopback binding and wss://
--token <value>        fixed token (default: read/create ~/.dsh/dsh-pocket-token)
--no-open              do not open the QR page in a browser
--list-hosts           list local IPv4 addresses and exit
```

### 2. Build and install the app

1. Open `harmony/` in DevEco Studio.
2. Configure signing: **File → Project Structure → Signing Configs**, use your Huawei account.
3. Build the `entry` module (debug or release) and install the HAP.

The app only requests `ohos.permission.INTERNET`.

### 3. Connect

Use the URL printed by the bridge, for example:

```text
ws://192.168.1.10:3090/ws?token=<token>
```

You can also open the QR page on the PC (`http://<pc-ip>:3090/?key=<token>`) and scan it from the app.

After the first successful connection the URL is saved; the next launch reconnects automatically.

### 4. Remote access (optional)

Do not expose the bridge directly to the internet. Put a TLS tunnel in front of it and bind the bridge to loopback:

```bash
node host/dsh-native-host.mjs --host 127.0.0.1 --port 3090 \
  --public-url https://your-tunnel.example.com
```

Then connect the app to:

```text
wss://your-tunnel.example.com/ws?token=<token>
```

In public mode the control page at `/` also requires `?key=<token>`.

## Security

The bridge token is powerful: it allows the paired phone to drive a DSH agent that can run tools on the PC. Treat it like an SSH key.

- Keep the token out of screenshots, logs and repositories.
- Prefer a TLS tunnel; do not port-forward plain `ws://` to the internet.
- The bridge accepts one active WebSocket; a new valid connection replaces the old one.
- Ten bad tokens from one IP within ten minutes ban that IP for an hour. Bans are in memory and clear on restart.
- Public mode protects `/` with the same token; `/ws` always requires it.
- `phone/archive` writes `~/.dsh/storages/workspace.json`; the bridge keeps a one-time `.dshpocket.bak` backup. Do not run it against a workspace file you cannot restore.
- This project is not audited. Review the code before exposing it.

See [SECURITY.md](SECURITY.md) for details.

## Limitations

- ACP exposes a subset of DSH. Images/attachments, terminal, file tree, preview and plan views are not available.
- History replay is capped at the latest 200 messages per session; the app pages 10 at a time.
- The window cache stores at most 10 messages, with per-message truncation. It is a convenience, not an offline archive.
- Folder/hidden sync is pull-based: the phone reads the PC file on refresh, and writes hide/unhide back. It is not a live push channel. Concurrent writes follow last-write-wins.
- The bridge parses the full session log before slicing a page; very large logs can still be slow on first open.
- HarmonyOS WebSocket behavior differs across versions. The app adds `ngrok-skip-browser-warning` to the handshake for ngrok free tunnels.

## Project layout

```text
harmony/                 HarmonyOS app (ArkTS, Stage model)
  AppScope/              bundle metadata
  entry/src/main/ets/    pages, ACP client, Markdown renderer, storage
host/
  dsh-native-host.mjs    Node bridge, WebSocket server, history and workspace APIs
  start-native-host.cmd  Windows launcher
  vendor/qrcode.js       QR rendering (MIT, see vendor/NOTICE.txt)
scripts/build-hap.cmd    command-line build helper
docs/                    usage, install, architecture and troubleshooting
```

## License

MIT. See [LICENSE](LICENSE).

DeepSeek Harness and its marks belong to their respective owners. This is an independent client, not an official DeepSeek project.
