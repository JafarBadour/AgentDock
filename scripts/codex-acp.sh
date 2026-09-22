#!/usr/bin/env bash
# Agent Dock — remote Codex ACP runtime installer
#
# Installs the Codex ACP adapter (@agentclientprotocol/codex-acp, which bundles
# the OpenAI Codex CLI) that Agent Dock launches over SSH.
#
#   curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/codex-acp.sh | bash
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

# The adapter is TypeScript and needs a current Node (the bundled Codex CLI
# ships a native binary, so only the adapter itself runs on Node).
NODE_MIN_MAJOR=20
node_ok() {
  have node || return 1
  local major
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [ "${major:-0}" -ge "$NODE_MIN_MAJOR" ]
}

say "Agent Dock · Codex ACP setup"

mkdir -p "$HOME/.local/bin"
ensure_path_line

# --- Node / npm (nvm-friendly) ----------------------------------------------
say "Node.js ${NODE_MIN_MAJOR}+ and npm"
load_nvm
if ! node_ok || ! have npm; then
  if ! [ -s "$HOME/.nvm/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  fi
  load_nvm
  nvm install --lts
  load_nvm
fi
if ! node_ok; then
  warn "node ${NODE_MIN_MAJOR}+ is required (have: $(node --version 2>/dev/null || echo none))"
  exit 1
fi
ok "node $(node --version) · npm $(npm --version)"

# --- ACP adapter ------------------------------------------------------------
say "Codex ACP adapter (@agentclientprotocol/codex-acp)"
npm install -g @agentclientprotocol/codex-acp@latest

NODE_BIN="$(dirname "$(command -v node)")"
PREFIX_BIN="$(npm prefix -g 2>/dev/null)/bin"

# Locate the real npm-global binary — never link ~/.local/bin to itself.
REAL=
for dir in "$NODE_BIN" "$PREFIX_BIN"; do
  [ -d "$dir" ] || continue
  [ "$(cd "$dir" && pwd -P)" = "$(cd "$HOME/.local/bin" && pwd -P)" ] && continue
  if [ -x "$dir/codex-acp" ]; then
    REAL="$dir/codex-acp"
    break
  fi
done

if [ -z "$REAL" ]; then
  warn "codex-acp binary not found after npm install"
  exit 1
fi

# Wrapper so non-login shells (tmux) still find `node` via nvm.
{
  printf '#!/usr/bin/env bash\n'
  printf '# Agent Dock wrapper — ensure nvm node is on PATH for #!/usr/bin/env node.\n'
  printf 'export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"\n'
  printf '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"\n'
  printf 'for d in "$HOME"/.nvm/versions/node/*/bin; do\n'
  printf '  [ -d "$d" ] && PATH="$d:$PATH"\n'
  printf 'done\n'
  printf 'export PATH="$HOME/.local/bin:$PATH"\n'
  printf '# Never try to open a browser on a headless host.\n'
  printf 'export NO_BROWSER=1\n'
  printf 'exec %q "$@"\n' "$REAL"
} >"$HOME/.local/bin/codex-acp"
chmod +x "$HOME/.local/bin/codex-acp"

# `codex` CLI on PATH for `codex login` (bundled with the adapter).
CODEX_JS="$(npm root -g 2>/dev/null)/@agentclientprotocol/codex-acp/node_modules/@openai/codex/bin/codex.js"
if ! have codex && [ -f "$CODEX_JS" ]; then
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"\n'
    printf '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"\n'
    printf 'for d in "$HOME"/.nvm/versions/node/*/bin; do\n'
    printf '  [ -d "$d" ] && PATH="$d:$PATH"\n'
    printf 'done\n'
    printf 'exec node %q "$@"\n' "$CODEX_JS"
  } >"$HOME/.local/bin/codex"
  chmod +x "$HOME/.local/bin/codex"
  ok "codex → $HOME/.local/bin/codex (bundled)"
fi

ensure_path_line
ok "adapter → $REAL"
ok "wrapper → $HOME/.local/bin/codex-acp"

# --- tmux -------------------------------------------------------------------
if [ "${AGENTDOCK_SKIP_TMUX:-}" = "1" ]; then
  say "tmux (skipped — Agent Dock already checked)"
else
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
fi

# --- ADSM (session manager) -------------------------------------------------
if [ "${AGENTDOCK_SKIP_ADSM:-}" = "1" ]; then
  say "ADSM (skipped — Agent Dock manages ADSM separately)"
else
  say "ADSM (Agent Dock Session Manager)"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [ -n "${SCRIPT_DIR}" ] && [ -f "${SCRIPT_DIR}/install-adsm.sh" ]; then
    bash "${SCRIPT_DIR}/install-adsm.sh"
  else
    curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/install-adsm.sh | bash
  fi
fi

say "Done"
cat <<'DONE'

Next — pick ONE auth method:
  A) On this host:   codex login --device-auth
                     (starting a login signs out any existing Codex session)
  B) In Agent Dock:  Settings → save OpenAI API key
                     (Codex keeps it in ~/.codex/auth.json on this host)

Then in Agent Dock create a Codex agent and connect.

Smoke:
  codex login status
  command -v codex-acp
  agentdock-adsm status

DONE
