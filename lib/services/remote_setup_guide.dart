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
# or save CURSOR_API_KEY in the Agent Dock Connect tab

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
# or save ANTHROPIC_API_KEY in the Agent Dock Connect tab

# Smoke:
claude --version
command -v claude-code-acp
tmux -V
''';

const kRemoteTmuxSetupGuide = r'''# Install tmux on the remote
# Debian/Ubuntu:
sudo apt update && sudo apt install -y tmux

# Fedora:
# sudo dnf install -y tmux

# macOS:
# brew install tmux

tmux -V
''';
