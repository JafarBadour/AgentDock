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
  Future<void> ensureRemoteTools(Host host) async {
    await ensureTmux(host);
    await ensureCursorCli(host);
  }

  Future<void> ensureTmux(Host host) async {
    final client = await connect(host);
    final tmux = await _whichLogin(client, 'tmux', host.id);
    if (tmux == null) {
      throw MissingToolException('tmux', kRemoteTmuxSetupGuide.trim());
    }
  }

  /// True when tmux exists, without throwing.
  Future<bool> hasTmux(Host host) async {
    try {
      await ensureTmux(host);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Resolves Cursor CLI to an **absolute** path.
  ///
  /// Prefers SFTP existence checks (fast, no shell). Falls back to a short
  /// non-login `test -x` command.
  Future<String> ensureCursorCli(Host host) async {
    final client = await connect(host);
    final path = await _resolveCursorCliPath(client, host.id);
    if (path == null) {
      throw MissingToolException(
        'Cursor Agent CLI / SDK',
        kRemoteCursorSetupGuide.trim(),
      );
    }
    return path;
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
