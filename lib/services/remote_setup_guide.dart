/// Commands to install on the remote when Cursor agent runtime is missing.
const kRemoteCursorSetupGuide = r'''# 1. Cursor CLI (the SDK's local runtime depends on this binary)
curl https://cursor.com/install -fsS | bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
agent --version

# 2. Node, if it isn't there
node --version || curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs

# 3. Project + SDK
mkdir -p ~/agent-sdk && cd ~/agent-sdk
npm init -y
npm pkg set type=module
npm install @cursor/sdk

# 4. Key
echo 'export CURSOR_API_KEY=your_key_here' >> ~/.bashrc
source ~/.bashrc
''';

/// Shown when Claude is selected (beta) — install is not wired yet.
const kRemoteClaudeSetupGuide = r'''# Claude Code (beta in Agentic Phone — not wired yet)
# On the remote host, typical install:
curl -fsSL https://claude.ai/install.sh | bash
# or: npm install -g @anthropic-ai/claude-code
claude --version
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
