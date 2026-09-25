import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/secure/safe_log.dart';

/// Starts a download into [localPath]; returns bytes written.
typedef DownloadStarter = Future<int> Function(
  String localPath,
  void Function(int received, int? total) onProgress,
  bool Function() isCancelled,
);

/// Files at or above this size always get a save-location + progress dialog.
const int kLargeDownloadBytes = 1 << 20; // 1 MiB

/// Public Downloads folder when we can write there, otherwise null.
Future<Directory?> publicDownloadsDir() async {
  if (Platform.isAndroid) {
    // Shared Downloads the Files app shows — not the app-private one.
    final public = Directory('/storage/emulated/0/Download');
    try {
      if (!await public.exists()) {
        await public.create(recursive: true);
      }
      // Probe write access before claiming this is usable.
      final probe = File(
        p.join(
          public.path,
          '.agentdock_write_probe_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await probe.writeAsString('ok');
      await probe.delete();
      return public;
    } catch (e) {
      SafeLog.d('public Downloads unavailable', e);
    }
  }
  try {
    final d = await getDownloadsDirectory();
    if (d != null) {
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }
  } catch (e) {
    SafeLog.d('getDownloadsDirectory failed', e);
  }
  return null;
}

/// A free path for [fileName] inside [dir], suffixing on collision.
Future<String> uniquePathIn(Directory dir, String fileName) async {
  var localPath = p.join(dir.path, fileName);
  if (!await File(localPath).exists()) return localPath;
  final stem = p.basenameWithoutExtension(fileName);
  final ext = p.extension(fileName);
  return p.join(
    dir.path,
    '$stem-${DateTime.now().millisecondsSinceEpoch}$ext',
  );
}

Future<String?> pickSaveLocation(String fileName) {
  return FilePicker.saveFile(dialogTitle: 'Save $fileName', fileName: fileName);
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// A temp path for a downloaded copy, safe to hand to a viewer or Share.
Future<String> cacheFilePath(String fileName) async {
  final cache = await getTemporaryDirectory();
  return uniquePathIn(cache, fileName);
}

void showSavedSnack(BuildContext context, String name, String localPath) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Saved $name'),
      action: SnackBarAction(
        label: 'Share',
        onPressed: () {
          SharePlus.instance.share(
            ShareParams(files: [XFile(localPath, name: name)], subject: name),
          );
        },
      ),
      duration: const Duration(seconds: 6),
    ),
  );
}

/// Copy an already-downloaded [localPath] to Downloads (or a chosen location).
///
/// Returns the destination, or null when the user cancelled. Throws if the
/// copy itself fails, so callers can offer "Save as…" instead.
Future<String?> saveFileCopy(
  String localPath,
  String fileName, {
  bool askWhere = false,
}) async {
  final size = await File(localPath).length();
  String? dest;
  if (size >= kLargeDownloadBytes || askWhere) {
    dest = await pickSaveLocation(fileName);
  } else {
    final dir = await publicDownloadsDir();
    dest = dir != null
        ? await uniquePathIn(dir, fileName)
        : await pickSaveLocation(fileName);
  }
  if (dest == null || dest.isEmpty) return null;
  final parent = Directory(p.dirname(dest));
  if (!await parent.exists()) {
    await parent.create(recursive: true);
  }
  await File(localPath).copy(dest);
  return dest;
}

/// Download into the cache with a modal progress bar, for viewing or sharing.
///
/// Returns the local path, or null if the user cancelled or it failed (the
/// failure is surfaced in the dialog itself).
Future<String?> fetchFileToCache(
  BuildContext context, {
  required String fileName,
  required String action,
  int? totalBytes,
  required DownloadStarter onStartDownload,
}) async {
  final localPath = await cacheFilePath(fileName);
  if (!context.mounted) return null;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _CacheDownloadDialog(
      fileName: fileName,
      action: action,
      localPath: localPath,
      totalBytes: totalBytes,
      onStartDownload: onStartDownload,
    ),
  );
  return ok == true ? localPath : null;
}

class _CacheDownloadDialog extends StatefulWidget {
  const _CacheDownloadDialog({
    required this.fileName,
    required this.action,
    required this.localPath,
    required this.totalBytes,
    required this.onStartDownload,
  });

  final String fileName;
  final String action;
  final String localPath;
  final int? totalBytes;
  final DownloadStarter onStartDownload;

  @override
  State<_CacheDownloadDialog> createState() => _CacheDownloadDialogState();
}

class _CacheDownloadDialogState extends State<_CacheDownloadDialog> {
  int _received = 0;
  int? _total;
  bool _cancelling = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _total = widget.totalBytes;
    _run();
  }

  Future<void> _run() async {
    try {
      await widget.onStartDownload(
        widget.localPath,
        (received, total) {
          if (!mounted || _cancelling) return;
          setState(() {
            _received = received;
            _total = total ?? _total;
          });
        },
        () => _cancelling,
      );
      if (!mounted) return;
      Navigator.of(context).pop(!_cancelling);
    } catch (e) {
      if (!mounted) return;
      if (_cancelling || e.toString().contains('cancelled')) {
        Navigator.of(context).pop(false);
        return;
      }
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _total;
    final progress =
        total != null && total > 0 ? (_received / total).clamp(0.0, 1.0) : null;
    final failed = _error != null;
    return AlertDialog(
      title: Text(widget.action),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.fileName, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          if (failed)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            )
          else ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(
              total != null && total > 0
                  ? '${formatBytes(_received)} / ${formatBytes(total)}'
                      '${_cancelling ? ' · Cancelling…' : ''}'
                  : '${formatBytes(_received)} downloaded'
                      '${_cancelling ? ' · Cancelling…' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _cancelling
              ? null
              : () {
                  if (failed) {
                    Navigator.of(context).pop(false);
                  } else {
                    setState(() => _cancelling = true);
                  }
                },
          child: Text(failed ? 'Close' : 'Cancel'),
        ),
      ],
    );
  }
}

/// Choose save path, then multipart-download with a live progress bar.
class FileDownloadDialog extends StatefulWidget {
  const FileDownloadDialog({
    super.key,
    required this.fileName,
    required this.sizeLabel,
    required this.totalBytes,
    required this.initialPath,
    required this.onStartDownload,
    this.pickSavePath = pickSaveLocation,
  });

  final String fileName;
  final String sizeLabel;
  final int? totalBytes;
  final String? initialPath;
  final Future<String?> Function(String fileName) pickSavePath;
  final DownloadStarter onStartDownload;

  @override
  State<FileDownloadDialog> createState() => _FileDownloadDialogState();
}

class _FileDownloadDialogState extends State<FileDownloadDialog> {
  late final TextEditingController _pathCtrl;
  bool _running = false;
  bool _cancelling = false;
  int _received = 0;
  String? _error;
  String _modeLabel = 'multipart';
  DateTime? _lastProgressAt;
  Timer? _stallUiTimer;
  int _stallSeconds = 0;

  @override
  void initState() {
    super.initState();
    _pathCtrl = TextEditingController(text: widget.initialPath ?? '');
  }

  @override
  void dispose() {
    _stallUiTimer?.cancel();
    _pathCtrl.dispose();
    super.dispose();
  }

  void _armStallUi() {
    _stallUiTimer?.cancel();
    _stallUiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_running || _cancelling) return;
      final at = _lastProgressAt;
      if (at == null) return;
      final idle = DateTime.now().difference(at).inSeconds;
      if (idle != _stallSeconds) {
        setState(() => _stallSeconds = idle);
      }
    });
  }

  Future<void> _browse() async {
    final picked = await widget.pickSavePath(widget.fileName);
    if (picked == null || picked.isEmpty || !mounted) return;
    setState(() => _pathCtrl.text = picked);
  }

  Future<void> _start() async {
    var path = _pathCtrl.text.trim();
    if (path.isEmpty) {
      final picked = await widget.pickSavePath(widget.fileName);
      if (picked == null || picked.isEmpty || !mounted) return;
      path = picked;
      setState(() => _pathCtrl.text = path);
    }
    setState(() {
      _running = true;
      _cancelling = false;
      _error = null;
      _received = 0;
      _stallSeconds = 0;
      _modeLabel = 'multipart';
      _lastProgressAt = DateTime.now();
    });
    _armStallUi();
    try {
      final parent = Directory(p.dirname(path));
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      await widget.onStartDownload(
        path,
        (received, _) {
          if (!mounted || _cancelling) return;
          setState(() {
            if (received < _received) {
              // Auto-retry restarted from 0.
              _modeLabel = 'retry · sequential';
            }
            _received = received;
            _lastProgressAt = DateTime.now();
            _stallSeconds = 0;
          });
        },
        () => _cancelling,
      );
      if (!mounted) return;
      _stallUiTimer?.cancel();
      if (_cancelling) {
        Navigator.of(context).pop();
        return;
      }
      Navigator.of(context).pop(path);
    } catch (e) {
      if (!mounted) return;
      _stallUiTimer?.cancel();
      final msg = e.toString();
      if (_cancelling || msg.contains('cancelled')) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        _running = false;
        _error = msg.contains('stalled')
            ? 'Transfer stalled — tap Download to try again'
            : msg;
      });
    }
  }

  void _cancel() {
    if (!_running) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _cancelling = true);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.totalBytes;
    final progress = total != null && total > 0
        ? (_received / total).clamp(0.0, 1.0)
        : null;
    final stalledHint = _running && _stallSeconds >= 15;

    return AlertDialog(
      title: const Text('Download'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.fileName,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              widget.sizeLabel,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Text(
              'Save to',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pathCtrl,
                    enabled: !_running,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'Choose a location…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Browse',
                  onPressed: _running ? null : _browse,
                  icon: const Icon(Icons.folder_open),
                ),
              ],
            ),
            if (_running) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 8),
              Text(
                total != null && total > 0
                    ? '${formatBytes(_received)} / ${formatBytes(total)}'
                        '${progress != null ? ' · ${(progress * 100).toStringAsFixed(0)}%' : ''}'
                        '${_cancelling ? ' · Cancelling…' : ' · $_modeLabel'}'
                    : '${formatBytes(_received)} downloaded'
                        '${_cancelling ? ' · Cancelling…' : ' · $_modeLabel'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (stalledHint && !_cancelling) ...[
                const SizedBox(height: 8),
                Text(
                  'No progress for ${_stallSeconds}s — waiting, or Cancel and retry',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
              ],
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cancelling ? null : _cancel,
          child: Text(_running ? 'Cancel' : 'Close'),
        ),
        FilledButton(
          onPressed: _running ? null : _start,
          child: Text(_error != null ? 'Retry' : 'Download'),
        ),
      ],
    );
  }
}
