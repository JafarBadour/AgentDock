# Remote install scripts (Agent Dock)

Run these **on the SSH host** Agent Dock connects to (not on your phone).

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

Both scripts are idempotent and install `tmux` when missing.
