import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../data/local/app_database.dart';
import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import 'remote_setup_guide.dart';
import 'ssh_no_delay_socket.dart';

class SshConnectResult {
  const SshConnectResult({required this.ok, this.detail, this.error});

  final bool ok;
  final String? detail;
  final String? error;
}

class MissingToolException implements Exception {
  MissingToolException(this.tool, this.installHint);

  final String tool;
  final String installHint;

  @override
  String toString() => '$tool is not installed on the remote host.';
}

/// Why a connection attempt failed, and whether retrying could ever help.
enum SshFailureKind {
  /// Bad credentials or an unusable key — retrying will never succeed and may
  /// trip fail2ban or lock the account.
  auth,

  /// No key configured on the device yet.
  missingKey,

  /// Host key rejected.
  hostKey,

  /// Transport-level problem: unreachable, refused, reset, timed out.
  network,

  /// Something the remote is missing, e.g. the Cursor CLI. Retrying the same
  /// connection cannot install it.
  tooling,

  unknown,
}

extension SshFailureKindX on SshFailureKind {
  /// Fatal failures must never be retried automatically.
  bool get isFatal =>
      this == SshFailureKind.auth ||
      this == SshFailureKind.missingKey ||
      this == SshFailureKind.hostKey ||
      this == SshFailureKind.tooling;
}

/// Classify an arbitrary error thrown from the SSH stack.
SshFailureKind classifySshFailure(Object error) {
  if (error is MissingToolException) return SshFailureKind.tooling;
  if (error is SSHAuthFailError) return SshFailureKind.auth;
  if (error is SSHKeyDecodeError) return SshFailureKind.missingKey;
  if (error is SSHHostkeyError) return SshFailureKind.hostKey;
  if (error is SSHAuthAbortError) {
    // Aborted auth is usually the socket dying mid-handshake.
    return SshFailureKind.network;
  }
  if (error is SSHSocketError ||
      error is SocketException ||
      error is TimeoutException ||
      error is SSHHandshakeError) {
    return SshFailureKind.network;
  }
  if (error is StateError) {
    final message = error.message.toLowerCase();
    if (message.contains('no ssh private key')) return SshFailureKind.missingKey;
    if (message.contains('passphrase') || message.contains('parse')) {
      return SshFailureKind.missingKey;
    }
  }
  final text = error.toString().toLowerCase();
  if (text.contains('connection closed') ||
      text.contains('transport is closed') ||
      text.contains('channel open') ||
      text.contains('broken pipe') ||
      text.contains('connection reset') ||
      text.contains('socketexception')) {
    return SshFailureKind.network;
  }
  return SshFailureKind.unknown;
}

/// Caps concurrent exec channels on one connection.
///
/// sshd's `MaxSessions` defaults to 10 channels per network connection. Now
/// that everything shares one connection per host, unbounded fan-out would hit
/// that ceiling and get channels refused.
class _ChannelGate {
  _ChannelGate(this.limit);

  final int limit;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();

  Future<T> run<T>(Future<T> Function() body) async {
    if (_active >= limit) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await body();
    } finally {
      _active--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}

class _PooledHost {
  _PooledHost(this.connecting);

  Future<SSHClient> connecting;
  SSHClient? client;
  final _ChannelGate gate = _ChannelGate(6);
}

/// SSH client wrapper. Secrets come from [SecureStore] only for the duration
/// of a connection attempt — never logged.
///
/// Connections are pooled per host and shared. Callers must **not** close the
/// client returned by [connect]; the pool owns its lifetime and evicts it when
/// it dies or fails a health check.
class SshService {
  SshService(this._secureStore, this._db);

  final SecureStore _secureStore;
  final AppDatabase _db;

  final Map<String, _PooledHost> _pool = {};
  Timer? _healthTimer;
  bool _suspended = false;

  static const _healthInterval = Duration(seconds: 45);
  static const _pingTimeout = Duration(seconds: 6);

  Future<SshConnectResult> testConnection(Host host) async {
    try {
      final client = await connect(host);
      final out = await _run(client, 'uname -a', hostId: host.id);
      return SshConnectResult(ok: true, detail: out.trim());
    } catch (e) {
      SafeLog.d('SSH test failed for ${host.hostname}', e);
      return SshConnectResult(ok: false, error: e.toString());
    }
  }

  /// A live, pooled client for [host]. Do not close the result.
  Future<SSHClient> connect(Host host, {Set<String>? visited}) async {
    final pooled = _pool[host.id];
    if (pooled != null) {
      try {
        final client = await pooled.connecting;
        if (!client.isClosed) return client;
      } catch (_) {
        // Fall through and reconnect below.
      }
      _pool.remove(host.id);
    }

    final entry = _PooledHost(_createClient(host, visited: visited));
    _pool[host.id] = entry;

    late final SSHClient client;
    try {
      client = await entry.connecting;
    } catch (e) {
      _pool.remove(host.id);
      rethrow;
    }

    entry.client = client;
    unawaited(
      client.done.whenComplete(() {
        if (_pool[host.id] == entry) {
          _pool.remove(host.id);
          SafeLog.d('SSH pool evicted ${host.alias} (transport closed)');
        }
      }),
    );
    _startHealthTimer();
    return client;
  }

  /// A dedicated connection the caller owns and must close itself.
  Future<SSHClient> connectExclusive(Host host) => _createClient(host);

  Future<SSHClient> _createClient(Host host, {Set<String>? visited}) async {
    final chain = {...?visited};
    if (!chain.add(host.id)) {
      throw StateError('ProxyJump cycle detected for ${host.displayLabel}');
    }

    final pem = await _secureStore.readSshPrivateKey();
    if (pem == null || pem.trim().isEmpty) {
      throw StateError('No SSH private key in secure storage. Add one in Connect.');
    }
    final passphrase = await _secureStore.readSshPassphrase();

    late List<SSHKeyPair> pairs;
    try {
      pairs = SSHKeyPair.fromPem(pem, passphrase);
    } catch (e) {
      throw StateError('Could not parse SSH private key (wrong passphrase?).');
    }

    final SSHSocket socket;
    if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) {
      final jumpHost = await _db.getHost(host.jumpHostId!);
      if (jumpHost == null) {
        throw StateError(
          'ProxyJump host is missing. Edit this host and pick a jump host again.',
        );
      }
      // The jump client is pooled too, so its lifetime is managed centrally.
      final jumpClient = await connect(jumpHost, visited: chain);
      socket = await jumpClient
          .forwardLocal(host.hostname, host.port)
          .timeout(const Duration(seconds: 20));
    } else {
      socket = await SshNoDelaySocket.connect(
        host.hostname,
        host.port,
        timeout: const Duration(seconds: 15),
      );
    }

    final client = SSHClient(
      socket,
      username: host.username,
      identities: pairs,
    );
    try {
      await client.authenticated.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException('SSH authentication timed out'),
      );
    } catch (e) {
      client.close();
      rethrow;
    }
    return client;
  }

  /// Drop a host's pooled connection (used when a health check fails).
  void invalidate(String hostId) {
    final entry = _pool.remove(hostId);
    try {
      entry?.client?.close();
    } catch (_) {}
  }

  void closeAll() {
    for (final id in _pool.keys.toList()) {
      invalidate(id);
    }
  }

  /// Actively verify pooled connections and evict the dead ones.
  ///
  /// dartssh2 pings every 10s but never times out waiting for the reply, and
  /// its in-flight guard means one lost reply silently stops all later pings.
  /// So a dead link is only noticed when TCP finally gives up, which can take
  /// minutes. This does the detection the library skips.
  Future<void> healthCheckAll() async {
    if (_pool.isEmpty) return;
    final ids = _pool.keys.toList();
    await Future.wait(
      ids.map((id) async {
        final entry = _pool[id];
        final client = entry?.client;
        if (entry == null || client == null) return;
        if (client.isClosed) {
          invalidate(id);
          return;
        }
        try {
          await client.ping().timeout(_pingTimeout);
        } catch (e) {
          SafeLog.d('SSH health check failed for $id; evicting', e);
          invalidate(id);
        }
      }),
    );
  }

  void _startHealthTimer() {
    if (_suspended || _healthTimer != null) return;
    _healthTimer = Timer.periodic(_healthInterval, (_) {
      unawaited(healthCheckAll());
    });
  }

  /// The OS is about to freeze us: stop timers and let sockets go.
  void onAppPaused() {
    _suspended = true;
    _healthTimer?.cancel();
    _healthTimer = null;
    // Sockets do not survive suspension; drop them so the next use reconnects
    // immediately instead of waiting for a dead connection to time out.
    closeAll();
  }

  /// Back in the foreground: re-verify everything before the user touches it.
  void onAppResumed() {
    _suspended = false;
    unawaited(healthCheckAll());
    _startHealthTimer();
  }

  Future<String> exec(Host host, String command) async {
    final client = await connect(host);
    return _run(client, command, hostId: host.id);
  }

  Future<String> _run(
    SSHClient client,
    String command, {
    required String hostId,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final gate = _pool[hostId]?.gate;
    Future<String> body() async {
      final session = await client.execute(command);
      try {
        // Read stdout + stderr in parallel — sequential reads can deadlock SSH channels.
        final chunks = await Future.wait<Uint8List>([
          _readAll(session.stdout),
          _readAll(session.stderr),
        ]).timeout(timeout);
        await session.done.timeout(const Duration(seconds: 5));
        final stdout = chunks[0];
        final stderr = chunks[1];
        final code = session.exitCode ?? 0;
        if (code != 0) {
          final err = utf8.decode(stderr).trim();
          throw Exception(err.isEmpty ? 'Command failed (exit $code)' : err);
        }
        return utf8.decode(stdout);
      } on TimeoutException {
        try {
          session.close();
        } catch (_) {}
        throw TimeoutException('Remote command timed out after $timeout');
      }
    }

    return gate == null ? body() : gate.run(body);
  }

  Future<Uint8List> _readAll(Stream<Uint8List> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Probe remote tools; throws [MissingToolException] with install hints.
  Future<void> ensureRemoteTools(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    await ensureTmux(host, onProgress: onProgress);
    await ensureCursorCli(host, onProgress: onProgress);
  }

  Future<void> ensureTmux(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    final client = await connect(host);
    var tmux = await _whichLogin(client, 'tmux', host.id);
    if (tmux != null) return;

    onProgress?.call('Installing tmux on the remote…');
    try {
      await _run(
        client,
        r'''
set -e
if command -v tmux >/dev/null 2>&1; then exit 0; fi
if command -v apt-get >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y tmux
elif command -v brew >/dev/null 2>&1; then
  brew install tmux
else
  echo "no package manager for tmux" >&2
  exit 1
fi
command -v tmux
''',
        hostId: host.id,
        timeout: const Duration(minutes: 5),
      );
    } catch (e) {
      SafeLog.d('tmux auto-install failed', e);
    }

    tmux = await _whichLogin(client, 'tmux', host.id);
    if (tmux == null) {
      throw MissingToolException('tmux', kRemoteTmuxSetupGuide.trim());
    }
  }

  /// True when tmux exists, without throwing.
  Future<bool> hasTmux(Host host) async {
    try {
      final client = await connect(host);
      return await _whichLogin(client, 'tmux', host.id) != null;
    } catch (_) {
      return false;
    }
  }

  /// Resolves Cursor CLI to an absolute path, installing on the host if needed.
  Future<String> ensureCursorCli(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    final client = await connect(host);
    var path = await _resolveCursorCliPath(client, host.id);
    if (path != null) return path;

    onProgress?.call('Installing Cursor CLI on the remote (this can take a few minutes)…');
    final installed = await _runAgentDockInstallScript(
      client,
      hostId: host.id,
      scriptName: 'cursor-acp.sh',
      onProgress: onProgress,
    );
    if (!installed) {
      onProgress?.call('Trying Cursor official installer…');
      try {
        await _run(
          client,
          r'''
set -e
export PATH="$HOME/.local/bin:$HOME/.cursor/bin:$PATH"
curl -fsSL https://cursor.com/install | bash
mkdir -p "$HOME/.local/bin"
if command -v agent >/dev/null 2>&1 && ! command -v cursor-agent >/dev/null 2>&1; then
  ln -sfn "$(command -v agent)" "$HOME/.local/bin/cursor-agent"
fi
command -v cursor-agent >/dev/null || command -v agent >/dev/null
''',
          hostId: host.id,
          timeout: const Duration(minutes: 5),
        );
      } catch (e) {
        SafeLog.d('Cursor official installer failed', e);
      }
    }

    path = await _resolveCursorCliPath(client, host.id);
    if (path == null) {
      throw MissingToolException(
        'Cursor Agent CLI / SDK',
        kRemoteCursorSetupGuide.trim(),
      );
    }
    onProgress?.call('Cursor CLI ready');
    return path;
  }

  /// Resolves the Claude ACP adapter, installing Claude Code + adapter if needed.
  Future<String> ensureClaudeAcpBinary(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    final client = await connect(host);
    var path = await _resolveClaudeAcpPath(client, host.id);
    if (path != null) return path;

    onProgress?.call(
      'Installing Claude Code + ACP adapter on the remote (this can take a few minutes)…',
    );
    final installed = await _runAgentDockInstallScript(
      client,
      hostId: host.id,
      scriptName: 'claude-acp.sh',
      onProgress: onProgress,
    );
    if (!installed) {
      onProgress?.call('Trying local npm/nvm install…');
      try {
        await _run(
          client,
          r'''
set -e
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
mkdir -p "$HOME/.local/bin"

if ! command -v claude >/dev/null 2>&1; then
  curl -fsSL https://claude.ai/install.sh | bash
fi

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  fi
  . "$HOME/.nvm/nvm.sh"
  nvm install --lts
fi
. "$HOME/.nvm/nvm.sh" 2>/dev/null || true

npm install -g @agentclientprotocol/claude-agent-acp \
  || npm install -g @zed-industries/claude-code-acp

NODE_BIN="$(dirname "$(command -v node)")"
PREFIX_BIN="$(npm prefix -g 2>/dev/null)/bin"
REAL=
for dir in "$NODE_BIN" "$PREFIX_BIN"; do
  [ -d "$dir" ] || continue
  [ "$(cd "$dir" && pwd -P)" = "$(cd "$HOME/.local/bin" && pwd -P)" ] && continue
  for name in claude-agent-acp claude-code-acp; do
    if [ -x "$dir/$name" ]; then REAL="$dir/$name"; break 2; fi
  done
done
[ -n "$REAL" ]

cat > "$HOME/.local/bin/claude-code-acp" <<EOF
#!/usr/bin/env bash
export NVM_DIR="\${NVM_DIR:-\$HOME/.nvm}"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
for d in "\$HOME"/.nvm/versions/node/*/bin; do
  [ -d "\$d" ] && PATH="\$d:\$PATH"
done
export PATH="\$HOME/.local/bin:\$PATH"
exec $REAL "\$@"
EOF
chmod +x "$HOME/.local/bin/claude-code-acp"
ln -sfn "$HOME/.local/bin/claude-code-acp" "$HOME/.local/bin/claude-agent-acp"
test -x "$HOME/.local/bin/claude-code-acp"
''',
          hostId: host.id,
          timeout: const Duration(minutes: 8),
        );
      } catch (e) {
        SafeLog.d('claude ACP inline install failed', e);
      }
    }

    path = await _resolveClaudeAcpPath(client, host.id);
    if (path == null) {
      throw MissingToolException(
        'Claude Code ACP adapter',
        kRemoteClaudeSetupGuide.trim(),
      );
    }
    onProgress?.call('Claude ACP ready');
    return path;
  }

  /// Installs/starts ADSM on the host and verifies it responds.
  ///
  /// Uses the GitHub `install-adsm.sh` installer only when the binary is
  /// missing. If `agentdock-adsm` already exists, we only call
  /// `ensure-running` — never the install script (it `pkill`s the daemon and
  /// can leave Connect falsely reporting "ADSM still missing").
  Future<void> ensureAdsm(
    Host host, {
    void Function(String status)? onProgress,
  }) async {
    final client = await connect(host);
    var lastProbe = '';

    Future<({bool ok, bool hasBin, String raw})> probe() async {
      try {
        final out = await _run(
          client,
          r'''
set +e
export PATH="$HOME/.local/bin:$PATH"
BIN="$(command -v agentdock-adsm 2>/dev/null)"
[ -n "$BIN" ] || BIN="$HOME/.local/bin/agentdock-adsm"

# Direct socket ping — works even when the wrapper is not on PATH.
python3 - <<'PY' 2>/dev/null
import os, socket, sys
p = os.path.expanduser("~/.agentdock/adsm.sock")
if not os.path.exists(p):
    sys.exit(2)
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
try:
    s.connect(p)
    s.sendall(b'{"id":1,"method":"ping","params":{}}\n')
    data = s.recv(8192).decode("utf-8", "replace")
    print(data.strip())
    if '"ok"' in data or "version" in data:
        print("ADSM_PROBE=ok")
        sys.exit(0)
except Exception as e:
    print(f"ADSM_SOCK_ERR={e}")
    sys.exit(1)
finally:
    try:
        s.close()
    except Exception:
        pass
sys.exit(1)
PY
SOCK_EC=$?
if [ "$SOCK_EC" -eq 0 ]; then
  exit 0
fi

if [ ! -x "$BIN" ]; then
  echo "ADSM_PROBE=missing_bin"
  exit 0
fi
echo "ADSM_BIN=$BIN"
OUT="$("$BIN" ensure-running 2>&1)"
EC=$?
printf '%s\n' "$OUT"
if [ "$EC" -eq 0 ]; then
  echo "ADSM_PROBE=ok"
else
  echo "ADSM_PROBE=ensure_failed ec=$EC"
fi
"$BIN" status 2>/dev/null | head -1 || true
exit 0
''',
          hostId: host.id,
          timeout: const Duration(seconds: 35),
        );
        lastProbe = out.trim();
        SafeLog.d('ADSM probe: $lastProbe');
        return (
          ok: out.contains('ADSM_PROBE=ok'),
          hasBin: !out.contains('ADSM_PROBE=missing_bin'),
          raw: out,
        );
      } catch (e) {
        lastProbe = e.toString();
        SafeLog.d('ADSM probe exception', e);
        return (ok: false, hasBin: false, raw: lastProbe);
      }
    }

    onProgress?.call('Checking ADSM…');
    var state = await probe();
    if (state.ok) {
      onProgress?.call('ADSM ready');
      return;
    }

    // Binary is on the host — start/repair only. Do NOT curl install-adsm.sh
    // (that script kills the live daemon and often races the next probe).
    if (state.hasBin) {
      onProgress?.call('Starting ADSM…');
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration(milliseconds: 400 + i * 250));
        state = await probe();
        if (state.ok) {
          onProgress?.call('ADSM ready');
          return;
        }
      }
      throw MissingToolException(
        'ADSM',
        '${kRemoteAdsmSetupGuide.trim()}\n\n'
        '# Probe (daemon binary found but not healthy):\n$lastProbe',
      );
    }

    onProgress?.call('Installing ADSM on the remote…');
    final installed = await _runAgentDockInstallScript(
      client,
      hostId: host.id,
      scriptName: 'install-adsm.sh',
      onProgress: onProgress,
    );
    if (!installed) {
      onProgress?.call('Starting ADSM…');
      try {
        await _run(
          client,
          r'''
set +e
export PATH="$HOME/.local/bin:$PATH"
command -v agentdock-adsm >/dev/null || exit 1
agentdock-adsm ensure-running
exit 0
''',
          hostId: host.id,
          timeout: const Duration(seconds: 45),
        );
      } catch (e) {
        SafeLog.d('ADSM ensure-running after failed install failed', e);
      }
    }

    for (var i = 0; i < 8; i++) {
      state = await probe();
      if (state.ok) {
        onProgress?.call('ADSM ready');
        return;
      }
      await Future<void>.delayed(Duration(milliseconds: 400 + i * 200));
    }

    throw MissingToolException(
      'ADSM',
      '${kRemoteAdsmSetupGuide.trim()}\n\n# Probe:\n$lastProbe',
    );
  }

  /// Downloads and runs an Agent Dock `scripts/*.sh` installer on the host.
  ///
  /// Returns false when the download/run failed so callers can try a fallback.
  Future<bool> _runAgentDockInstallScript(
    SSHClient client, {
    required String hostId,
    required String scriptName,
    void Function(String status)? onProgress,
  }) async {
    final url = '$kAgentDockScriptsBase/$scriptName';
    onProgress?.call('Downloading $scriptName…');
    try {
      await _run(
        client,
        '''
set -e
export PATH="\$HOME/.local/bin:\$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH"
[ -s "\$HOME/.nvm/nvm.sh" ] && . "\$HOME/.nvm/nvm.sh"
curl -fsSL ${shellQuote(url)} | bash
''',
        hostId: hostId,
        timeout: const Duration(minutes: 10),
      );
      return true;
    } catch (e) {
      SafeLog.d('Agent Dock install script $scriptName failed', e);
      onProgress?.call('Install script failed — trying fallback…');
      return false;
    }
  }

  Future<String?> _resolveClaudeAcpPath(SSHClient client, String hostId) async {
    try {
      final homeOut = await _run(
        client,
        r'printf %s "$HOME"',
        hostId: hostId,
        timeout: const Duration(seconds: 8),
      );
      final home = homeOut.trim();
      if (home.isNotEmpty) {
        final sftp = await client.sftp();
        for (final rel in [
          '.local/bin/claude-code-acp',
          '.local/bin/claude-agent-acp',
          '.npm-global/bin/claude-code-acp',
          '.npm-global/bin/claude-agent-acp',
        ]) {
          final full = '$home/$rel';
          try {
            await sftp.stat(full);
            return full;
          } catch (_) {}
        }
      }
    } catch (e) {
      SafeLog.d('SFTP Claude ACP probe failed, trying which', e);
    }

    const script = r'''
set +e
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
for name in claude-code-acp claude-agent-acp; do
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    exit 0
  fi
done
for p in "$HOME/.local/bin/claude-code-acp" \
         "$HOME/.local/bin/claude-agent-acp" \
         "$HOME/.npm-global/bin/claude-code-acp" \
         "$HOME/.npm-global/bin/claude-agent-acp" \
         /usr/local/bin/claude-code-acp \
         /usr/local/bin/claude-agent-acp; do
  if [ -x "$p" ]; then printf %s "$p"; exit 0; fi
done
for p in "$HOME"/.nvm/versions/node/*/bin/claude-code-acp \
         "$HOME"/.nvm/versions/node/*/bin/claude-agent-acp; do
  if [ -x "$p" ]; then printf %s "$p"; exit 0; fi
done
exit 1
''';
    try {
      final out = await _run(
        client,
        'bash -lc ${shellQuote(script)}',
        hostId: hostId,
        timeout: const Duration(seconds: 20),
      );
      final path = out.trim().split('\n').last.trim();
      return path.isEmpty ? null : path;
    } catch (e) {
      SafeLog.d('resolve Claude ACP path failed', e);
      return null;
    }
  }

  Future<String?> _resolveCursorCliPath(SSHClient client, String hostId) async {
    // Fast path: SFTP stat known install locations (no bash).
    try {
      final homeOut = await _run(
        client,
        r'printf %s "$HOME"',
        hostId: hostId,
        timeout: const Duration(seconds: 8),
      );
      final home = homeOut.trim();
      if (home.isNotEmpty) {
        final sftp = await client.sftp();
        for (final rel in [
          '.local/bin/cursor-agent',
          '.local/bin/agent',
          '.cursor/bin/cursor-agent',
          '.cursor/bin/agent',
        ]) {
          final full = '$home/$rel';
          try {
            await sftp.stat(full);
            return full;
          } catch (_) {}
        }
      }
    } catch (e) {
      SafeLog.d('SFTP Cursor probe failed, trying test -x', e);
      // Fall through to the shell probe; only give up if that fails too.
    }

    // Fallback: one short shell test (stdout+stderr read in parallel).
    const script =
        r'for p in "$HOME/.local/bin/cursor-agent" "$HOME/.local/bin/agent" '
        r'"$HOME/.cursor/bin/cursor-agent" "$HOME/.cursor/bin/agent" '
        r'/usr/local/bin/cursor-agent /usr/local/bin/agent; '
        r'do [ -x "$p" ] && printf %s "$p" && exit 0; done; exit 1';
    try {
      final out = await _run(
        client,
        'sh -c ${shellQuote(script)}',
        hostId: hostId,
        timeout: const Duration(seconds: 8),
      );
      final path = out.trim();
      return path.isEmpty ? null : path;
    } catch (e) {
      SafeLog.d('resolve Cursor CLI path failed', e);
      // A clean "not found" arrives as empty stdout above, not as an
      // exception. Anything thrown here is a dead transport — rethrow so
      // reconnect retries instead of claiming the CLI is missing.
      rethrow;
    }
  }

  Future<bool> remotePathExists(Host host, String path) async {
    try {
      final out = await exec(host, 'test -d ${shellQuote(path)} && echo OK || true');
      return out.trim() == 'OK';
    } catch (e) {
      SafeLog.d('remotePathExists failed', e);
      return false;
    }
  }

  /// Absolute home directory for the SSH user (no trailing slash, except `/`).
  Future<String> remoteHomeDirectory(Host host) async {
    final out = await exec(host, 'printf %s "\$HOME"');
    final home = out.trim();
    if (home.isEmpty) return '/';
    return home.endsWith('/') && home != '/' ? home.substring(0, home.length - 1) : home;
  }

  /// List directories (and symlink-to-dir) under [path] via SFTP.
  Future<RemoteListing> listRemoteDirectories(Host host, String path) async {
    final full = await listRemoteEntries(host, path);
    return RemoteListing(
      path: full.path,
      directories: full.entries
          .where((e) => e.isDirectory)
          .map((e) => RemoteDirEntry(name: e.name, isSymlink: e.isSymlink))
          .toList(),
    );
  }

  /// List files and directories under [path] via SFTP.
  Future<RemoteFileListing> listRemoteEntries(Host host, String path) async {
    final normalized = normalizeRemotePath(path);
    final client = await connect(host);
    final sftp = await client.sftp();
    final items = await sftp.listdir(normalized);
    final entries = <RemoteFileEntry>[];
    for (final item in items) {
      final name = item.filename;
      if (name == '.' || name == '..') continue;
      final attrs = item.attr;
      entries.add(
        RemoteFileEntry(
          name: name,
          isDirectory: attrs.isDirectory,
          isSymlink: attrs.isSymbolicLink,
          size: attrs.size,
          modifiedAt: attrs.modifyTime != null
              ? DateTime.fromMillisecondsSinceEpoch(attrs.modifyTime! * 1000)
              : null,
        ),
      );
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return RemoteFileListing(path: normalized, entries: entries);
  }

  /// Download a remote file to [localPath]. Returns bytes written.
  Future<int> downloadRemoteFile(
    Host host,
    String remotePath,
    String localPath, {
    void Function(int bytes)? onProgress,
  }) async {
    final remote = normalizeRemotePath(remotePath);
    final client = await connect(host);
    final sftp = await client.sftp();
    final file = File(localPath);
    await file.parent.create(recursive: true);
    final sink = file.openWrite();
    try {
      return await sftp.download(
        remote,
        sink,
        onProgress: onProgress,
        closeDestination: true,
      );
    } catch (e) {
      await sink.close();
      rethrow;
    }
  }

  /// Upload local bytes/file to [remotePath] (overwrites).
  Future<void> uploadRemoteFile(
    Host host,
    String localPath,
    String remotePath, {
    void Function(int bytes)? onProgress,
  }) async {
    final remote = normalizeRemotePath(remotePath);
    final bytes = await File(localPath).readAsBytes();
    final client = await connect(host);
    final sftp = await client.sftp();
    final remoteFile = await sftp.open(
      remote,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.truncate |
          SftpFileOpenMode.write,
    );
    try {
      await remoteFile.writeBytes(bytes);
      onProgress?.call(bytes.length);
    } finally {
      await remoteFile.close();
    }
  }

  Future<void> mkdirRemote(Host host, String remotePath) async {
    final remote = normalizeRemotePath(remotePath);
    final client = await connect(host);
    final sftp = await client.sftp();
    await sftp.mkdir(remote);
  }

  Future<void> removeRemoteFile(Host host, String remotePath) async {
    final remote = normalizeRemotePath(remotePath);
    final client = await connect(host);
    final sftp = await client.sftp();
    await sftp.remove(remote);
  }

  /// True if [path] is [root] or a child of [root].
  static bool isUnderRoot(String root, String path) {
    final r = normalizeRemotePath(root);
    final p = normalizeRemotePath(path);
    if (r == '/') return true;
    return p == r || p.startsWith('$r/');
  }

  static String normalizeRemotePath(String path) {
    var p = path.trim();
    if (p.isEmpty) return '/';
    if (!p.startsWith('/')) p = '/$p';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String joinRemotePath(String parent, String child) {
    final base = normalizeRemotePath(parent);
    if (base == '/') return '/$child';
    return '$base/$child';
  }

  static String? parentRemotePath(String path) {
    final normalized = normalizeRemotePath(path);
    if (normalized == '/') return null;
    final index = normalized.lastIndexOf('/');
    if (index <= 0) return '/';
    return normalized.substring(0, index);
  }

  /// `command -v` with an extended PATH (non-login; avoids hanging .bashrc).
  Future<String?> _whichLogin(SSHClient client, String binary, String hostId) async {
    final name = binary.replaceAll("'", '');
    try {
      final out = await _run(
        client,
        "bash -c ${shellQuote('export PATH="\$HOME/.local/bin:\$PATH"; command -v $name')}",
        hostId: hostId,
        timeout: const Duration(seconds: 10),
      );
      final path = out.trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  static String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  void dispose() {
    _healthTimer?.cancel();
    _healthTimer = null;
    closeAll();
  }
}

class RemoteDirEntry {
  const RemoteDirEntry({required this.name, this.isSymlink = false});

  final String name;
  final bool isSymlink;
}

class RemoteListing {
  const RemoteListing({required this.path, required this.directories});

  final String path;
  final List<RemoteDirEntry> directories;
}

class RemoteFileEntry {
  const RemoteFileEntry({
    required this.name,
    required this.isDirectory,
    this.isSymlink = false,
    this.size,
    this.modifiedAt,
  });

  final String name;
  final bool isDirectory;
  final bool isSymlink;
  final int? size;
  final DateTime? modifiedAt;

  String get sizeLabel {
    if (isDirectory || size == null) return '';
    final s = size!;
    if (s < 1024) return '$s B';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB';
    if (s < 1024 * 1024 * 1024) {
      return '${(s / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(s / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

class RemoteFileListing {
  const RemoteFileListing({required this.path, required this.entries});

  final String path;
  final List<RemoteFileEntry> entries;
}
