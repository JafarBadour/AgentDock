#!/usr/bin/env bash
# Agent Dock — remote Claude ACP runtime installer
#
# Installs Claude Code + the ACP adapter Agent Dock launches over SSH.
#
#   curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/claude-acp.sh | bash
#
# Idempotent: safe to re-run.

set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ✓ %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*" >&2; }

ensure_path_line() {
  local line='export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"'
  local rc
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    [ -f "$rc" ] || touch "$rc"
    if ! grep -Fqs '.local/bin' "$rc" 2>/dev/null; then
      printf '\n# Agent Dock\n%s\n' "$line" >>"$rc"
    fi
  done
  # shellcheck disable=SC2086
  eval "$line"
}

have() { command -v "$1" >/dev/null 2>&1; }

load_nvm() {
  # shellcheck disable=SC1090,SC1091
  if [ -s "$HOME/.nvm/nvm.sh" ]; then
    . "$HOME/.nvm/nvm.sh"
  fi
}

say "Agent Dock · Claude ACP setup"

mkdir -p "$HOME/.local/bin"
ensure_path_line

# --- Claude Code CLI --------------------------------------------------------
say "Claude Code CLI"
if have claude; then
  ok "already installed: $(command -v claude)"
  claude --version 2>/dev/null || true
else
  curl -fsSL https://claude.ai/install.sh | bash
  ensure_path_line
  if ! have claude; then
    warn "claude not on PATH after install"
    exit 1
  fi
  ok "claude → $(command -v claude)"
fi

# --- Node / npm (nvm-friendly) ----------------------------------------------
say "Node.js + npm"
load_nvm
if ! have node || ! have npm; then
  if ! [ -s "$HOME/.nvm/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  fi
  load_nvm
  nvm install --lts
  load_nvm
fi
ok "node $(node --version) · npm $(npm --version)"

# --- ACP adapter ------------------------------------------------------------
say "Claude ACP adapter (@agentclientprotocol/claude-agent-acp)"
npm install -g @agentclientprotocol/claude-agent-acp \
  || npm install -g @zed-industries/claude-code-acp

NODE_BIN="$(dirname "$(command -v node)")"
PREFIX_BIN="$(npm prefix -g 2>/dev/null)/bin"

# Locate the real npm-global binary — never link ~/.local/bin to itself.
REAL=
for dir in "$NODE_BIN" "$PREFIX_BIN"; do
  [ -d "$dir" ] || continue
  # Skip if this dir is ~/.local/bin (would create a self-symlink).
  [ "$(cd "$dir" && pwd -P)" = "$(cd "$HOME/.local/bin" && pwd -P)" ] && continue
  for name in claude-agent-acp claude-code-acp; do
    if [ -x "$dir/$name" ]; then
      REAL="$dir/$name"
      break 2
    fi
  done
done

if [ -z "$REAL" ]; then
  warn "ACP adapter binary not found after npm install"
  exit 1
fi

# Wrapper so non-login shells (tmux) still find `node` via nvm.
cat >"$HOME/.local/bin/claude-code-acp" <<EOF
#!/usr/bin/env bash
# Agent Dock wrapper — ensure nvm node is on PATH for #!/usr/bin/env node.
export NVM_DIR="\${NVM_DIR:-\$HOME/.nvm}"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
for d in "\$HOME"/.nvm/versions/node/*/bin; do
  [ -d "\$d" ] && PATH="\$d:\$PATH"
done
export PATH="\$HOME/.local/bin:\$PATH"
exec $(printf %q "$REAL") "\$@"
EOF
chmod +x "$HOME/.local/bin/claude-code-acp"
ln -sfn "$HOME/.local/bin/claude-code-acp" "$HOME/.local/bin/claude-agent-acp"

ensure_path_line
ok "adapter → $REAL"
ok "wrapper → $HOME/.local/bin/claude-code-acp"

# --- tmux -------------------------------------------------------------------
say "tmux (durable sessions)"
if have tmux; then
  ok "tmux $(tmux -V 2>/dev/null | awk '{print $2}')"
else
  if have apt-get; then
    sudo apt-get update -y && sudo apt-get install -y tmux
  elif have dnf; then
    sudo dnf install -y tmux
  elif have brew; then
    brew install tmux
  else
    warn "Install tmux manually, then re-run."
    exit 1
  fi
  ok "tmux installed"
fi

# --- ADSM (session manager) -------------------------------------------------
say "ADSM (Agent Dock Session Manager)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "${SCRIPT_DIR}" ] && [ -f "${SCRIPT_DIR}/install-adsm.sh" ]; then
  bash "${SCRIPT_DIR}/install-adsm.sh"
else
  curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/install-adsm.sh | bash
fi

say "Done"
cat <<'EOF'

Next — pick ONE auth method:
  A) On this host:   claude login
  B) In Agent Dock:  Connect tab → save Anthropic API key

Then in Agent Dock create a Claude agent and tap Connect.

Smoke:
  claude --version
  command -v claude-code-acp
  agentdock-adsm status

EOF
