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

/// Install Claude Code + Zed's ACP adapter on the remote host.
const kRemoteClaudeSetupGuide = r'''# 1. Claude Code CLI
curl -fsSL https://claude.ai/install.sh | bash
# or: npm install -g @anthropic-ai/claude-code
claude --version

# 2. Node (needed for the ACP adapter)
node --version || curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs

# 3. Zed Claude Code ACP adapter (stdio ACP bridge)
npm install -g @zed-industries/claude-code-acp
# Ensure the binary is on PATH (npm prefix bin):
echo 'export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
command -v claude-code-acp
# Smoke: start briefly then Ctrl-C (Agent Dock launches this for you)
# claude-code-acp

# 4. Auth — either works with Agent Dock:
#    a) Save ANTHROPIC_API_KEY in the app Connect tab, or:
export ANTHROPIC_API_KEY=your_key_here
#    b) Or interactive login on the host:
claude login
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
