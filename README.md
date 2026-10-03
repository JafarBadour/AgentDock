# AgentPlantation

Flutter app (Android-first, iOS beta, plus a desktop build) for a Cursor-style
**Agents** window over SSH. Desktop — macOS, Windows, Linux — gets the
three-column shell; phones get bottom nav.

- **Connect** — SSH private key (and optional Cursor / Anthropic / OpenAI API key) in the device keystore
- **Hosts** — remotes like SSH config entries
- **Repos** — remote directories under a host
- **Agents** — many chats per repo; each chat talks to **ADSM** (the session-manager daemon) on the remote, which owns Cursor / Claude / Codex ACP workers

Chats are local-first: the transcript is read from SQLite and painted before any
network call, and remote state is merged in afterwards.

### In a chat

- **Fork** — branch a chat into a second agent that starts with the same
  conversation (see below)
- **Images** — paste or drag into the composer, up to 5 per prompt. Oversized
  ones are re-encoded **on the device** before sending, so anything the platform
  can decode works whether or not the host has Pillow / sips
- **Copy** — selecting part of a reply and copying puts HTML on the clipboard
  beside the plain text, so pasting into Teams or Outlook keeps bold, lists,
  tables, code and links
- **Voice** — dictate a prompt instead of typing it

### How a chat stays alive

On **Connect**, if the host is missing tooling the app installs it automatically
via the GitHub install scripts (`tmux`, Cursor CLI / Claude ACP / Codex ACP, then **ADSM**).

Then the phone opens **one SSH channel** to `agentdock-adsm client`. That process
talks to a host daemon over a Unix socket. The daemon:

- Starts / adopts **tmux-supervised** ACP workers under `~/.agentdock/sessions/<chatId>/`
- Is the **only** writer to each session FIFO and reader of each journal
- Emits **normalized** events (text, tools, permissions, status) — not raw ACP replay
- Owns authoritative agent status (`idle` / `running` / `waiting_permission` / …)

Reconnecting re-subscribes to ADSM; the worker and conversation stay on the host.

Catalog sync (`~/.agentdock/agents`, `messages`) remains file-based for multi-device
transcripts.

### Every chat stays current, not just the open one

While the app is in the foreground it holds **one `digest` subscription per
host**, riding the shared bridge. That carries new messages, turn ends, status
and catalog changes for every chat on that host — never the token stream — so
the chat list behaves like a messenger's rather than only updating what is on
screen. Chats with an open runtime keep applying their own events; the rest get
the message stored or the finished reply pulled. The daemon fans events out to
every connected device, so a rename, a read marker or a delete on your laptop
lands on your phone.

### Forking an agent

A fork is a new chat on the same repo, agent and model, holding a copy of the
source's durable transcript — but **deliberately no ACP session id**. It opens
its own session and rebuilds context from that transcript on its first prompt,
reusing the same history bootstrap that recovers a dropped session.

So the two agents share a past and nothing else: neither sees the other's later
turns, and the source keeps running untouched. The copy happens on the host,
which already holds the transcript, so forking a long chat uploads nothing.

Message ids are regenerated on copy — an id is unique per device database, not
per chat, so reusing them would collide with the source once the fork syncs back.

What a fork carries is the **conversation**, not the agent's own internal session
state (file reads, tool results, compacted memory). The agent re-derives from a
bounded slice of the transcript, the same budget used for session recovery — so a
fork of a very long chat starts from its tail, not a byte-exact clone.

## Remote setup (optional)

Connect usually installs everything. Manual scripts (also what the app curls):

```bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/cursor-acp.sh | bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/claude-acp.sh | bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/codex-acp.sh | bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/install-adsm.sh | bash
```

Agents on **This PC** (Windows) run natively; to preinstall what they need, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/windows-setup.ps1 | iex
```

Details: [`scripts/README.md`](scripts/README.md).

## Security

- Secrets only in `flutter_secure_storage` (Android Keystore / iOS Keychain)
- Metadata SQLite DB never stores keys
- No analytics, Firebase, Crashlytics, or ads SDKs
- Network egress is SSH to hosts you configure (plus whatever the agent CLI does on the remote)
- Debug logs redact PEM / API-key-looking strings
- Prefer `agent login` / `claude login` / `codex login --device-auth` on the remote; phone-stored API keys are optional and only injected into that agent process env (Codex additionally persists an injected key in `~/.codex/auth.json` on the host)

## Remote prerequisites

SSH access; host can reach GitHub raw URLs for install scripts. Auth: `agent login`,
`claude login` or `codex login --device-auth` (or API keys in Settings).

Those CLI sign-in flows run from the app over a real PTY. On the machine running
AgentPlantation that PTY is **local**, so signing a host in there needs no Remote
Login / OpenSSH Server.

## Run

```bash
flutter pub get
flutter run              # attached device
flutter run -d macos     # desktop shell
```

Use JDK 17+ for Android Gradle if your machine requires it.

## Test

```bash
flutter test

# ADSM. tests/ has no __init__.py, so name the modules rather than discovering.
cd host && PYTHONPATH="$PWD/..:$PWD" python3 -m unittest \
  adsm.tests.test_fork adsm.tests.test_images adsm.tests.test_multi_device \
  adsm.tests.test_process_hygiene adsm.tests.test_protocol \
  adsm.tests.test_transcript adsm.tests.test_worker_codex \
  adsm.tests.test_worker_hydrate adsm.test_config_options
```

## Layout

```
lib/               Flutter app
host/adsm/         Python ADSM daemon (installed on host by install-adsm.sh)
scripts/           Remote installers (cursor-acp, claude-acp, codex-acp, install-adsm)
                   + windows-setup.ps1
test/              Dart tests
integration_test/  Dart integration tests
tool/              Dev utilities (ACP model probe)
binaries/          Local build artifacts (gitignored)
```
