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

Then: `claude login` **or** save an Anthropic API key in Agent Dock → Connect.

Both scripts are idempotent and install `tmux` when missing, then install/start **ADSM**.

## ADSM only

```bash
curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/install-adsm.sh | bash
agentdock-adsm status
```

ADSM is the host session manager: one daemon owns all durable agent workers.
The phone talks only to ADSM over SSH (`agentdock-adsm client`).
