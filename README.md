# Agent Dock

Flutter app (Android-first, iOS beta) for a Cursor-style **Agents** window over SSH.

- **Connect** — SSH private key (and optional Cursor API key) in the device keystore
- **Hosts** — remotes like SSH config entries
- **Repos** — remote directories under a host
- **Agents** — many chats per repo; each chat talks to **Cursor Agent CLI** (`cursor-agent acp` / `agent acp`) on the remote via stock **tmux** + ACP

Chats are local-first: the transcript is read from SQLite and painted before any
network call, and remote state is merged in afterwards.

### How a chat stays alive

The agent runs detached under tmux in `~/.agentdock/sessions/<chatId>/`, not
bound to the SSH connection:

- **stdin** is a FIFO (`in`) held open by a parked `sleep`, so the phone
  disconnecting never sends EOF to the agent
- **stdout** is appended to a journal (`out.jsonl`), so output produced while
  you were away is kept and replayed from the byte offset you last read

Reconnecting therefore reattaches to the *same* process with its context intact.
If the process is gone (host reboot), the app falls back to ACP `session/load`
when the agent advertises that capability, and only then to a new session.

One pooled SSH connection per host is shared by every feature, health-checked
with a timeout, and dropped when the app backgrounds.

This is a greenfield project. Patterns were studied from open-source tools (e.g. MonkeySSH); **no third-party app code or remote helper binaries are vendored**.

## Remote setup (SSH host)

On the machine Agent Dock SSHs into:

```bash
# Cursor agents
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/cursor-acp.sh | bash

# Claude agents
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/claude-acp.sh | bash
```

Details: [`scripts/README.md`](scripts/README.md).

## Security

- Secrets only in `flutter_secure_storage` (Android Keystore / iOS Keychain)
- Metadata SQLite DB never stores keys
- No analytics, Firebase, Crashlytics, or ads SDKs
- Network egress is SSH to hosts you configure (plus whatever the Cursor CLI does on the remote)
- Debug logs redact PEM / API-key-looking strings
- Prefer `agent login` on the remote; phone-stored Cursor API key is optional and only injected into that agent process env

## Remote prerequisites

On each host:

```bash
# tmux
sudo apt install tmux   # or brew install tmux

# Cursor Agent CLI on PATH as `cursor-agent` or `agent`
agent login
```

## Run (Android)

```bash
flutter pub get
flutter run
```

Use JDK 17+ for Android Gradle if your machine requires it.

iOS builds are supported by the project but are secondary (beta).

## Layout

```
lib/
  features/   # Connect, Hosts, Repos, Agents UI
  data/       # models, sqflite metadata, secure store
  services/   # SSH pool, remote agent runtime, Cursor ACP client, sync
  app/        # router, providers
```
