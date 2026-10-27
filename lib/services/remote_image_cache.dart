import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import 'ssh_service.dart';

/// Why an image the agent pointed at could not be shown inline.
enum RemoteImageFailure {
  /// No such file, or it could not be stat'd on the host.
  missing,

  /// Larger than [RemoteImageCache.maxBytes] — offered as a tap instead of
  /// being pulled down the SSH channel and decoded on the UI isolate.
  tooLarge,

  /// The transfer itself failed (channel dropped, permissions, …).
  transferFailed,
}

/// A resolved inline image: either a local file to render, or why not.
class RemoteImageResult {
  const RemoteImageResult.ready(this.localPath, this.bytes)
    : failure = null;
  const RemoteImageResult.failed(this.failure, {this.bytes})
    : localPath = null;

  final String? localPath;
  final RemoteImageFailure? failure;

  /// Size on the host, when it was known. Lets the UI say "4.2 MB — open".
  final int? bytes;

  bool get isReady => localPath != null;
}

/// Stat one remote path, or null when it is not there.
typedef RemoteStat = Future<RemoteFileEntry?> Function(Host host, String path);

/// Copy a remote file to [localPath], returning the bytes written.
typedef RemoteDownload =
    Future<int> Function(
      Host host,
      String remotePath,
      String localPath, {
      int? totalBytes,
    });

/// Local copies of images an agent referenced, so the transcript can show
/// them inline.
///
/// Inline images are rendered from a file on disk rather than from bytes in
/// the message. Base64 bodies in transcript rows are what `stripInlineImages`
/// exists to remove: a few dozen of them made chats tens of MB, all parsed,
/// synced and re-encoded on the UI isolate. The row keeps the path; the
/// picture lives here.
///
/// Keyed on the host's own (size, mtime), so an agent that regenerates a
/// chart under the same name gets re-fetched rather than served a stale copy.
class RemoteImageCache {
  RemoteImageCache({
    required RemoteStat stat,
    required RemoteDownload download,
    Future<Directory> Function()? cacheRoot,
  }) : _stat = stat,
       _download = download,
       _cacheRoot = cacheRoot ?? getTemporaryDirectory;

  /// Wired to a live [SshService].
  factory RemoteImageCache.of(SshService ssh) => RemoteImageCache(
    stat: ssh.statRemoteFile,
    download: (host, remotePath, localPath, {int? totalBytes}) =>
        ssh.downloadRemoteFile(
          host,
          remotePath,
          localPath,
          totalBytes: totalBytes,
          multipart: false,
        ),
  );

  final RemoteStat _stat;
  final RemoteDownload _download;
  final Future<Directory> Function() _cacheRoot;

  /// Biggest image pulled down for an inline preview.
  static const int maxBytes = 16 * 1024 * 1024;

  /// Total the cache directory may hold before the oldest files are pruned.
  static const int budgetBytes = 256 * 1024 * 1024;

  /// Concurrent transfers. Scrolling past a chat full of charts should not
  /// open twenty SSH channels at once.
  static const int _maxConcurrent = 3;

  /// Recent answers, so a row rebuilding mid-scroll does not spend an SSH
  /// round-trip re-stat'ing a picture it already has. Short enough that an
  /// agent regenerating a chart still shows up without restarting the app.
  static const Duration recheckAfter = Duration(seconds: 30);

  final _recent = <String, (DateTime, RemoteImageResult)>{};
  final _inFlight = <String, Future<RemoteImageResult>>{};
  final _waiting = <Completer<void>>[];
  int _active = 0;
  Directory? _dir;
  bool _pruned = false;

  /// A local file for [remotePath] on [host], fetching it if needed.
  ///
  /// Repeat calls for the same (path, size, mtime) share one transfer, so a
  /// row that rebuilds mid-download does not start a second one.
  Future<RemoteImageResult> resolve(Host host, String remotePath) async {
    final memo = '${host.id}|$remotePath';
    final seen = _recent[memo];
    if (seen != null && _now().difference(seen.$1) < recheckAfter) {
      final result = seen.$2;
      // Only trust a hit whose file is still on disk; the OS may clear temp.
      if (!result.isReady || File(result.localPath!).existsSync()) {
        return result;
      }
      _recent.remove(memo);
    }
    final result = await _resolveFresh(host, remotePath);
    _recent[memo] = (_now(), result);
    return result;
  }

  /// Overridable so a test can age the memo without waiting.
  DateTime Function() _now = DateTime.now;

  @visibleForTesting
  // ignore: use_setters_to_change_properties
  void debugSetClock(DateTime Function() now) => _now = now;

  Future<RemoteImageResult> _resolveFresh(Host host, String remotePath) async {
    final stat = await _statQuietly(host, remotePath);
    if (stat == null || stat.isDirectory) {
      return const RemoteImageResult.failed(RemoteImageFailure.missing);
    }
    final size = stat.size;
    if (size != null && size > maxBytes) {
      return RemoteImageResult.failed(
        RemoteImageFailure.tooLarge,
        bytes: size,
      );
    }

    final key = _key(host, remotePath, stat);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _fetch(host, remotePath, key, size);
    _inFlight[key] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<RemoteFileEntry?> _statQuietly(Host host, String remotePath) async {
    try {
      return await _stat(host, remotePath);
    } catch (e) {
      SafeLog.d('inline image stat failed $remotePath', e);
      return null;
    }
  }

  Future<RemoteImageResult> _fetch(
    Host host,
    String remotePath,
    String key,
    int? size,
  ) async {
    final dir = await _cacheDir();
    final file = File('${dir.path}/$key');
    if (await file.exists() && await file.length() > 0) {
      return RemoteImageResult.ready(file.path, size);
    }

    await _acquire();
    try {
      // Re-check: a sibling may have finished it while we waited for a slot.
      if (await file.exists() && await file.length() > 0) {
        return RemoteImageResult.ready(file.path, size);
      }
      final tmp = File('${file.path}.part');
      await _download(host, remotePath, tmp.path, totalBytes: size);
      if (!await tmp.exists() || await tmp.length() == 0) {
        await _quietDelete(tmp);
        return const RemoteImageResult.failed(
          RemoteImageFailure.transferFailed,
        );
      }
      final got = await tmp.length();
      if (got > maxBytes) {
        // The host under-reported, or the file grew mid-transfer.
        await _quietDelete(tmp);
        return RemoteImageResult.failed(
          RemoteImageFailure.tooLarge,
          bytes: got,
        );
      }
      await tmp.rename(file.path);
      unawaited(_pruneOnce());
      return RemoteImageResult.ready(file.path, got);
    } catch (e) {
      SafeLog.d('inline image fetch failed $remotePath', e);
      return const RemoteImageResult.failed(
        RemoteImageFailure.transferFailed,
      );
    } finally {
      _release();
    }
  }

  Future<void> _acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    final gate = Completer<void>();
    _waiting.add(gate);
    await gate.future;
    _active++;
  }

  void _release() {
    _active--;
    if (_waiting.isEmpty) return;
    _waiting.removeAt(0).complete();
  }

  /// Stable name from what identifies the bytes, keeping the extension so
  /// `Image.file` and the share sheet still see a `.png`.
  String _key(Host host, String remotePath, RemoteFileEntry stat) {
    final seed =
        '${host.id}|$remotePath|${stat.size ?? -1}|'
        '${stat.modifiedAt?.microsecondsSinceEpoch ?? -1}';
    final digest = sha256.convert(utf8.encode(seed)).toString().substring(0, 32);
    final dot = remotePath.lastIndexOf('.');
    final slash = remotePath.lastIndexOf('/');
    final ext = (dot > slash && dot < remotePath.length - 1)
        ? remotePath.substring(dot).toLowerCase()
        : '';
    // An extension is attacker-adjacent data (it comes from agent output), so
    // keep only a short alphanumeric suffix rather than anything path-like.
    final safeExt = RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(ext) ? ext : '';
    return '$digest$safeExt';
  }

  Future<Directory> _cacheDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await _cacheRoot();
    final dir = Directory('${base.path}/agentdock_chat_images');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// Drop the oldest files once the directory passes [budgetBytes]. Runs at
  /// most once per app run — this is a temp dir the OS may clear anyway.
  Future<void> _pruneOnce() async {
    if (_pruned) return;
    _pruned = true;
    try {
      final dir = await _cacheDir();
      final files = <(File, FileStat)>[];
      var total = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        total += stat.size;
        files.add((entity, stat));
      }
      if (total <= budgetBytes) return;
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, stat) in files) {
        if (total <= budgetBytes) break;
        await _quietDelete(file);
        total -= stat.size;
      }
    } catch (e) {
      SafeLog.d('inline image prune failed', e);
    }
  }

  Future<void> _quietDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
