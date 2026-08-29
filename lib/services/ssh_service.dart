import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../data/local/app_database.dart';
import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import 'remote_setup_guide.dart';

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
  String toString() => '$tool is not installed on the remote host.\n\n$installHint';
}

/// SSH client wrapper. Secrets come from [SecureStore] only for the duration
/// of a connection attempt — never logged.
class SshService {
  SshService(this._secureStore, this._db);

  final SecureStore _secureStore;
  final AppDatabase _db;

  Future<SshConnectResult> testConnection(Host host) async {
    SSHClient? client;
    try {
      client = await connect(host);
      final out = await _run(client, 'uname -a');
      return SshConnectResult(ok: true, detail: out.trim());
    } catch (e) {
      SafeLog.d('SSH test failed for ${host.hostname}', e);
      return SshConnectResult(ok: false, error: e.toString());
    } finally {
      client?.close();
    }
  }

  Future<SSHClient> connect(Host host, {Set<String>? visited}) async {
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
    SSHClient? jumpClient;
    if (host.jumpHostId != null && host.jumpHostId!.isNotEmpty) {
      final jumpHost = await _db.getHost(host.jumpHostId!);
      if (jumpHost == null) {
        throw StateError(
          'ProxyJump host is missing. Edit this host and pick a jump host again.',
        );
      }
      jumpClient = await connect(jumpHost, visited: chain);
      try {
        socket = await jumpClient
            .forwardLocal(host.hostname, host.port)
            .timeout(const Duration(seconds: 20));
      } catch (e) {
        jumpClient.close();
        rethrow;
      }
    } else {
      socket = await SSHSocket.connect(
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
    // Authenticate promptly; don't leave callers waiting on first execute forever.
    try {
      await client.authenticated.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw TimeoutException('SSH authentication timed out');
        },
      );
    } catch (e) {
      client.close();
      jumpClient?.close();
      rethrow;
    }

    // Keep the jump tunnel alive until the target session ends.
    if (jumpClient != null) {
      final jump = jumpClient;
      unawaited(client.done.whenComplete(jump.close));
    }
    return client;
  }

  Future<String> exec(Host host, String command) async {
    final client = await connect(host);
    try {
      return await _run(client, command);
    } finally {
      client.close();
    }
  }

  Future<String> _run(
    SSHClient client,
    String command, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
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
    try {
      final tmux = await _whichLogin(client, 'tmux');
      if (tmux == null) {
        throw MissingToolException(
          'tmux',
          kRemoteTmuxSetupGuide.trim(),
        );
      }
    } finally {
      client.close();
    }
  }

  /// Resolves Cursor CLI to an **absolute** path.
  ///
  /// Prefers SFTP existence checks (fast, no shell). Falls back to a short
  /// non-login `test -x` command.
  Future<String> ensureCursorCli(Host host) async {
    final client = await connect(host);
    try {
      final path = await _resolveCursorCliPath(client);
      if (path == null) {
        throw MissingToolException(
          'Cursor Agent CLI / SDK',
          kRemoteCursorSetupGuide.trim(),
        );
      }
      return path;
    } finally {
      client.close();
    }
  }

  Future<String?> _resolveCursorCliPath(SSHClient client) async {
    // Fast path: SFTP stat known install locations (no bash).
    try {
      final homeOut = await _run(
        client,
        r'printf %s "$HOME"',
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
        timeout: const Duration(seconds: 8),
      );
      final path = out.trim();
      return path.isEmpty ? null : path;
    } catch (e) {
      SafeLog.d('resolve Cursor CLI path failed', e);
      return null;
    }
  }

  Future<bool> remotePathExists(Host host, String path) async {
    final client = await connect(host);
    try {
      final session = await client.execute('test -d ${shellQuote(path)} && echo OK');
      final out = utf8.decode(await _readAll(session.stdout)).trim();
      await session.done;
      return out == 'OK';
    } finally {
      client.close();
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
    try {
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
    } finally {
      client.close();
    }
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
    try {
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
    } finally {
      client.close();
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
    try {
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
    } finally {
      client.close();
    }
  }

  Future<void> mkdirRemote(Host host, String remotePath) async {
    final remote = normalizeRemotePath(remotePath);
    final client = await connect(host);
    try {
      final sftp = await client.sftp();
      await sftp.mkdir(remote);
    } finally {
      client.close();
    }
  }

  Future<void> removeRemoteFile(Host host, String remotePath) async {
    final remote = normalizeRemotePath(remotePath);
    final client = await connect(host);
    try {
      final sftp = await client.sftp();
      await sftp.remove(remote);
    } finally {
      client.close();
    }
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
  Future<String?> _whichLogin(SSHClient client, String binary) async {
    final name = binary.replaceAll("'", '');
    try {
      final out = await _run(
        client,
        "bash -c ${shellQuote('export PATH="\$HOME/.local/bin:\$PATH"; command -v $name')}",
        timeout: const Duration(seconds: 10),
      );
      final path = out.trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  static String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";
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
