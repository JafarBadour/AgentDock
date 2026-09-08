import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../data/local/app_database.dart';
import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import 'adsm_version.dart';
import 'local_host_bootstrap.dart';
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

enum _BundledAdsmPush { ok, noAssets, failed }

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
  if (text.contains('adsm channel closed') ||
      text.contains('adsm closed') ||
      text.contains('adsm write failed') ||
      text.contains('acp connection closed') ||
      text.contains('acp connection error') ||
      text.contains('acp stdin closed') ||
      text.contains('connection closed') ||
      text.contains('transport is closed') ||
      text.contains('channel open') ||
      text.contains('broken pipe') ||
      text.contains('connection reset') ||
      text.contains('socketexception')) {
    return SshFailureKind.network;
  }
  return SshFailureKind.unknown;
}

/// True when the ADSM/ACP/SSH bridge dropped and auto-reconnect should handle it
/// without a sticky red banner.
bool isTransientBridgeError(Object error) {
  if (classifySshFailure(error) == SshFailureKind.network) return true;
  return isTransientBridgeErrorText(error.toString());
}

bool isTransientBridgeErrorText(String text) {
  final t = text.toLowerCase();
  return t.contains('adsm channel closed') ||
      t.contains('adsm closed') ||
      t.contains('adsm write failed') ||
      t.contains('acp connection closed') ||
      t.contains('acp connection error') ||
      t.contains('acp stdin closed') ||
      t.contains('connection closed') ||
      t.contains('transport is closed') ||
      t.contains('broken pipe') ||
      t.contains('connection reset');
}

/// Claude/Cursor OAuth or API key rejected — user must re-authenticate.
bool isAgentAuthFailureText(String text) {
  final t = text.toLowerCase();
  return t.contains('authentication_failed') ||
      t.contains('errorkind\': \'authentication') ||
      t.contains('"errorkind":"authentication') ||
      t.contains('oauth access token has expired') ||
      t.contains('re-authenticate') ||
      t.contains('reauthenticate') ||
      (t.contains('401') &&
          (t.contains('oauth') ||
              t.contains('token') ||
              t.contains('unauthorized') ||
              t.contains('authenticate'))) ||
      t.contains('not logged in') ||
      t.contains('please run /login') ||
      t.contains('claude auth login') ||
      t.contains('agent login');
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

  /// Hosts whose ADSM already meets [kRequiredAdsmVersion] this process.
  /// Avoids re-uploading / restarting the daemon on every chat reconnect.
  final Map<String, String> _adsmVerifiedVersion = {};

  /// Serializes [ensureAdsm] per host so parallel chats cannot double-upgrade.
  final Map<String, Future<void>> _adsmEnsureInflight = {};

  static const _healthInterval = Duration(seconds: 45);
  static const _pingTimeout = Duration(seconds: 6);

  /// True when this app already verified the host at the required ADSM version.
  bool isAdsmReady(String hostId) {
    final v = _adsmVerifiedVersion[hostId];
    return v != null && adsmVersionMeets(v, kRequiredAdsmVersion);
  }

  void _markAdsmReady(String hostId, String version) {
    _adsmVerifiedVersion[hostId] = version;
  }

  void clearAdsmReady(String hostId) {
    _adsmVerifiedVersion.remove(hostId);
  }

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
  Future<SSHClient> connectExclusive(Host host) async {
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return await _createClient(host, exclusive: true);
      } catch (e) {
        lastError = e;
        if (!_isRetryableChannelOpenError(e) || attempt == 1) {
          throw _friendlySshOpenError(e);
        }
        SafeLog.d(
          'SSH exclusive connect retry after channel open failure '
          'for ${host.displayLabel}',
          e,
        );
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
    }
    throw _friendlySshOpenError(lastError ?? StateError('SSH open failed'));
  }

  static bool _isRetryableChannelOpenError(Object e) {
    final t = e.toString().toLowerCase();
    return e is SSHChannelOpenError ||
        t.contains('open failed') ||
        t.contains('sshchannelopenerror') ||
        t.contains('administratively prohibited');
  }

  static Object _friendlySshOpenError(Object e) {
    if (!_isRetryableChannelOpenError(e)) return e;
    return StateError(
      'SSH open failed — too many sessions on this host (or its jump host). '
      'Close unused terminals/agents and retry. ($e)',
    );
  }

  Future<SSHClient> _createClient(
    Host host, {
    Set<String>? visited,
    bool exclusive = false,
  }) async {
    final chain = {...?visited};
    if (!chain.add(host.id)) {
      throw StateError('ProxyJump cycle detected for ${host.displayLabel}');
    }

    final password = await _secureStore.readHostPassword(host.id);
    final usePassword = password != null && password.isNotEmpty;

    List<SSHKeyPair>? pairs;
    if (!usePassword) {
      var pem = await _secureStore.readSshPrivateKey();
      // Local this-computer host: fall back to ~/.ssh/id_* so coding on the
      // same Mac/PC works without pasting a key into Connect first.
      if ((pem == null || pem.trim().isEmpty) && isLocalThisComputerHost(host)) {
        pem = await readDefaultSshPrivateKeyPem();
      }
      if (pem == null || pem.trim().isEmpty) {
        throw StateError(
          isLocalThisComputerHost(host)
              ? 'No SSH key for this computer. Enable Remote Login (Mac) or '
                  'OpenSSH Server (Windows), then add your key in Connect, '
                  'or set a password on this host. Default ~/.ssh/id_ed25519 '
                  'or id_rsa is also tried automatically.'
              : 'No SSH private key in Connect, and no password on this host. '
                  'Add a key in Connect or set a password when editing the host.',
        );
      }
      final passphrase = await _secureStore.readSshPassphrase();
      try {
        pairs = SSHKeyPair.fromPem(
          pem,
          (passphrase != null && passphrase.isNotEmpty) ? passphrase : null,
        );
      } catch (e) {
        throw StateError(
          'Could not parse SSH private key (wrong passphrase?).',
        );
      }
    }

    final SSHSocket socket;
    SSHClient? ownedJump;
    if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) {
      final jumpHost = await _db.getHost(host.jumpHostId!);
      if (jumpHost == null) {
        throw StateError(
          'ProxyJump host is missing. Edit this host and pick a jump host again.',
        );
      }
      // Long-lived exclusive sessions must not burn direct-tcpip channels on
      // the shared jump pool (that is what surfaces as "ssh open failed"
      // when a second agent connects while another is busy).
      final SSHClient jumpClient;
      if (exclusive) {
        ownedJump = await _createClient(
          jumpHost,
          visited: chain,
          exclusive: true,
        );
        jumpClient = ownedJump;
      } else {
        jumpClient = await connect(jumpHost, visited: chain);
      }
      try {
        socket = await jumpClient
            .forwardLocal(host.hostname, host.port)
            .timeout(const Duration(seconds: 20));
      } catch (e) {
        try {
          ownedJump?.close();
        } catch (_) {}
        rethrow;
      }
    } else {
      try {
        socket = await SshNoDelaySocket.connect(
          host.hostname,
          host.port,
          timeout: const Duration(seconds: 15),
        );
      } catch (e) {
        if (isLocalThisComputerHost(host)) {
          throw StateError(describeLocalHostConnectError(e, host));
        }
        rethrow;
      }
    }

    final client = SSHClient(
      socket,
      username: host.username,
      identities: pairs,
      onPasswordRequest: usePassword ? () => password : null,
    );
    try {
      await client.authenticated.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException('SSH authentication timed out'),
      );
    } catch (e) {
      try {
        client.close();
      } catch (_) {}
      try {
        ownedJump?.close();
      } catch (_) {}
      rethrow;
    }
    if (ownedJump != null) {
      final jump = ownedJump;
      unawaited(
        client.done.whenComplete(() {
          try {
            jump.close();
          } catch (_) {}
        }),
      );
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
    var tmux = await _resolveTmuxPath(client, host.id);
    if (tmux != null) return;

    onProgress?.call('Installing tmux on the remote…');
    try {
      await _run(
        client,
        r'''
set -e
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
if command -v tmux >/dev/null 2>&1; then command -v tmux; exit 0; fi

# Environment modules (common on HPC — no sudo).
if [ -f /etc/profile.d/modules.sh ]; then . /etc/profile.d/modules.sh; fi
if [ -f /usr/share/lmod/lmod/init/bash ]; then . /usr/share/lmod/lmod/init/bash; fi
if command -v module >/dev/null 2>&1; then
  module load tmux 2>/dev/null || true
  module load tools/tmux 2>/dev/null || true
  module load app/tmux 2>/dev/null || true
  if command -v tmux >/dev/null 2>&1; then command -v tmux; exit 0; fi
fi

# User-local conda/mamba (also no sudo).
if command -v conda >/dev/null 2>&1; then
  conda install -y -c conda-forge tmux </dev/null && command -v tmux && exit 0
fi
if command -v mamba >/dev/null 2>&1; then
  mamba install -y -c conda-forge tmux </dev/null && command -v tmux && exit 0
fi

# System package managers (need sudo / brew).
if command -v apt-get >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y tmux
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y tmux
elif command -v brew >/dev/null 2>&1; then
  brew install tmux
elif command -v zypper >/dev/null 2>&1; then
  sudo zypper install -y tmux
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

    tmux = await _resolveTmuxPath(client, host.id);
    if (tmux == null) {
      throw MissingToolException('tmux', kRemoteTmuxSetupGuide.trim());
    }
  }

  /// Locate tmux via PATH, known paths, and HPC environment modules.
  Future<String?> _resolveTmuxPath(SSHClient client, String hostId) async {
    const script = r'''
set +e
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
if command -v tmux >/dev/null 2>&1; then command -v tmux; exit 0; fi
for p in /usr/bin/tmux /usr/local/bin/tmux /opt/homebrew/bin/tmux \
         "$HOME/.local/bin/tmux"; do
  if [ -x "$p" ]; then printf %s "$p"; exit 0; fi
done
if [ -f /etc/profile.d/modules.sh ]; then . /etc/profile.d/modules.sh; fi
if [ -f /usr/share/lmod/lmod/init/bash ]; then . /usr/share/lmod/lmod/init/bash; fi
if [ -f /usr/share/Modules/init/bash ]; then . /usr/share/Modules/init/bash; fi
if command -v module >/dev/null 2>&1; then
  module load tmux 2>/dev/null || true
  module load tools/tmux 2>/dev/null || true
  module load app/tmux 2>/dev/null || true
  if command -v tmux >/dev/null 2>&1; then command -v tmux; exit 0; fi
fi
exit 1
''';
    try {
      final out = await _run(
        client,
        'bash -lc ${shellQuote(script)}',
        hostId: hostId,
        timeout: const Duration(seconds: 25),
      );
      final path = out.trim().split('\n').last.trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  /// True when tmux exists, without throwing.
  Future<bool> hasTmux(Host host) async {
    try {
      final client = await connect(host);
      return await _resolveTmuxPath(client, host.id) != null;
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

  Future<String> _runWithInstallProgress(
    SSHClient client,
    String command, {
    required String hostId,
    Duration timeout = const Duration(minutes: 10),
    void Function(String status)? onProgress,
  }) async {
    final gate = _pool[hostId]?.gate;
    Future<String> body() async {
      final session = await client.execute(command);
      final stdout = StringBuffer();
      final stderr = StringBuffer();

      void pushLine(String source, String line) {
        if (source == 'out') {
          stdout.writeln(line);
        } else {
          stderr.writeln(line);
        }
        final t = line.trim();
        if (t.startsWith('==> ')) {
          onProgress?.call(t.substring(4));
        } else if (t.startsWith('✓ ')) {
          onProgress?.call(t.substring(2));
        }
      }

      Future<void> drain(Stream<Uint8List> stream, String source) async {
        final carry = StringBuffer();
        await for (final chunk in stream) {
          carry.write(utf8.decode(chunk, allowMalformed: true));
          var text = carry.toString();
          var idx = text.indexOf('\n');
          while (idx >= 0) {
            pushLine(source, text.substring(0, idx));
            text = text.substring(idx + 1);
            idx = text.indexOf('\n');
          }
          carry
            ..clear()
            ..write(text);
        }
        final tail = carry.toString();
        if (tail.isNotEmpty) pushLine(source, tail);
      }

      try {
        await Future.wait<void>([
          drain(session.stdout, 'out'),
          drain(session.stderr, 'err'),
        ]).timeout(timeout);
        await session.done.timeout(const Duration(seconds: 5));
        final code = session.exitCode ?? 0;
        if (code != 0) {
          final err = stderr.toString().trim();
          throw Exception(
            err.isEmpty ? 'Command failed (exit $code)' : err,
          );
        }
        return stdout.toString();
      } on TimeoutException {
        try {
          session.close();
        } catch (_) {}
        throw TimeoutException('Remote command timed out after $timeout');
      }
    }

    return gate == null ? body() : gate.run(body);
  }

  static const _claudeInlineInstall = r'''
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

cat > "$HOME/.local/bin/claude-code-acp" <<'EOF'
#!/usr/bin/env bash
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
for d in "$HOME"/.nvm/versions/node/*/bin; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH="$HOME/.local/bin:$PATH"
EOF
printf 'exec %q "$@"\n' "$REAL" >> "$HOME/.local/bin/claude-code-acp"
chmod +x "$HOME/.local/bin/claude-code-acp"
ln -sfn "$HOME/.local/bin/claude-code-acp" "$HOME/.local/bin/claude-agent-acp"
test -x "$HOME/.local/bin/claude-code-acp"
''';

  Future<void> _tryClaudeInlineInstall(
    SSHClient client, {
    required String hostId,
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Installing Claude ACP adapter (npm)…');
    await _runWithInstallProgress(
      client,
      _claudeInlineInstall,
      hostId: hostId,
      timeout: const Duration(minutes: 12),
      onProgress: onProgress,
    );
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
      'First Claude setup on this host — usually 3–8 minutes…',
    );

    // Fast path: npm/nvm only (tmux + ADSM are handled separately).
    try {
      await _tryClaudeInlineInstall(
        client,
        hostId: host.id,
        onProgress: onProgress,
      );
      path = await _resolveClaudeAcpPath(client, host.id);
      if (path != null) {
        onProgress?.call('Claude ACP ready');
        return path;
      }
    } catch (e) {
      SafeLog.d('claude ACP inline install failed', e);
      onProgress?.call('Inline install failed — trying full setup script…');
    }

    final installed = await _runAgentDockInstallScript(
      client,
      hostId: host.id,
      scriptName: 'claude-acp.sh',
      onProgress: onProgress,
      timeout: const Duration(minutes: 15),
    );
    if (!installed) {
      onProgress?.call('Retrying npm install…');
      try {
        await _tryClaudeInlineInstall(
          client,
          hostId: host.id,
          onProgress: onProgress,
        );
      } catch (e) {
        SafeLog.d('claude ACP inline install retry failed', e);
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

  /// Installs/starts ADSM on the host and verifies it responds at
  /// [kRequiredAdsmVersion] or newer.
  ///
  /// Prefers uploading the ADSM package bundled with this app. GitHub is only
  /// used when this build has no ADSM assets (should not happen in release).
  ///
  /// Set [allowUpgrade] to false on reconnects so we never restart the daemon
  /// mid-chat — that was killing the shared bridge and causing reconnect loops.
  Future<void> ensureAdsm(
    Host host, {
    void Function(String status)? onProgress,
    bool allowUpgrade = true,
  }) async {
    final prev = _adsmEnsureInflight[host.id];
    final run = () async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      await _ensureAdsmBody(
        host,
        onProgress: onProgress,
        allowUpgrade: allowUpgrade,
      );
    }();
    _adsmEnsureInflight[host.id] = run;
    try {
      await run;
    } finally {
      if (identical(_adsmEnsureInflight[host.id], run)) {
        _adsmEnsureInflight.remove(host.id);
      }
    }
  }

  Future<void> _ensureAdsmBody(
    Host host, {
    void Function(String status)? onProgress,
    required bool allowUpgrade,
  }) async {
    var client = await connect(host);
    var lastProbe = '';

    Future<SSHClient> refreshClient() async {
      invalidate(host.id);
      client = await connect(host);
      return client;
    }

    bool transportDead(Object e) {
      final t = e.toString().toLowerCase();
      return t.contains('transport is closed') ||
          t.contains('connection reset') ||
          t.contains('broken pipe') ||
          t.contains('socket has been shut down');
    }

    Future<({bool ok, bool hasBin, String? version, String raw})> probe() async {
      try {
        if (client.isClosed) await refreshClient();
        final out = await _run(
          client,
          r'''
set +e
export PATH="$HOME/.local/bin:$PATH"
BIN="$(command -v agentdock-adsm 2>/dev/null)"
[ -n "$BIN" ] || BIN="$HOME/.local/bin/agentdock-adsm"

# Direct socket ping — works even when the wrapper is not on PATH.
python3 - <<'PY' 2>/dev/null
import json, os, socket, sys
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
    ver = ""
    try:
        msg = json.loads(data.strip().splitlines()[0])
        ver = str((msg.get("result") or {}).get("version") or "")
    except Exception:
        pass
    if ver:
        print(f"ADSM_VERSION={ver}")
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
# Re-ping after ensure-running for version.
python3 - <<'PY' 2>/dev/null
import json, os, socket, sys
p = os.path.expanduser("~/.agentdock/adsm.sock")
if not os.path.exists(p):
    sys.exit(0)
s = socket.socket(socket.AF_UNIX)
s.settimeout(3)
try:
    s.connect(p)
    s.sendall(b'{"id":1,"method":"ping","params":{}}\n')
    data = s.recv(8192).decode("utf-8", "replace")
    print(data.strip())
    msg = json.loads(data.strip().splitlines()[0])
    ver = str((msg.get("result") or {}).get("version") or "")
    if ver:
        print(f"ADSM_VERSION={ver}")
except Exception:
    pass
finally:
    try:
        s.close()
    except Exception:
        pass
PY
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
        String? version;
        for (final line in out.split('\n')) {
          final t = line.trim();
          if (t.startsWith('ADSM_VERSION=')) {
            version = t.substring('ADSM_VERSION='.length).trim();
            if (version.isEmpty) version = null;
          }
        }
        // Fallback: parse version from status / ping JSON line.
        if (version == null) {
          final m = RegExp(r'"version"\s*:\s*"([^"]+)"').firstMatch(out);
          if (m != null) version = m.group(1);
        }
        return (
          ok: out.contains('ADSM_PROBE=ok'),
          hasBin: !out.contains('ADSM_PROBE=missing_bin'),
          version: version,
          raw: out,
        );
      } catch (e) {
        lastProbe = e.toString();
        SafeLog.d('ADSM probe exception', e);
        if (transportDead(e)) {
          try {
            await refreshClient();
          } catch (_) {}
        }
        return (ok: false, hasBin: false, version: null, raw: lastProbe);
      }
    }

    Future<void> installOrUpgrade({required String reason}) async {
      onProgress?.call(reason);
      if (client.isClosed || transportDead(lastProbe)) {
        await refreshClient();
      }
      // Ship this app's ADSM first — GitHub main can lag a local version bump.
      final push = await _pushBundledAdsm(
        client,
        hostId: host.id,
        onProgress: onProgress,
      );
      if (push == _BundledAdsmPush.ok) return;

      if (push == _BundledAdsmPush.failed) {
        throw MissingToolException(
          'ADSM',
          'Could not upload the ADSM package bundled with this app '
          '(v$kRequiredAdsmVersion). GitHub install was skipped because '
          'main can lag this build and would restart the daemon on every '
          'retry.\n\nCheck SSH/SFTP to the host and reconnect.\n\n'
          '# Probe:\n$lastProbe',
        );
      }

      // Assets missing from this build — last resort.
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
    }

    Future<bool> waitForRequired({int attempts = 10}) async {
      for (var i = 0; i < attempts; i++) {
        await Future<void>.delayed(Duration(milliseconds: 400 + i * 200));
        final state = await probe();
        if (state.ok &&
            adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
          _markAdsmReady(host.id, state.version!);
          onProgress?.call('ADSM ready (v${state.version})');
          return true;
        }
        onProgress?.call(
          'Waiting for ADSM v$kRequiredAdsmVersion… '
          '(host reports ${state.version ?? "unknown"})',
        );
      }
      return false;
    }

    onProgress?.call('Checking ADSM…');
    var state = await probe();

    // Healthy + new enough → done.
    if (state.ok && adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
      _markAdsmReady(host.id, state.version!);
      onProgress?.call('ADSM ready (v${state.version})');
      return;
    }

    // Reconnect / soft path: keep a working daemon alive; never pkill.
    if (!allowUpgrade || isAdsmReady(host.id)) {
      if (state.ok) {
        onProgress?.call(
          'ADSM v${state.version ?? "unknown"} running '
          '(app prefers v$kRequiredAdsmVersion) — continuing',
        );
        return;
      }
      if (state.hasBin) {
        onProgress?.call('Starting ADSM…');
        state = await probe(); // ensure-running is inside probe path
        if (state.ok) {
          if (adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
            _markAdsmReady(host.id, state.version!);
          }
          onProgress?.call('ADSM ready (v${state.version ?? "unknown"})');
          return;
        }
      }
      throw MissingToolException(
        'ADSM',
        'ADSM is not running on the host and upgrade was skipped '
        '(reconnect path).\n\n# Probe:\n$lastProbe',
      );
    }

    // Running but too old (or version unknown on an old build).
    if (state.ok &&
        !adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
      final have = state.version ?? 'unknown';
      await installOrUpgrade(
        reason:
            'ADSM mismatch — host has v$have, this app needs '
            'v$kRequiredAdsmVersion. Updating…',
      );
      if (await waitForRequired()) return;
      throw MissingToolException(
        'ADSM',
        'ADSM mismatch — cannot run until the host is on '
        'v$kRequiredAdsmVersion (host still reports '
        '${state.version ?? "unknown"}).\n'
        'Open this agent again to retry the automatic update.\n\n'
        '# Probe:\n$lastProbe',
      );
    }

    // Binary present but daemon not healthy — start/repair only first.
    if (state.hasBin) {
      onProgress?.call('Starting ADSM…');
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration(milliseconds: 400 + i * 250));
        state = await probe();
        if (state.ok &&
            adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
          _markAdsmReady(host.id, state.version!);
          onProgress?.call('ADSM ready (v${state.version})');
          return;
        }
        if (state.ok &&
            !adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
          break; // fall through to upgrade
        }
      }
      if (state.ok &&
          !adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
        final have = state.version ?? 'unknown';
        await installOrUpgrade(
          reason:
              'ADSM mismatch — host has v$have, this app needs '
              'v$kRequiredAdsmVersion. Updating…',
        );
        if (await waitForRequired()) return;
      } else if (!state.ok) {
        throw MissingToolException(
          'ADSM',
          '${kRemoteAdsmSetupGuide.trim()}\n\n'
          '# Probe (daemon binary found but not healthy):\n$lastProbe',
        );
      }
    }

    // Missing binary, dead probe, or upgrade path above failed — push/install.
    if (!state.hasBin ||
        !adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
      await installOrUpgrade(
        reason: state.hasBin
            ? 'ADSM mismatch — updating host to v$kRequiredAdsmVersion…'
            : 'Installing ADSM on the remote…',
      );
    }

    if (await waitForRequired()) return;

    state = await probe();
    if (state.ok &&
        !adsmVersionMeets(state.version, kRequiredAdsmVersion)) {
      throw MissingToolException(
        'ADSM',
        'ADSM mismatch — cannot run. Host is still '
        'v${state.version ?? "unknown"}; this app needs v$kRequiredAdsmVersion.\n'
        'Reconnect to retry the automatic update.\n\n# Probe:\n$lastProbe',
      );
    }

    throw MissingToolException(
      'ADSM',
      '${kRemoteAdsmSetupGuide.trim()}\n\n# Probe:\n$lastProbe',
    );
  }

  static const _bundledAdsmFiles = <String>[
    '__init__.py',
    '__main__.py',
    'paths.py',
    'protocol.py',
    'worker.py',
    'daemon.py',
    'cli.py',
    'scheduler.py',
    'transcript.py',
  ];

  Future<Map<String, Uint8List>> _loadBundledAdsmPayloads() async {
    final payloads = <String, Uint8List>{};
    for (final name in _bundledAdsmFiles) {
      final data = await rootBundle.load('host/adsm/$name');
      payloads[name] = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
    }
    return payloads;
  }

  static const _adsmWrapper = '''
#!/usr/bin/env bash
export PYTHONPATH="\$HOME/.local/share/agentdock/host\${PYTHONPATH:+:\$PYTHONPATH}"
exec python3 -m adsm "\$@"
''';

  static const _adsmRestartScript = r'''
set -e
chmod +x "$HOME/.local/bin/agentdock-adsm"
export PATH="$HOME/.local/bin:$PATH"
pkill -f 'python3 -m adsm serve' 2>/dev/null || true
pkill -f 'python -m adsm serve' 2>/dev/null || true
sleep 0.3
rm -f "$HOME/.agentdock/adsm.sock" 2>/dev/null || true
agentdock-adsm ensure-running
''';

  /// Upload bundled ADSM. Prefer stdin/base64 (reliable over ProxyJump);
  /// SFTP is a fallback. GitHub is only used when assets are missing.
  Future<_BundledAdsmPush> _pushBundledAdsm(
    SSHClient client, {
    required String hostId,
    void Function(String status)? onProgress,
  }) async {
    onProgress?.call('Uploading ADSM v$kRequiredAdsmVersion from this app…');
    late final Map<String, Uint8List> payloads;
    try {
      payloads = await _loadBundledAdsmPayloads();
    } catch (e) {
      SafeLog.d('Bundled ADSM assets missing from this build', e);
      onProgress?.call('App ADSM assets missing — trying GitHub…');
      return _BundledAdsmPush.noAssets;
    }

    try {
      await _pushBundledAdsmViaStdin(
        client,
        hostId: hostId,
        payloads: payloads,
      );
      onProgress?.call('ADSM v$kRequiredAdsmVersion uploaded');
      return _BundledAdsmPush.ok;
    } catch (e) {
      SafeLog.d('ADSM stdin upload failed, trying SFTP', e);
      onProgress?.call('Retrying ADSM upload over SFTP…');
    }

    try {
      await _pushBundledAdsmViaSftp(
        client,
        hostId: hostId,
        payloads: payloads,
      );
      onProgress?.call('ADSM v$kRequiredAdsmVersion uploaded');
      return _BundledAdsmPush.ok;
    } catch (e) {
      SafeLog.d('Bundled ADSM upload failed', e);
      onProgress?.call('Bundled ADSM upload failed');
      return _BundledAdsmPush.failed;
    }
  }

  Future<void> _runScriptViaStdin(
    SSHClient client, {
    required String hostId,
    required String script,
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final gate = _pool[hostId]?.gate;
    Future<void> body() async {
      final session = await client.execute('bash -s');
      try {
        session.stdin.add(utf8.encode(script));
        await session.stdin.close();
        final chunks = await Future.wait<Uint8List>([
          _readAll(session.stdout),
          _readAll(session.stderr),
        ]).timeout(timeout);
        await session.done.timeout(const Duration(seconds: 10));
        final code = session.exitCode ?? 0;
        if (code != 0) {
          final err = utf8.decode(chunks[1]).trim();
          final out = utf8.decode(chunks[0]).trim();
          final detail = err.isNotEmpty ? err : out;
          throw Exception(
            detail.isEmpty ? 'Remote script failed (exit $code)' : detail,
          );
        }
      } on TimeoutException {
        try {
          session.close();
        } catch (_) {}
        throw TimeoutException('Remote script timed out after $timeout');
      }
    }

    return gate == null ? body() : gate.run(body);
  }

  Future<void> _pushBundledAdsmViaStdin(
    SSHClient client, {
    required String hostId,
    required Map<String, Uint8List> payloads,
  }) async {
    final buf = StringBuffer()
      ..writeln('set -euo pipefail')
      ..writeln('SHARE="\$HOME/.local/share/agentdock/host/adsm"')
      ..writeln('BIN="\$HOME/.local/bin"')
      ..writeln('mkdir -p "\$SHARE" "\$BIN"');
    for (final entry in payloads.entries) {
      buf
        ..writeln('base64 -d > "\$SHARE/${entry.key}" <<\'ADSM_B64\'')
        ..writeln(base64Encode(entry.value))
        ..writeln('ADSM_B64');
    }
    buf
      ..writeln('cat > "\$BIN/agentdock-adsm" <<\'ADSM_WRAP\'')
      ..writeln(_adsmWrapper.trimRight())
      ..writeln('ADSM_WRAP')
      ..writeln(_adsmRestartScript);
    await _runScriptViaStdin(
      client,
      hostId: hostId,
      script: buf.toString(),
      timeout: const Duration(minutes: 3),
    );
  }

  Future<void> _pushBundledAdsmViaSftp(
    SSHClient client, {
    required String hostId,
    required Map<String, Uint8List> payloads,
  }) async {
    final homeOut = await _run(
      client,
      r'printf %s "$HOME"',
      hostId: hostId,
      timeout: const Duration(seconds: 8),
    );
    final home = homeOut.trim();
    if (home.isEmpty) {
      throw Exception('Could not resolve remote HOME');
    }

    final share = '$home/.local/share/agentdock/host/adsm';
    final binDir = '$home/.local/bin';
    await _run(
      client,
      'mkdir -p ${shellQuote(share)} ${shellQuote(binDir)}',
      hostId: hostId,
      timeout: const Duration(seconds: 10),
    );

    final sftp = await client.sftp();
    try {
      for (final entry in payloads.entries) {
        final remote = '$share/${entry.key}';
        final remoteFile = await sftp.open(
          remote,
          mode: SftpFileOpenMode.create |
              SftpFileOpenMode.truncate |
              SftpFileOpenMode.write,
        );
        try {
          await remoteFile.writeBytes(entry.value);
        } finally {
          await remoteFile.close();
        }
      }

      final wrapperPath = '$binDir/agentdock-adsm';
      final wrapperFile = await sftp.open(
        wrapperPath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        await wrapperFile.writeBytes(
          Uint8List.fromList(utf8.encode(_adsmWrapper)),
        );
      } finally {
        await wrapperFile.close();
      }
    } finally {
      sftp.close();
    }

    await _run(
      client,
      _adsmRestartScript,
      hostId: hostId,
      timeout: const Duration(seconds: 45),
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
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final url = '$kAgentDockScriptsBase/$scriptName';
    onProgress?.call('Running $scriptName on the remote…');
    try {
      await _runWithInstallProgress(
        client,
        '''
set -e
export AGENTDOCK_SKIP_TMUX=1
export AGENTDOCK_SKIP_ADSM=1
export PATH="\$HOME/.local/bin:\$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH"
[ -s "\$HOME/.nvm/nvm.sh" ] && . "\$HOME/.nvm/nvm.sh"
curl -fsSL ${shellQuote(url)} | bash
''',
        hostId: hostId,
        timeout: timeout,
        onProgress: onProgress,
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
  ///
  /// Uses a **dedicated** SSH connection (not the pooled ADSM/agent link) so
  /// agent traffic cannot starve SFTP. Multipart pipelining is used for large
  /// files; if progress stalls, the transfer is aborted and retried once with
  /// a single in-flight read (more reliable on some HPC SSHDs).
  ///
  /// Always re-stats the remote file for length — directory listing sizes can
  /// be wrong and previously caused truncated/corrupt archives.
  Future<int> downloadRemoteFile(
    Host host,
    String remotePath,
    String localPath, {
    void Function(int bytes, int? total)? onProgress,
    int? totalBytes,
    bool multipart = true,
    bool Function()? isCancelled,
  }) async {
    final remote = normalizeRemotePath(remotePath);
    try {
      return await _downloadRemoteFileOnce(
        host,
        remote,
        localPath,
        onProgress: onProgress,
        totalBytes: totalBytes,
        multipart: multipart,
        isCancelled: isCancelled,
        maxPending: multipart ? 8 : 1,
      );
    } on _DownloadStalled catch (e) {
      SafeLog.d(
        'download stalled at ${e.bytesRead}B — retrying sequential '
        '$remote',
        e,
      );
      if (isCancelled?.call() == true) throw const _DownloadCancelled();
      onProgress?.call(0, e.total);
      return _downloadRemoteFileOnce(
        host,
        remote,
        localPath,
        onProgress: onProgress,
        totalBytes: e.total ?? totalBytes,
        multipart: false,
        isCancelled: isCancelled,
        maxPending: 1,
        chunkSize: 128 * 1024,
      );
    }
  }

  Future<int> _downloadRemoteFileOnce(
    Host host,
    String remote,
    String localPath, {
    void Function(int bytes, int? total)? onProgress,
    int? totalBytes,
    bool multipart = true,
    bool Function()? isCancelled,
    int maxPending = 8,
    int chunkSize = 64 * 1024,
  }) async {
    // Exclusive session: file transfer must not share the ADSM event channel.
    final client = await connectExclusive(host);
    final local = File(localPath);
    await local.parent.create(recursive: true);

    var lastProgressAt = DateTime.now();
    var lastBytes = 0;
    var progressTotal = totalBytes;
    Timer? stallWatch;
    var stalled = false;

    void armStallWatch() {
      stallWatch?.cancel();
      stallWatch = Timer.periodic(const Duration(seconds: 5), (_) {
        if (isCancelled?.call() == true) {
          try {
            client.close();
          } catch (_) {}
          return;
        }
        final idle = DateTime.now().difference(lastProgressAt);
        // HPC links can pause between chunks; 45s with zero movement is stuck.
        if (idle >= const Duration(seconds: 45) && lastBytes > 0) {
          stalled = true;
          SafeLog.d(
            'SFTP download stall ${idle.inSeconds}s at $lastBytes '
            'of ${progressTotal ?? '?'} — closing exclusive SSH',
          );
          try {
            client.close();
          } catch (_) {}
        }
      });
    }

    try {
      final sftp = await client.sftp();
      final remoteFile = await sftp.open(remote, mode: SftpFileOpenMode.read);
      try {
        final attrs = await remoteFile.stat();
        final actualTotal = attrs.size ?? totalBytes;
        if (actualTotal == null || actualTotal < 0) {
          throw StateError('Cannot determine remote file size for $remote');
        }
        progressTotal = actualTotal;
        if (actualTotal == 0) {
          await local.writeAsBytes(const []);
          onProgress?.call(0, 0);
          return 0;
        }

        onProgress?.call(0, actualTotal);
        armStallWatch();

        final large = actualTotal >= (1 << 20); // 1 MiB
        final useMultipart = multipart && large;
        final pending = useMultipart ? maxPending : 1;

        final raf = await local.open(mode: FileMode.write);
        try {
          await raf.truncate(0);
          final written = await remoteFile.downloadToRandomAccess(
            raf,
            length: actualTotal,
            onProgress: (bytes) {
              if (isCancelled?.call() == true) {
                throw const _DownloadCancelled();
              }
              if (bytes > lastBytes) {
                lastBytes = bytes;
                lastProgressAt = DateTime.now();
              }
              onProgress?.call(bytes, actualTotal);
            },
            chunkSize: chunkSize,
            maxPendingRequests: pending,
          );
          await raf.flush();
          await raf.close();

          if (written != actualTotal) {
            try {
              await local.delete();
            } catch (_) {}
            throw StateError(
              'Download incomplete: got $written of $actualTotal bytes',
            );
          }

          final onDisk = await local.length();
          if (onDisk != actualTotal) {
            try {
              await local.delete();
            } catch (_) {}
            throw StateError(
              'Download size mismatch: file is $onDisk, expected $actualTotal',
            );
          }

          return written;
        } on _DownloadCancelled {
          try {
            await raf.close();
          } catch (_) {}
          try {
            if (await local.exists()) await local.delete();
          } catch (_) {}
          rethrow;
        } catch (e) {
          try {
            await raf.close();
          } catch (_) {}
          try {
            if (await local.exists()) await local.delete();
          } catch (_) {}
          if (stalled || _looksLikeSshDrop(e)) {
            throw _DownloadStalled(bytesRead: lastBytes, total: actualTotal);
          }
          rethrow;
        }
      } finally {
        try {
          await remoteFile.close();
        } catch (_) {}
      }
    } finally {
      stallWatch?.cancel();
      try {
        client.close();
      } catch (_) {}
    }
  }

  static bool _looksLikeSshDrop(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('closed') ||
        s.contains('socket') ||
        s.contains('connection') ||
        s.contains('broken pipe') ||
        (s.contains('sftp') && s.contains('error'));
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
  // ignore: unused_element
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

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();

  @override
  String toString() => 'Download cancelled';
}

class _DownloadStalled implements Exception {
  const _DownloadStalled({required this.bytesRead, this.total});

  final int bytesRead;
  final int? total;

  @override
  String toString() =>
      'Download stalled after $bytesRead bytes'
      '${total != null ? ' of $total' : ''}';
}
