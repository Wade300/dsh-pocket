# Security

## What the token protects

The bridge token authenticates a phone to a DSH agent running on your PC. A paired client can:

- list and read session history;
- send prompts that make the agent run tools on the PC;
- answer permission prompts;
- hide or unhide sessions by editing `~/.dsh/storages/workspace.json`.

Treat the token like an SSH key. Anyone who has it and can reach the bridge can drive the agent with your OS user's permissions.

## Defaults

- Fixed token stored at `~/.dsh/dsh-pocket-token` (created on first run, mode 0600 where the OS supports it).
- The token can also be passed with `--token`; command-line arguments may be visible to other local users.
- One active WebSocket. A new valid connection replaces the old one.
- Ten authentication failures from one IP inside ten minutes ban that IP for one hour.
- Bans are in memory and are cleared when the bridge restarts.
- Public mode (`--public-url`) forces loopback binding and protects the control page `/` with `?key=<token>`. `/ws` always requires the token.

## Recommendations

1. Put a TLS tunnel in front of the bridge for remote use. Do not port-forward plain `ws://`.
2. Keep the bridge bound to a private interface or loopback.
3. Rotate the token by deleting `~/.dsh/dsh-pocket-token` (or passing a new `--token`) and updating the phone.
4. Do not put tokens, session logs, screenshots or `workspace.json` in the repository.
5. Restrict who can read your home directory. Session logs can contain prompts, code and tool output.
6. Review the code before exposing it. This project is not audited.

## Sensitive operations

`phone/archive` edits the DSH workspace state. The bridge keeps a one-time `workspace.json.dshpocket.bak` backup before the first write, but concurrent writers (DSH itself or another process) can still race. Do not use the bridge against a workspace file you cannot restore.

## Reporting

Open a private GitHub Security Advisory on this repository. Do not file a public issue with a working exploit or a real token.
