# Contributing

Thanks for taking a look.

## Before you open a PR

- Read `README.md`, `docs/ARCHITECTURE.md` and `SECURITY.md`.
- Do not commit tokens, session logs, screenshots with a token, local paths, signing files or `workspace.json`.
- Keep the bridge API compatible unless the PR explains the migration.

## Development

- Host: Node.js 22+, no third-party runtime dependencies.
  ```bash
  node host/dsh-native-host.mjs --list-hosts
  node host/dsh-native-host.mjs --port 3090
  ```
- App: open `harmony/` in DevEco Studio, configure your own signing, build the `entry` module.
- Markdown changes: verify headings, lists, quotes, fenced code, tables and inline styles on a real device or emulator.
- ACP changes: check `initialize`, `session/list`, `session/resume`, `session/prompt`, `session/cancel` and `session/update` notifications.

## Commits

Use Conventional Commits, for example:

```text
feat: 会话列表按 workspace 分组
fix: 修复未知 session 时仍允许发送
docs: 补充公网隧道说明
```

The repository history uses a generic author identity; do not add a personal email to commits.

## Security

Report vulnerabilities through a private GitHub Security Advisory, not a public issue. See `SECURITY.md`.
