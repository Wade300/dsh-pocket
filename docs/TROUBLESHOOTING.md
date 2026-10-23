# Troubleshooting

## The app cannot connect

Check, in order:

1. Bridge is running and the window is still open.
2. Phone and PC are on the same network (or the tunnel is up).
3. The URL includes `/ws?token=...`; the token matches the file or `--token`.
4. `ping <pc-ip>` from the phone works.
5. The PC firewall allows the bridge port on the private network.

### `HTTP 401` / `401 Unauthorized`

The token is wrong or missing. Read the current token on the PC:

```bash
cat ~/.dsh/dsh-pocket-token
```

Update the phone URL, or delete the token file and restart the bridge, then scan the new QR.

### `HTTP 403` / `403 Forbidden`

The IP is banned after 10 bad tokens in 10 minutes. Wait an hour or restart the bridge (bans are in memory).

### `WebSocket 错误 200`

`200` is a HarmonyOS WebSocket error code, not an HTTP status. Check:

- Wi-Fi actually has an IP (`ifconfig wlan0` shows `inet addr:` and `RUNNING`);
- the phone is not on cellular while using a LAN URL;
- the bridge is reachable from the phone browser;
- if using a free ngrok tunnel, the app's `ngrok-skip-browser-warning` header is present (it is in current builds);
- if using a tunnel, the tunnel forwards to the bridge's actual port and the bridge is bound to the interface the tunnel reaches.

### `连不上` / timeout

- Try the LAN URL first; only then the tunnel.
- Restart the bridge and confirm it prints a URL.
- For a tunnel, test `curl https://.../` from the PC and `wss://.../ws?token=...` with a WebSocket client.
- Keep the tunnel process alive; free tunnel hostnames often change after a restart.

### `429 Too Many Requests`

Current builds replace the old connection instead of returning 429. If you see 429, you are running an older bridge; update it.

## Session issues

### `Invalid params: unknown session`

The phone holds a session ID that the current ACP process does not know, usually after the bridge/DSH restarted. Current builds disable sending and show a notice. Fix:

- tap **刷新** and reopen the session; or
- create a new session.

### History is empty or `需要安装 7-Zip`

Install 7-Zip and make sure `7z` is on `PATH`, then restart the bridge. The bridge reads `session.v4.jsonl.zstd`; it cannot replay without a decompressor.

### History opens slowly

The bridge decompresses the entire log before returning a page. Large sessions can take seconds. This is a known limitation; the app only transfers 10 messages per page.

### `会话未就绪` and the send button is disabled

`session/resume` failed or has not finished. Tap **刷新**, reopen the session, or create a new one. The cached history remains readable.

## Folder / hidden sync

- The phone reads `~/.dsh/storages/workspace.json` on **刷新**.
- Long-press a session to hide/unhide; the bridge writes `archivedSessionIds` and keeps `workspace.json.dshpocket.bak`.
- The DSH UI may need a page refresh to see external changes.
- If both sides write at the same time, the last writer wins. Restore from the backup only when DSH is not running.

## Window cache

- The cache is written after a session is opened and its history is loaded.
- On launch the app shows `last_chat` immediately, then reconnects.
- If the cached session cannot be resumed, the window stays read-only.
- The cache is limited to 10 messages and truncates long text. Uninstalling the app clears it.

## Logo / QR page

- The QR page is at `http://<pc-ip>:<port>/?key=<token>` in public mode and `http://<pc-ip>:<port>/` on a LAN.
- If the page loads but the phone scanner cannot connect, check the tunnel/URL and regenerate the QR after changing the port.

## Logs

The bridge prints connection, auth, ACP and model events to the terminal. The app logs ACP requests/responses to `hilog` under `com.example.dshpocket`.

Do not paste tokens, session logs or full prompts into a public issue.
