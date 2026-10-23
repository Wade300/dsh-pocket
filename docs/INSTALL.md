# Install

## Prerequisites

| Part | Requirement |
| --- | --- |
| PC bridge | Node.js 22+, DeepSeek Harness installed and logged in |
| History replay | 7-Zip on `PATH` (the bridge calls `7z`) |
| Phone | HarmonyOS NEXT / API 12+ |
| Build | DevEco Studio with the HarmonyOS SDK and your own signing certificate |

## 1. Start the bridge

Clone the repository and run:

```bash
node host/dsh-native-host.mjs --port 3090
```

Windows: double-click `host\start-native-host.cmd`, or run the command above from a normal terminal.

The first run creates a fixed token:

```text
~/.dsh/dsh-pocket-token
```

The bridge prints:

- LAN WebSocket URL, e.g. `ws://192.168.1.10:3090/ws?token=...`
- QR page, e.g. `http://192.168.1.10:3090/?key=...`
- public URL if `--public-url` is supplied

Keep the bridge window open. `Ctrl+C` stops it.

Useful options:

```text
--host <addr>        bind address
--port <port>        default 3090
--public-url <url>   public tunnel URL; binds loopback and uses wss://
--token <value>      fixed token; otherwise read/create ~/.dsh/dsh-pocket-token
--no-open            do not open the QR page
--list-hosts         print local IPv4 addresses and exit
--help               full help
```

## 2. Build the app

1. Open the `harmony/` directory in DevEco Studio.
2. **File → Project Structure → Signing Configs**: configure a signing profile with your Huawei developer account.
3. Select the `entry` module and build a debug or release HAP.
4. The unsigned output is under `entry/build/default/outputs/default/`. Sign it in DevEco Studio if needed.

Command-line helper:

```bat
scripts\build-hap.cmd
```

It uses `DEVECO_HOME` (or the default DevEco Studio install path) and needs `DEVECO_HOME\sdk` and `DEVECO_HOME\tools\node`. It copies the project to a temporary ASCII path because hvigor rejects some non-ASCII project paths.

The app requests only `ohos.permission.INTERNET`.

## 3. Install

With `hdc`:

```bash
hdc install -r entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.example.dshpocket
```

Or use DevEco Studio's Run button.

## 4. Connect

1. Put the phone and PC on the same Wi-Fi.
2. Enter the LAN URL printed by the bridge, or tap **扫码连接** and scan the QR page.
3. Wait for the session list.

The URL is saved after the first successful connection. The next app launch reconnects automatically and restores the last window from its local cache.

### Remote access

Use a TLS tunnel (Cloudflare Tunnel, ngrok, a VPS reverse proxy, etc.):

```bash
node host/dsh-native-host.mjs --host 127.0.0.1 --port 3090 \
  --public-url https://your-tunnel.example.com
```

Connect the app to:

```text
wss://your-tunnel.example.com/ws?token=<token>
```

Do not expose `ws://` directly. See `SECURITY.md`.

## 5. Session folders and hidden sessions

The phone reads:

```text
~/.dsh/storages/workspace.json
```

- `workspaces` supplies folder names and membership.
- `archivedSessionIds` supplies hidden sessions.

Long-press a session to hide/unhide it. The bridge writes the file and keeps `workspace.json.dshpocket.bak` before the first write. The DSH UI sees the change after a refresh; the phone sees PC changes after **刷新**.

## 6. Rotate the token

Delete the token file and restart the bridge:

```bash
rm ~/.dsh/dsh-pocket-token
node host/dsh-native-host.mjs --port 3090
```

Then update the phone's saved URL (or scan the new QR code). The old token stops working immediately.

## 7. Update

- Pull the repository.
- Rebuild/reinstall the HAP.
- Restart the bridge.

The app keeps its cached last window and saved URL across normal upgrades. Uninstalling the app clears its Preferences cache.
