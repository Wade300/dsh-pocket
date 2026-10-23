# Architecture

## Components

```text
HarmonyOS app (ArkTS)
  ├─ UI: Index.ets, Markdown.ets
  ├─ ACP client: WebSocket + JSON-RPC
  └─ local cache: Preferences
            │
            │ ws:// or wss://  /ws?token=...
            ▼
Node bridge (host/dsh-native-host.mjs)
  ├─ HTTP control page + QR
  ├─ WebSocket server, auth, ban, single active client
  ├─ ACP process: dsh --profile acp (stdio JSON-RPC)
  ├─ history replay: session.v4.jsonl.zstd via 7z
  └─ workspace state: ~/.dsh/storages/workspace.json
            │
            ▼
DeepSeek Harness agent + tools
```

The phone never talks to DSH directly. The bridge owns the ACP process and translates a few phone-specific requests.

## Handshake

1. Phone opens `ws(s)://.../ws?token=...`.
2. Bridge validates the token, then sends:
   ```json
   {"jsonrpc":"2.0","method":"phone/hello","params":{"version":"2.0.0","cwd":"..."}}
   ```
3. Phone sends ACP `initialize` with `protocolVersion: 1`.
4. Phone lists sessions with `session/list`.
5. Opening a session:
   - `phone/history` with `limit: 10` for the latest page;
   - `session/resume` to make the ACP session active;
   - `phone/titles` for the current title.
6. Sending:
   - `session/prompt` with `{sessionId, prompt:[{type:"text", text}]}`;
   - bridge forwards `session/update` notifications (`agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update`, `usage_update`);
   - permission requests use `session/request_permission` and a `session/permission` response.

## Private bridge methods

| Method | Request | Response |
| --- | --- | --- |
| `phone/info` | `{}` | `{cwd, home, platform, bridgeVersion}` |
| `phone/history` | `{sessionId, limit?, before?}` | `{sessionId,title,cwd,messages,before,hasMore,total,note}` |
| `phone/titles` | `{sessionIds:[...]}` | `{titles:[{sessionId,title}]}` |
| `phone/workspaces` | `{}` | `{workspaces,archived,pinned,defaultWorkspaceId,note}` |
| `phone/archive` | `{sessionId, archived}` | `{archived:[...],sessionId,hidden}` |

`before` is an index into the bridge's capped message array (latest 200). The first page omits `before`; later pages pass the previous `before`.

## History replay

Session logs live under:

```text
~/.dsh/sessions/<encoded-cwd>/<session-id>/session.v4.jsonl.zstd
```

The bridge decompresses with `7z x <file> -so`, parses JSONL events, and maps:

- `user/message` → user message;
- `assistant/message` → assistant text + reasoning + usage;
- `tool/call` → running tool card;
- `tool/result` → tool output;
- `session/title` → title.

The full log is parsed, then sliced. This is why very large logs can still be slow on first open.

## Workspace sync

`workspace.json` is the DSH workspace store:

```json
{
  "global": {
    "workspaceIds": ["..."],
    "defaultWorkspaceId": "...",
    "archivedSessionIds": ["session-..."],
    "pinnedSessionIds": ["session-..."]
  },
  "tables": {
    "workspaces": {
      "<id>": {
        "path": "/path/to/folder",
        "title": "folder name",
        "sessionIds": ["session-..."]
      }
    }
  }
}
```

The bridge reads it on every `phone/workspaces` and edits `archivedSessionIds` on `phone/archive`. Writes are atomic (temp file + rename) with a one-time backup. Concurrent writers can still race; last write wins.

## Local cache

The phone stores in Preferences:

- `servers`: recent bridge URLs, most recent first;
- `settings`: `{autoConnect}`;
- `last_session`: `{sessionId,title,cwd}`;
- `last_chat`: the last window and up to 10 messages, with per-message truncation.

On launch the app renders `last_chat` immediately, then connects and calls `session/resume`. If resume fails, the cached window stays readable but the composer is disabled.

## Auth

- Fixed token in `~/.dsh/dsh-pocket-token` or `--token`.
- One active WebSocket; a new valid connection closes the old one.
- 10 failures per IP in 10 minutes → 1 hour ban (in-memory).
- Public mode: `/` requires `?key=<token>`; `/ws` always requires `token`.
- `CF-Connecting-IP` / `X-Forwarded-For` / `X-Real-IP` are trusted only when the direct peer is loopback.

## Layout

- `<600vp`: compact, one pane.
- `600–840vp`: rail + content.
- `≥840vp`: session rail + chat, larger typography.

The app uses ArkUI breakpoints and a `List`-based chat; there is no WebView.
