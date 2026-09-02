# Agent Dock

Flutter app (Android-first, iOS beta) for a Cursor-style **Agents** window over SSH.

- **Connect** — SSH private key (and optional Cursor / Anthropic API key) in the device keystore
- **Hosts** — remotes like SSH config entries
- **Repos** — remote directories under a host
- **Agents** — many chats per repo; each chat talks to **ADSM** (Agent Dock Session Manager) on the remote, which owns Cursor / Claude ACP workers

Chats are local-first: the transcript is read from SQLite and painted before any
network call, and remote state is merged in afterwards.

### How a chat stays alive

On **Connect**, if the host is missing tooling the app installs it automatically
via the GitHub install scripts (`tmux`, Cursor CLI or Claude ACP, then **ADSM**).

Then the phone opens **one SSH channel** to `agentdock-adsm client`. That process
talks to a host daemon over a Unix socket. The daemon:

- Starts / adopts **tmux-supervised** ACP workers under `~/.agentdock/sessions/<chatId>/`
- Is the **only** writer to each session FIFO and reader of each journal
- Emits **normalized** events (text, tools, permissions, status) — not raw ACP replay
- Owns authoritative agent status (`idle` / `running` / `waiting_permission` / …)

Reconnecting re-subscribes to ADSM; the worker and conversation stay on the host.

Catalog sync (`~/.agentdock/agents`, `messages`) remains file-based for multi-device
transcripts.

## Remote setup (optional)

Connect usually installs everything. Manual scripts (also what the app curls):

```bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/cursor-acp.sh | bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/claude-acp.sh | bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/install-adsm.sh | bash
```

Details: [`scripts/README.md`](scripts/README.md).

## Security

- Secrets only in `flutter_secure_storage` (Android Keystore / iOS Keychain)
- Metadata SQLite DB never stores keys
- No analytics, Firebase, Crashlytics, or ads SDKs
- Network egress is SSH to hosts you configure (plus whatever the agent CLI does on the remote)
- Debug logs redact PEM / API-key-looking strings
- Prefer `agent login` / `claude login` on the remote; phone-stored API keys are optional and only injected into that agent process env

## Remote prerequisites

SSH access; host can reach GitHub raw URLs for install scripts. Auth: `agent login`
or `claude login` (or API keys in Connect).

## Run (Android)

```bash
flutter pub get
flutter run
```

Use JDK 17+ for Android Gradle if your machine requires it.

## Layout

```
lib/          Flutter app
host/adsm/    Python ADSM daemon (installed on host by install-adsm.sh)
scripts/      Remote installers (cursor-acp, claude-acp, install-adsm)
test/         Dart tests
```
