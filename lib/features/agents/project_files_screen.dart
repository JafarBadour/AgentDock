import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/platform_layout.dart';
import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/secure/safe_log.dart';
import '../../services/ssh_service.dart';
import 'pdf_viewer_screen.dart';

/// Browse / download / upload files under a project root on [host].
class ProjectFilesScreen extends ConsumerStatefulWidget {
  const ProjectFilesScreen({
    super.key,
    required this.host,
    required this.rootPath,
    this.title,
    this.embedded = false,
  });

  final Host host;
  final String rootPath;
  final String? title;

  /// When true (desktop right panel), omit the full-window AppBar.
  final bool embedded;

  static Future<void> open(
    BuildContext context, {
    required Host host,
    required String rootPath,
    String? title,
  }) {
    if (useDesktopShell(context)) {
      final container = ProviderScope.containerOf(context);
      container.read(desktopProjectFilesProvider.notifier).state =
          DesktopProjectFilesArgs(
        host: host,
        rootPath: rootPath,
        title: title,
      );
      container.read(desktopRightPanelProvider.notifier).state =
          DesktopRightPanel.files;
      return Future.value();
    }
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProjectFilesScreen(
          host: host,
          rootPath: rootPath,
          title: title,
        ),
      ),
    );
  }

  @override
  ConsumerState<ProjectFilesScreen> createState() => _ProjectFilesScreenState();
}

class _ProjectFilesScreenState extends ConsumerState<ProjectFilesScreen> {
  late String _root;
  String? _path;
  List<RemoteFileEntry> _entries = const [];
  bool _loading = true;
  bool _busy = false;
  String? _status;
  String? _error;
  int? _downloadReceived;
  int? _downloadTotal;

  /// When set (desktop embedded), the folder list stays mounted underneath and
  /// this PDF replaces the panel body until the user goes back.
  String? _pdfLocalPath;
  String? _pdfTitle;
  RemoteFileEntry? _pdfEntry;

  @override
  void initState() {
    super.initState();
    _root = SshService.normalizeRemotePath(widget.rootPath);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _load(_root);
  }

  Future<void> _load(String path) async {
    final target = SshService.normalizeRemotePath(path);
    if (!SshService.isUnderRoot(_root, target)) {
      setState(() => _error = 'Outside project root');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await ref.read(sshServiceProvider).listRemoteEntries(
            widget.host,
            target,
          );
      if (!mounted) return;
      setState(() {
        _path = listing.path;
        _entries = listing.entries;
        _loading = false;
      });
    } catch (e) {
      SafeLog.d('project files list failed', e);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not open $target\n$e';
      });
    }
  }

  Future<void> _goUp() async {
    final parent = SshService.parentRemotePath(_path ?? _root);
    if (parent == null) return;
    if (!SshService.isUnderRoot(_root, parent)) return;
    await _load(parent);
  }

  Future<void> _openDir(String name) async {
    final next = SshService.joinRemotePath(_path ?? _root, name);
    await _load(next);
  }

  /// Public Downloads folder when we can write there, otherwise null.
  Future<Directory?> _publicDownloadsDir() async {
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

  Future<String> _uniquePathIn(Directory dir, String fileName) async {
    var localPath = p.join(dir.path, fileName);
    if (!await File(localPath).exists()) return localPath;
    final stem = p.basenameWithoutExtension(fileName);
    final ext = p.extension(fileName);
    return p.join(
      dir.path,
      '$stem-${DateTime.now().millisecondsSinceEpoch}$ext',
    );
  }

  /// Files at or above this size always get a save-location + progress dialog.
  static const _largeDownloadBytes = 1 << 20; // 1 MiB

  Future<String?> _pickSavePath(String fileName) async {
    return FilePicker.saveFile(
      dialogTitle: 'Save $fileName',
      fileName: fileName,
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _download(
    RemoteFileEntry entry, {
    bool askWhere = false,
  }) async {
    if (entry.isDirectory) return;
    final remote = SshService.joinRemotePath(_path ?? _root, entry.name);
    final total = entry.size;
    // Unknown size or ≥1 MiB / explicit Save as → location picker + progress.
    final large =
        total == null || total >= _largeDownloadBytes || askWhere;

    // Large downloads (or explicit Save as): pick location + progress dialog.
    if (large) {
      await _downloadWithDialog(entry, remote, total);
      return;
    }

    String? localPath;
    final dir = await _publicDownloadsDir();
    if (dir != null) {
      localPath = await _uniquePathIn(dir, entry.name);
    } else {
      localPath = await _pickSavePath(entry.name);
      if (localPath == null || localPath.isEmpty) return;
    }

    setState(() {
      _busy = true;
      _status = 'Downloading ${entry.name}…';
      _downloadReceived = 0;
      _downloadTotal = total;
    });
    try {
      final parent = Directory(p.dirname(localPath));
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      final bytes = await ref.read(sshServiceProvider).downloadRemoteFile(
            widget.host,
            remote,
            localPath,
            totalBytes: total,
            onProgress: (received, tot) {
              if (!mounted) return;
              setState(() {
                _downloadReceived = received;
                _downloadTotal = tot ?? total;
                final t = _downloadTotal;
                _status = t != null && t > 0
                    ? 'Downloading ${entry.name}… '
                        '${_formatBytes(received)} / ${_formatBytes(t)}'
                    : 'Downloading ${entry.name}… ${_formatBytes(received)}';
              });
            },
          );
      if (!mounted) return;
      setState(() => _status = 'Saved $bytes bytes → $localPath');
      _showDownloadedSnack(entry.name, localPath);
    } catch (e) {
      SafeLog.d('download failed', e);
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Could not write Downloads — pick a location'),
          action: SnackBarAction(
            label: 'Save as',
            onPressed: () => _download(entry, askWhere: true),
          ),
        ),
      );
      return;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloadReceived = null;
          _downloadTotal = null;
        });
      }
    }
  }

  Future<void> _downloadWithDialog(
    RemoteFileEntry entry,
    String remote,
    int? total,
  ) async {
    String? suggested;
    final dir = await _publicDownloadsDir();
    if (dir != null) {
      suggested = await _uniquePathIn(dir, entry.name);
    }

    if (!mounted) return;
    final savedPath = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _FileDownloadDialog(
        fileName: entry.name,
        sizeLabel: entry.sizeLabel.isNotEmpty
            ? entry.sizeLabel
            : (total != null ? _formatBytes(total) : 'Unknown size'),
        totalBytes: total,
        initialPath: suggested,
        pickSavePath: _pickSavePath,
        onStartDownload: (localPath, onProgress, isCancelled) {
          return ref.read(sshServiceProvider).downloadRemoteFile(
                widget.host,
                remote,
                localPath,
                totalBytes: total,
                multipart: true,
                onProgress: onProgress,
                isCancelled: isCancelled,
              );
        },
      ),
    );
    if (!mounted || savedPath == null) return;
    setState(() => _status = 'Saved → $savedPath');
    _showDownloadedSnack(entry.name, savedPath);
  }

  Future<void> _saveLocalCopy(
    String localPath,
    String fileName, {
    bool askWhere = false,
  }) async {
    // Treat local copies of large PDFs like downloads — ask where + show size.
    final size = await File(localPath).length();
    if (size >= _largeDownloadBytes || askWhere) {
      final dest = await _pickSavePath(fileName);
      if (dest == null || dest.isEmpty) return;
      setState(() {
        _busy = true;
        _status = 'Saving $fileName…';
      });
      try {
        final parent = Directory(p.dirname(dest));
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }
        await File(localPath).copy(dest);
        if (!mounted) return;
        setState(() => _status = 'Saved → $dest');
        _showDownloadedSnack(fileName, dest);
      } catch (e) {
        SafeLog.d('save local copy failed', e);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    String? dest;
    final dir = await _publicDownloadsDir();
    if (dir != null) {
      dest = await _uniquePathIn(dir, fileName);
    } else {
      dest = await _pickSavePath(fileName);
      if (dest == null || dest.isEmpty) return;
    }
    setState(() {
      _busy = true;
      _status = 'Saving $fileName…';
    });
    try {
      final parent = Directory(p.dirname(dest));
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      await File(localPath).copy(dest);
      if (!mounted) return;
      setState(() => _status = 'Saved → $dest');
      _showDownloadedSnack(fileName, dest);
    } catch (e) {
      SafeLog.d('save local copy failed', e);
      if (!mounted) return;
      if (!askWhere) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Could not write Downloads — pick a location'),
            action: SnackBarAction(
              label: 'Save as',
              onPressed: () =>
                  _saveLocalCopy(localPath, fileName, askWhere: true),
            ),
          ),
        );
        return;
      }
      setState(() => _status = 'Save failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(RemoteFileEntry entry) async {
    if (entry.isDirectory) return;
    final remote = SshService.joinRemotePath(_path ?? _root, entry.name);
    setState(() {
      _busy = true;
      _status = 'Preparing ${entry.name}…';
    });
    try {
      final cache = await getTemporaryDirectory();
      final localPath = await _uniquePathIn(cache, entry.name);
      await ref.read(sshServiceProvider).downloadRemoteFile(
            widget.host,
            remote,
            localPath,
          );
      if (!mounted) return;
      setState(() => _status = 'Sharing ${entry.name}…');
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(localPath, name: entry.name)],
          subject: entry.name,
        ),
      );
      if (!mounted) return;
      setState(() => _status = 'Shared ${entry.name}');
    } catch (e) {
      SafeLog.d('share failed', e);
      if (!mounted) return;
      setState(() => _status = 'Share failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showDownloadedSnack(String name, String localPath) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Saved $name'),
        action: SnackBarAction(
          label: 'Share',
          onPressed: () {
            SharePlus.instance.share(
              ShareParams(
                files: [XFile(localPath, name: name)],
                subject: name,
              ),
            );
          },
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  Future<void> _upload() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final dir = _path ?? _root;
    setState(() {
      _busy = true;
      _status = 'Uploading…';
    });
    final ssh = ref.read(sshServiceProvider);
    var ok = 0;
    try {
      for (final f in result.files) {
        final local = f.path;
        if (local == null) continue;
        final name = f.name;
        final remote = SshService.joinRemotePath(dir, name);
        setState(() => _status = 'Uploading $name…');
        await ssh.uploadRemoteFile(widget.host, local, remote);
        ok++;
      }
      if (!mounted) return;
      setState(() => _status = 'Uploaded $ok file(s)');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Uploaded $ok file(s)')),
      );
      await _load(dir);
    } catch (e) {
      SafeLog.d('upload failed', e);
      if (!mounted) return;
      setState(() => _status = 'Upload failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Upload failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _mkdir() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final remote = SshService.joinRemotePath(_path ?? _root, name);
    setState(() {
      _busy = true;
      _status = 'Creating $name…';
    });
    try {
      await ref.read(sshServiceProvider).mkdirRemote(widget.host, remote);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Created $name')),
      );
      await _load(_path ?? _root);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(RemoteFileEntry entry) async {
    if (entry.isDirectory) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Delete folders from Terminal for now.')),
      );
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text('Delete ${entry.name} on the remote?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final remote = SshService.joinRemotePath(_path ?? _root, entry.name);
    setState(() {
      _busy = true;
      _status = 'Deleting ${entry.name}…';
    });
    try {
      await ref.read(sshServiceProvider).removeRemoteFile(widget.host, remote);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted ${entry.name}')),
      );
      await _load(_path ?? _root);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _closePdf() {
    setState(() {
      _pdfLocalPath = null;
      _pdfTitle = null;
      _pdfEntry = null;
      _status = null;
    });
  }

  Future<void> _viewPdf(RemoteFileEntry entry) async {
    if (entry.isDirectory || !_isPdf(entry.name)) return;
    final remote = SshService.joinRemotePath(_path ?? _root, entry.name);
    final total = entry.size;
    setState(() {
      _busy = true;
      _status = 'Opening ${entry.name}…';
      _downloadReceived = 0;
      _downloadTotal = total;
    });
    try {
      final cache = await getTemporaryDirectory();
      final localPath = await _uniquePathIn(cache, entry.name);
      await ref.read(sshServiceProvider).downloadRemoteFile(
            widget.host,
            remote,
            localPath,
            totalBytes: total,
            multipart: true,
            onProgress: (received, tot) {
              if (!mounted) return;
              setState(() {
                _downloadReceived = received;
                _downloadTotal = tot ?? total;
                final t = _downloadTotal;
                _status = t != null && t > 0
                    ? 'Opening ${entry.name}… '
                        '${_formatBytes(received)} / ${_formatBytes(t)}'
                    : 'Opening ${entry.name}… ${_formatBytes(received)}';
              });
            },
          );
      if (!mounted) return;
      setState(() {
        _status = entry.name;
        _busy = false;
        _downloadReceived = null;
        _downloadTotal = null;
      });
      if (widget.embedded) {
        setState(() {
          _pdfLocalPath = localPath;
          _pdfTitle = entry.name;
          _pdfEntry = entry;
        });
        return;
      }
      await PdfViewerScreen.open(
        context,
        filePath: localPath,
        title: entry.name,
        onDownload: () {
          _saveLocalCopy(localPath, entry.name, askWhere: true);
        },
      );
    } catch (e) {
      SafeLog.d('pdf open failed', e);
      if (!mounted) return;
      setState(() => _status = 'Could not open PDF: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open PDF: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloadReceived = null;
          _downloadTotal = null;
        });
      }
    }
  }

  static bool _isPdf(String name) =>
      p.extension(name).toLowerCase() == '.pdf';

  IconData _iconFor(RemoteFileEntry entry) {
    if (entry.isDirectory) {
      return entry.isSymlink ? Icons.link : Icons.folder_outlined;
    }
    if (_isPdf(entry.name)) return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  void _showEntryMenu(RemoteFileEntry entry) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(entry.name),
              subtitle: Text(
                [
                  if (entry.isDirectory) 'Folder' else 'File',
                  if (entry.sizeLabel.isNotEmpty) entry.sizeLabel,
                ].join(' · '),
              ),
            ),
            if (!entry.isDirectory && _isPdf(entry.name))
              ListTile(
                leading: const Icon(Icons.picture_as_pdf_outlined),
                title: const Text('View PDF'),
                onTap: () {
                  Navigator.pop(context);
                  _viewPdf(entry);
                },
              ),
            if (!entry.isDirectory && _isPdf(entry.name))
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download PDF'),
                subtitle: const Text('Save to Downloads'),
                onTap: () {
                  Navigator.pop(context);
                  _download(entry);
                },
              ),
            if (!entry.isDirectory) ...[
              if (!_isPdf(entry.name))
                ListTile(
                  leading: const Icon(Icons.download),
                  title: const Text('Download'),
                  subtitle: const Text('Save to Downloads'),
                  onTap: () {
                    Navigator.pop(context);
                    _download(entry);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('Save as…'),
                subtitle: const Text('Choose where to save'),
                onTap: () {
                  Navigator.pop(context);
                  _download(entry, askWhere: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.ios_share),
                title: const Text('Share…'),
                subtitle: const Text('Send via another app'),
                onTap: () {
                  Navigator.pop(context);
                  _share(entry);
                },
              ),
            ],
            if (entry.isDirectory)
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('Open'),
                onTap: () {
                  Navigator.pop(context);
                  _openDir(entry.name);
                },
              ),
            if (!entry.isDirectory)
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: const Text('Delete'),
                onTap: () {
                  Navigator.pop(context);
                  _delete(entry);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pdfPath = _pdfLocalPath;
    final pdfTitle = _pdfTitle;
    if (pdfPath != null && pdfTitle != null) {
      return PdfViewerScreen(
        filePath: pdfPath,
        title: pdfTitle,
        embedded: true,
        onBack: _closePdf,
        onDownload: () {
          final entry = _pdfEntry;
          if (entry != null) {
            _download(entry);
          } else {
            _saveLocalCopy(pdfPath, pdfTitle);
          }
        },
      );
    }

    final parent = _path == null ? null : SshService.parentRemotePath(_path!);
    final canGoUp = parent != null && SshService.isUnderRoot(_root, parent);
    final relative = _path == null
        ? ''
        : (_path == _root
            ? '/'
            : _path!.substring(_root.length).isEmpty
                ? '/'
                : _path!.substring(_root.length));

    final pathBar = Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Up',
              onPressed: !canGoUp || _loading || _busy ? null : _goUp,
              icon: const Icon(Icons.arrow_upward),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    relative,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Text(
                    _root,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _path == null || _loading || _busy
                  ? null
                  : () => _load(_path!),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.embedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.host.displayLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: 'New folder',
                  onPressed: _busy || _loading ? null : _mkdir,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                ),
                IconButton(
                  tooltip: 'Upload',
                  onPressed: _busy || _loading ? null : _upload,
                  icon: const Icon(Icons.upload_file, size: 20),
                ),
              ],
            ),
          ),
        pathBar,
        if (_busy || _status != null)
          LinearProgressIndicator(
            value: () {
              final total = _downloadTotal;
              final received = _downloadReceived;
              if (_busy && total != null && total > 0 && received != null) {
                return (received / total).clamp(0.0, 1.0);
              }
              return _busy ? null : 1.0;
            }(),
          ),
        if (_status != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              _status!,
              style: Theme.of(context).textTheme.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (_error != null)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _entries.isEmpty
                  ? const Center(child: Text('Empty folder'))
                  : ListView.separated(
                      itemCount: _entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final entry = _entries[index];
                        return ListTile(
                          leading: Icon(_iconFor(entry)),
                          title: Text(entry.name),
                          subtitle: entry.sizeLabel.isEmpty
                              ? null
                              : Text(entry.sizeLabel),
                          trailing: entry.isDirectory
                              ? const Icon(Icons.chevron_right)
                              : _isPdf(entry.name)
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: 'Download PDF',
                                          icon: const Icon(Icons.download),
                                          onPressed: _busy
                                              ? null
                                              : () => _download(entry),
                                        ),
                                        IconButton(
                                          tooltip: 'View PDF',
                                          icon: const Icon(
                                            Icons.visibility_outlined,
                                          ),
                                          onPressed: _busy
                                              ? null
                                              : () => _viewPdf(entry),
                                        ),
                                      ],
                                    )
                                  : IconButton(
                                      tooltip: 'Download to Downloads',
                                      icon: const Icon(Icons.download),
                                      onPressed: _busy
                                          ? null
                                          : () => _download(entry),
                                    ),
                          onTap: entry.isDirectory
                              ? () => _openDir(entry.name)
                              : _isPdf(entry.name)
                                  ? () => _viewPdf(entry)
                                  : () => _showEntryMenu(entry),
                          onLongPress: () => _showEntryMenu(entry),
                        );
                      },
                    ),
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title ?? 'Project files'),
            Text(
              widget.host.displayLabel,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'New folder',
            onPressed: _busy || _loading ? null : _mkdir,
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: 'Upload',
            onPressed: _busy || _loading ? null : _upload,
            icon: const Icon(Icons.upload_file),
          ),
        ],
      ),
      body: body,
    );
  }
}

typedef _DownloadStarter = Future<int> Function(
  String localPath,
  void Function(int received, int? total) onProgress,
  bool Function() isCancelled,
);

/// Choose save path, then multipart-download with a live progress bar.
class _FileDownloadDialog extends StatefulWidget {
  const _FileDownloadDialog({
    required this.fileName,
    required this.sizeLabel,
    required this.totalBytes,
    required this.initialPath,
    required this.pickSavePath,
    required this.onStartDownload,
  });

  final String fileName;
  final String sizeLabel;
  final int? totalBytes;
  final String? initialPath;
  final Future<String?> Function(String fileName) pickSavePath;
  final _DownloadStarter onStartDownload;

  @override
  State<_FileDownloadDialog> createState() => _FileDownloadDialogState();
}

class _FileDownloadDialogState extends State<_FileDownloadDialog> {
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

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
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
                    ? '${_fmt(_received)} / ${_fmt(total)}'
                        '${progress != null ? ' · ${(progress * 100).toStringAsFixed(0)}%' : ''}'
                        '${_cancelling ? ' · Cancelling…' : ' · $_modeLabel'}'
                    : '${_fmt(_received)} downloaded'
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
