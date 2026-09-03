#!/usr/bin/env bash
# Agent Dock — install / start ADSM (Agent Dock Session Manager) on the host.
#
#   curl -fsSL https://raw.githubusercontent.com/JafarBadour/AgentDock/main/scripts/install-adsm.sh | bash
#
# Idempotent. Copies the Python package next to this install or from a
# sibling checkout, then ensures the daemon is running.

set -euo pipefail

say() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ✓ %s\n' "$*"; }
warn() { printf '    ! %s\n' "$*" >&2; }

DEST_SHARE="${HOME}/.local/share/agentdock"
DEST_BIN="${HOME}/.local/bin"
REPO_URL="${AGENTDOCK_ADSM_URL:-https://raw.githubusercontent.com/JafarBadour/AgentDock/main}"

mkdir -p "$DEST_SHARE" "$DEST_BIN"
export PATH="$DEST_BIN:$PATH"

# Prefer a local host/ tree (when installing from a git checkout).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
LOCAL_HOST=""
if [ -n "${SCRIPT_DIR}" ] && [ -d "${SCRIPT_DIR}/../host/adsm" ]; then
  LOCAL_HOST="$(cd "${SCRIPT_DIR}/../host" && pwd)"
elif [ -d "$(pwd)/host/adsm" ]; then
  LOCAL_HOST="$(pwd)/host"
fi

say "Agent Dock · ADSM install"

if [ -n "$LOCAL_HOST" ]; then
  ok "using local package at $LOCAL_HOST"
  rm -rf "$DEST_SHARE/host"
  mkdir -p "$DEST_SHARE/host"
  cp -R "$LOCAL_HOST/adsm" "$DEST_SHARE/host/"
else
  say "fetching ADSM sources from GitHub"
  TMP="$(mktemp -d)"
  cleanup() { rm -rf "$TMP"; }
  trap cleanup EXIT
  # Sparse-ish: pull individual modules.
  mkdir -p "$TMP/adsm"
  for f in __init__.py __main__.py paths.py protocol.py worker.py daemon.py cli.py scheduler.py transcript.py; do
    curl -fsSL "$REPO_URL/host/adsm/$f" -o "$TMP/adsm/$f"
  done
  rm -rf "$DEST_SHARE/host"
  mkdir -p "$DEST_SHARE/host"
  cp -R "$TMP/adsm" "$DEST_SHARE/host/"
fi

# Wrapper on PATH.
cat >"$DEST_BIN/agentdock-adsm" <<EOF
#!/usr/bin/env bash
export PYTHONPATH="${DEST_SHARE}/host\${PYTHONPATH:+:\$PYTHONPATH}"
exec python3 -m adsm "\$@"
EOF
chmod +x "$DEST_BIN/agentdock-adsm"
ok "agentdock-adsm → $DEST_BIN/agentdock-adsm"

# PATH line for interactive shells.
line='export PATH="$HOME/.local/bin:$PATH"'
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  [ -f "$rc" ] || touch "$rc"
  if ! grep -Fqs '.local/bin' "$rc" 2>/dev/null; then
    printf '\n# Agent Dock\n%s\n' "$line" >>"$rc"
  fi
done

say "starting daemon"
if ! command -v python3 >/dev/null 2>&1; then
  warn "python3 not found"
  exit 1
fi
if ! command -v tmux >/dev/null 2>&1; then
  warn "tmux not found — install tmux (ADSM workers need it)"
fi

# Always restart so a prior daemon cannot keep old code in memory.
pkill -f 'python3 -m adsm serve' 2>/dev/null || true
pkill -f 'python -m adsm serve' 2>/dev/null || true
sleep 0.3
rm -f "${HOME}/.agentdock/adsm.sock" 2>/dev/null || true

"$DEST_BIN/agentdock-adsm" ensure-running
ok "ADSM daemon running"
"$DEST_BIN/agentdock-adsm" status || true
ok "ADSM ready"
