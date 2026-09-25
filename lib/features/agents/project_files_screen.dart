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
import '../../services/file_kind.dart';
import '../../services/ssh_service.dart';
import 'file_download_dialog.dart';
import 'file_mention.dart';
import 'file_viewer_screen.dart';
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
  String? _previewLocalPath;
  String? _previewTitle;
  RemoteFileEntry? _previewEntry;

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

  Future<void> _download(
    RemoteFileEntry entry, {
    bool askWhere = false,
  }) async {
    if (entry.isDirectory) return;
    final remote = SshService.joinRemotePath(_path ?? _root, entry.name);
    final total = entry.size;
    // Unknown size or ≥1 MiB / explicit Save as → location picker + progress.
    final large =
        total == null || total >= kLargeDownloadBytes || askWhere;

    // Large downloads (or explicit Save as): pick location + progress dialog.
    if (large) {
      await _downloadWithDialog(entry, remote, total);
      return;
    }

    String? localPath;
    final dir = await publicDownloadsDir();
    if (dir != null) {
      localPath = await uniquePathIn(dir, entry.name);
    } else {
      localPath = await pickSaveLocation(entry.name);
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
                        '${formatBytes(received)} / ${formatBytes(t)}'
                    : 'Downloading ${entry.name}… ${formatBytes(received)}';
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
    final dir = await publicDownloadsDir();
    if (dir != null) {
      suggested = await uniquePathIn(dir, entry.name);
    }

    if (!mounted) return;
    final savedPath = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => FileDownloadDialog(
        fileName: entry.name,
        sizeLabel: entry.sizeLabel.isNotEmpty
            ? entry.sizeLabel
            : (total != null ? formatBytes(total) : 'Unknown size'),
        totalBytes: total,
        initialPath: suggested,
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
    if (size >= kLargeDownloadBytes || askWhere) {
      final dest = await pickSaveLocation(fileName);
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
    final dir = await publicDownloadsDir();
    if (dir != null) {
      dest = await uniquePathIn(dir, fileName);
    } else {
      dest = await pickSaveLocation(fileName);
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
      final localPath = await uniquePathIn(cache, entry.name);
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

  void _closePreview() {
    setState(() {
      _previewLocalPath = null;
      _previewTitle = null;
      _previewEntry = null;
      _status = null;
    });
  }

  Future<void> _viewFile(RemoteFileEntry entry) async {
    if (entry.isDirectory || !_kindOf(entry).isViewable) return;
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
      final localPath = await uniquePathIn(cache, entry.name);
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
                        '${formatBytes(received)} / ${formatBytes(t)}'
                    : 'Opening ${entry.name}… ${formatBytes(received)}';
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
          _previewLocalPath = localPath;
          _previewTitle = entry.name;
          _previewEntry = entry;
        });
        return;
      }
      await openLocalFile(
        context,
        filePath: localPath,
        title: entry.name,
        onDownload: () {
          _saveLocalCopy(localPath, entry.name, askWhere: true);
        },
        onShare: () {
          SharePlus.instance.share(
            ShareParams(
              files: [XFile(localPath, name: entry.name)],
              subject: entry.name,
            ),
          );
        },
      );
    } catch (e) {
      SafeLog.d('file open failed', e);
      if (!mounted) return;
      setState(() => _status = 'Could not open ${entry.name}: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open ${entry.name}: $e')),
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

  static FileKind _kindOf(RemoteFileEntry entry) => fileKindFor(entry.name);

  IconData _iconFor(RemoteFileEntry entry) {
    if (entry.isDirectory) {
      return entry.isSymlink ? Icons.link : Icons.folder_outlined;
    }
    return iconFor(_kindOf(entry));
  }

  /// "View PDF" / "View Markdown" / "View" — matches what the viewer shows.
  static String _viewLabel(FileKind kind) => switch (kind) {
        FileKind.pdf => 'View PDF',
        FileKind.markdown => 'View Markdown',
        FileKind.image => 'View image',
        FileKind.text => 'View',
        FileKind.binary => 'View',
      };

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
            if (!entry.isDirectory && _kindOf(entry).isViewable)
              ListTile(
                leading: Icon(iconFor(_kindOf(entry))),
                title: Text(_viewLabel(_kindOf(entry))),
                onTap: () {
                  Navigator.pop(context);
                  _viewFile(entry);
                },
              ),
            if (!entry.isDirectory) ...[
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
    final previewPath = _previewLocalPath;
    final previewTitle = _previewTitle;
    if (previewPath != null && previewTitle != null) {
      void download() {
        final entry = _previewEntry;
        if (entry != null) {
          _download(entry);
        } else {
          _saveLocalCopy(previewPath, previewTitle);
        }
      }

      if (fileKindFor(previewTitle) == FileKind.pdf) {
        return PdfViewerScreen(
          filePath: previewPath,
          title: previewTitle,
          embedded: true,
          onBack: _closePreview,
          onDownload: download,
        );
      }
      return FileViewerScreen(
        filePath: previewPath,
        title: previewTitle,
        embedded: true,
        onBack: _closePreview,
        onDownload: download,
        onShare: () {
          SharePlus.instance.share(
            ShareParams(
              files: [XFile(previewPath, name: previewTitle)],
              subject: previewTitle,
            ),
          );
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
                              : _kindOf(entry).isViewable
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: 'Download to Downloads',
                                          icon: const Icon(Icons.download),
                                          onPressed: _busy
                                              ? null
                                              : () => _download(entry),
                                        ),
                                        IconButton(
                                          tooltip: _viewLabel(_kindOf(entry)),
                                          icon: const Icon(
                                            Icons.visibility_outlined,
                                          ),
                                          onPressed: _busy
                                              ? null
                                              : () => _viewFile(entry),
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
                              : _kindOf(entry).isViewable
                                  ? () => _viewFile(entry)
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
