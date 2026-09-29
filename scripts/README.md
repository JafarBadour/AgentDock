# Remote install scripts (Agent Dock)

The app runs these automatically on **Connect** when something is missing.
You can also run them by hand on the SSH host.

## Cursor

```bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/cursor-acp.sh | bash
```

Then: `agent login` (or set `CURSOR_API_KEY` in the app).

## Claude

```bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/claude-acp.sh | bash
```

Then: `claude login` **or** save an Anthropic API key in Agent Dock → Settings.

## Codex

```bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/codex-acp.sh | bash
```

Installs `@agentclientprotocol/codex-acp` (bundles the Codex CLI) and a
`~/.local/bin/codex-acp` wrapper. Then: `codex login --device-auth` on the host
**or** save an OpenAI API key in Agent Dock → Settings (Codex persists it in
`~/.codex/auth.json` on the host). Starting a new `codex login` signs out any
existing Codex session on that host.

All scripts are idempotent and install `tmux` when missing, then install/start **ADSM**.

## This PC (Windows)

Local agents on Windows run natively (no SSH, tmux or WSL). In PowerShell:

```powershell
irm https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/windows-setup.ps1 | iex
```

Installs Python 3.9+ (runs ADSM), Node.js and the Claude ACP adapter via
winget/npm; installers may show an administrator prompt. For Codex too:
`$env:AGENTDOCK_AGENTS = "claude,codex"` before running it. Cursor is not
supported on This PC under Windows yet. The app installs and starts ADSM
itself, and also installs missing Python/Node/adapters on first connect.

## ADSM only

```bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/install-adsm.sh | bash
agentdock-adsm status
```

ADSM is the host session manager: one daemon owns all durable agent workers.
The phone talks only to ADSM over SSH (`agentdock-adsm client`).
