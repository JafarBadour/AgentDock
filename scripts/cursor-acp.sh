#!/usr/bin/env bash
# Agent Dock — remote Cursor ACP runtime installer
#
# One-shot install for the host Agent Dock talks to over SSH.
#
#   curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/cursor-acp.sh | bash
#
# Idempotent: safe to re-run.

set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ✓ %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*" >&2; }

ensure_path_line() {
  local line='export PATH="$HOME/.local/bin:$HOME/.cursor/bin:$PATH"'
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

say "Agent Dock · Cursor ACP setup"

mkdir -p "$HOME/.local/bin"
ensure_path_line

# --- Cursor Agent CLI -------------------------------------------------------
say "Cursor Agent CLI"
if have cursor-agent || have agent; then
  ok "already installed: $(command -v cursor-agent 2>/dev/null || command -v agent)"
else
  curl -fsSL https://cursor.com/install | bash
  ensure_path_line
fi

if have cursor-agent; then
  ok "cursor-agent → $(command -v cursor-agent)"
  cursor-agent --version 2>/dev/null || true
elif have agent; then
  ok "agent → $(command -v agent)"
  agent --version 2>/dev/null || true
  # Stable name Agent Dock looks for first.
  ln -sfn "$(command -v agent)" "$HOME/.local/bin/cursor-agent"
  ok "linked ~/.local/bin/cursor-agent"
else
  warn "Cursor CLI not found after install — check https://cursor.com/install"
  exit 1
fi

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

# --- Node (optional; some MCP / tooling expects it) -------------------------
say "Node.js (optional)"
load_nvm() {
  # shellcheck disable=SC1090,SC1091
  [ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
}
load_nvm
if have node; then
  ok "node $(node --version)"
else
  warn "node not found — installing nvm + LTS (optional for Cursor ACP)"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  load_nvm
  nvm install --lts
  ok "node $(node --version)"
fi

say "Done"
cat <<'EOF'

Next:
  1. Log in on this host:  agent login
     (or set CURSOR_API_KEY in the Agent Dock Connect tab)
  2. Smoke test:           cursor-agent --version
  3. In Agent Dock: create a Cursor agent and Connect

EOF
