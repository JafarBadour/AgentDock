/// One-liner installers for the remote host Agent Dock SSH-connects to.
///
/// Scripts live in the AgentDock GitHub repo under `scripts/`.
const kAgentDockScriptsBase =
    'https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts';

/// Commands to install Cursor agent runtime on the remote.
const kRemoteCursorSetupGuide = '''
# Agent Dock · Cursor on this host (copy-paste)
curl -fsSL $kAgentDockScriptsBase/cursor-acp.sh | bash

# Then authenticate:
agent login
# or save CURSOR_API_KEY in Agent Dock Settings

# Smoke:
cursor-agent --version || agent --version
tmux -V
''';

/// Commands to install Claude Code + ACP adapter on the remote.
const kRemoteClaudeSetupGuide = '''
# Agent Dock · Claude on this host (copy-paste)
curl -fsSL $kAgentDockScriptsBase/claude-acp.sh | bash

# Then authenticate (pick one):
claude login
# or save ANTHROPIC_API_KEY in Agent Dock Settings

# Smoke:
claude --version
command -v claude-code-acp
tmux -V
''';

/// Commands to install the Codex ACP adapter (bundles the Codex CLI).
const kRemoteCodexSetupGuide = '''
# Agent Dock · Codex on this host (copy-paste)
curl -fsSL $kAgentDockScriptsBase/codex-acp.sh | bash

# Then authenticate (pick one):
codex login --device-auth
# or save OPENAI_API_KEY in Agent Dock Settings
# (starting a new login signs out any existing Codex session on this host)

# Smoke:
codex login status
command -v codex-acp
tmux -V
''';

const kRemoteTmuxSetupGuide = r'''# Install tmux on the remote (required by Agent Dock)

# --- HPC / shared clusters (no sudo) ---
module spider tmux        # see available modules
module load tmux          # or: module load tools/tmux
# then confirm:
tmux -V

# Or conda/mamba in your account:
# conda install -y -c conda-forge tmux

# --- Debian/Ubuntu (needs sudo) ---
# sudo apt update && sudo apt install -y tmux

# --- Fedora ---
# sudo dnf install -y tmux

# --- macOS ---
# brew install tmux

tmux -V
''';

/// Shown only if the app’s automatic ADSM install somehow fails.
const kRemoteAdsmSetupGuide = '''
# Agent Dock installs/upgrades ADSM automatically when you open an agent.
# On version mismatch it re-runs install-adsm.sh so the host matches the app.
# If that failed, run once on the remote:

curl -fsSL $kAgentDockScriptsBase/install-adsm.sh | bash
agentdock-adsm status
''';
