import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/secure/safe_log.dart';
import '../../services/file_kind.dart';
import '../../services/ssh_service.dart';
import 'file_download_dialog.dart';
import 'file_viewer_screen.dart';
import 'project_files_screen.dart';

/// Makes file paths in chat text tappable, by saying which host and project
/// directory a mentioned path should be resolved against.
///
/// Installed by the chat screen above the transcript; [MessageBody] looks it up
/// to decide whether inline code like `lib/main.dart` becomes a chip.
class FileMentionScope extends InheritedWidget {
  const FileMentionScope({
    super.key,
    required this.host,
    required this.rootPath,
    required super.child,
  });

  final Host host;

  /// Project root that relative mentions are resolved against.
  final String rootPath;

  static FileMentionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FileMentionScope>();

  @override
  bool updateShouldNotify(FileMentionScope oldWidget) =>
      oldWidget.host.id != host.id || oldWidget.rootPath != rootPath;
}

/// Show what can be done with a file the agent mentioned: view it in the app,
/// download it, or share it.
Future<void> showFileMentionSheet(
  BuildContext context, {
  required Host host,
  required String rootPath,
  required FileMention mention,
}) async {
  final choice = await showModalBottomSheet<_MentionChoice>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _FileMentionSheet(
      host: host,
      rootPath: rootPath,
      mention: mention,
    ),
  );
  if (choice == null || !context.mounted) return;

  switch (choice.action) {
    case _MentionAction.view:
      await _viewRemoteFile(
        context,
        host: host,
        remotePath: choice.remotePath,
        name: choice.name,
        size: choice.size,
      );
    case _MentionAction.share:
      await _shareRemoteFile(
        context,
        host: host,
        remotePath: choice.remotePath,
        name: choice.name,
        size: choice.size,
      );
    case _MentionAction.download:
      await downloadRemoteFileToDisk(
        context,
        host: host,
        remotePath: choice.remotePath,
        name: choice.name,
        size: choice.size,
      );
    case _MentionAction.browse:
      final parent = choice.isDirectory
          ? choice.remotePath
          : SshService.parentRemotePath(choice.remotePath) ?? rootPath;
      if (!context.mounted) return;
      await ProjectFilesScreen.open(
        context,
        host: host,
        rootPath: parent,
        title: choice.name,
      );
  }
}

// listen: false — this is a one-shot read from callbacks and initState, not a
// dependency the widget should rebuild on.
SshService _ssh(BuildContext context) =>
    ProviderScope.containerOf(context, listen: false).read(sshServiceProvider);

Future<void> _viewRemoteFile(
  BuildContext context, {
  required Host host,
  required String remotePath,
  required String name,
  int? size,
}) async {
  final ssh = _ssh(context);
  final localPath = await fetchFileToCache(
    context,
    fileName: name,
    action: 'Opening $name',
    totalBytes: size,
    onStartDownload: (path, onProgress, isCancelled) => ssh.downloadRemoteFile(
      host,
      remotePath,
      path,
      totalBytes: size,
      onProgress: onProgress,
      isCancelled: isCancelled,
    ),
  );
  if (localPath == null || !context.mounted) return;
  await openLocalFile(
    context,
    filePath: localPath,
    title: name,
    onDownload: () => _saveCachedCopy(context, localPath, name),
    onShare: () => SharePlus.instance.share(
      ShareParams(files: [XFile(localPath, name: name)], subject: name),
    ),
  );
}

Future<void> _shareRemoteFile(
  BuildContext context, {
  required Host host,
  required String remotePath,
  required String name,
  int? size,
}) async {
  final ssh = _ssh(context);
  final localPath = await fetchFileToCache(
    context,
    fileName: name,
    action: 'Preparing $name',
    totalBytes: size,
    onStartDownload: (path, onProgress, isCancelled) => ssh.downloadRemoteFile(
      host,
      remotePath,
      path,
      totalBytes: size,
      onProgress: onProgress,
      isCancelled: isCancelled,
    ),
  );
  if (localPath == null) return;
  await SharePlus.instance.share(
    ShareParams(files: [XFile(localPath, name: name)], subject: name),
  );
}

Future<void> _saveCachedCopy(
  BuildContext context,
  String localPath,
  String name,
) async {
  try {
    final dest = await saveFileCopy(localPath, name);
    if (dest == null || !context.mounted) return;
    showSavedSnack(context, name, dest);
  } catch (e) {
    SafeLog.d('save copy failed', e);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Save failed: $e')),
    );
  }
}

/// Download a remote file to Downloads (or a location the user picks).
///
/// Small files land in Downloads directly with a snackbar; large or
/// unknown-size ones get the picker + progress dialog.
Future<void> downloadRemoteFileToDisk(
  BuildContext context, {
  required Host host,
  required String remotePath,
  required String name,
  int? size,
  bool askWhere = false,
}) async {
  final ssh = _ssh(context);
  final large = size == null || size >= kLargeDownloadBytes || askWhere;
  if (large) {
    final dir = await publicDownloadsDir();
    final suggested = dir == null ? null : await uniquePathIn(dir, name);
    if (!context.mounted) return;
    final saved = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => FileDownloadDialog(
        fileName: name,
        sizeLabel: size != null ? formatBytes(size) : 'Unknown size',
        totalBytes: size,
        initialPath: suggested,
        onStartDownload: (path, onProgress, isCancelled) =>
            ssh.downloadRemoteFile(
          host,
          remotePath,
          path,
          totalBytes: size,
          onProgress: onProgress,
          isCancelled: isCancelled,
        ),
      ),
    );
    if (saved == null || !context.mounted) return;
    showSavedSnack(context, name, saved);
    return;
  }

  final dir = await publicDownloadsDir();
  final dest =
      dir != null ? await uniquePathIn(dir, name) : await pickSaveLocation(name);
  if (dest == null || dest.isEmpty || !context.mounted) return;
  try {
    await ssh.downloadRemoteFile(host, remotePath, dest, totalBytes: size);
    if (!context.mounted) return;
    showSavedSnack(context, name, dest);
  } catch (e) {
    SafeLog.d('download failed', e);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Could not write Downloads — pick a location'),
        action: SnackBarAction(
          label: 'Save as',
          onPressed: () => downloadRemoteFileToDisk(
            context,
            host: host,
            remotePath: remotePath,
            name: name,
            size: size,
            askWhere: true,
          ),
        ),
      ),
    );
  }
}

enum _MentionAction { view, download, share, browse }

class _MentionChoice {
  const _MentionChoice({
    required this.action,
    required this.remotePath,
    required this.name,
    this.size,
    this.isDirectory = false,
  });

  final _MentionAction action;
  final String remotePath;
  final String name;
  final int? size;
  final bool isDirectory;
}

class _FileMentionSheet extends StatefulWidget {
  const _FileMentionSheet({
    required this.host,
    required this.rootPath,
    required this.mention,
  });

  final Host host;
  final String rootPath;
  final FileMention mention;

  @override
  State<_FileMentionSheet> createState() => _FileMentionSheetState();
}

class _FileMentionSheetState extends State<_FileMentionSheet> {
  String? _remotePath;
  RemoteFileEntry? _entry;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    final ssh = _ssh(context);
    var path = widget.mention.path;
    try {
      if (path.startsWith('~')) {
        final home = await ssh.remoteHomeDirectory(widget.host);
        path = path == '~'
            ? home
            : SshService.joinRemotePath(
                home,
                path.substring(path.startsWith('~/') ? 2 : 1),
              );
      } else if (!path.startsWith('/')) {
        path = SshService.joinRemotePath(widget.rootPath, path);
      }
      path = SshService.normalizeRemotePath(path);
      final entry = await ssh.statRemoteFile(widget.host, path);
      if (!mounted) return;
      setState(() {
        _remotePath = path;
        _entry = entry;
        _checking = false;
      });
    } catch (e) {
      SafeLog.d('file mention resolve failed', e);
      if (!mounted) return;
      setState(() {
        _remotePath = path;
        _checking = false;
      });
    }
  }

  void _choose(_MentionAction action) {
    final path = _remotePath;
    if (path == null) return;
    Navigator.pop(
      context,
      _MentionChoice(
        action: action,
        remotePath: path,
        name: widget.mention.name,
        size: _entry?.size,
        isDirectory: _entry?.isDirectory ?? false,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mention = widget.mention;
    final kind = mention.kind;
    final entry = _entry;
    final isDirectory = entry?.isDirectory ?? false;
    final exists = entry != null;
    final path = _remotePath ?? mention.path;

    final subtitle = _checking
        ? 'Looking on ${widget.host.displayLabel}…'
        : !exists
            ? 'Not found on ${widget.host.displayLabel}'
            : [
                if (isDirectory) 'Folder' else _kindLabel(kind),
                if (entry.sizeLabel.isNotEmpty) entry.sizeLabel,
              ].join(' · ');

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(isDirectory ? Icons.folder_outlined : iconFor(kind)),
            title: Text(mention.name),
            subtitle: Text(subtitle),
            trailing: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                path,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          if (exists && !isDirectory && kind.isViewable)
            ListTile(
              leading: const Icon(Icons.visibility_outlined),
              title: const Text('View'),
              subtitle: Text('Open ${_kindLabel(kind).toLowerCase()} in app'),
              onTap: () => _choose(_MentionAction.view),
            ),
          if (exists && !isDirectory) ...[
            ListTile(
              leading: const Icon(Icons.download),
              title: const Text('Download'),
              subtitle: const Text('Save to Downloads'),
              onTap: () => _choose(_MentionAction.download),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('Share…'),
              subtitle: const Text('Send via another app'),
              onTap: () => _choose(_MentionAction.share),
            ),
          ],
          // Offered even when the file is missing — the folder is still the
          // best place to go looking for it.
          if (!_checking)
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: Text(
                isDirectory ? 'Open folder' : 'Show in project files',
              ),
              onTap: () => _choose(_MentionAction.browse),
            ),
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Copy path'),
            onTap: () {
              Clipboard.setData(ClipboardData(text: path));
              Navigator.pop(context);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

String _kindLabel(FileKind kind) => switch (kind) {
      FileKind.pdf => 'PDF',
      FileKind.markdown => 'Markdown',
      FileKind.text => 'Text',
      FileKind.image => 'Image',
      FileKind.binary => 'File',
    };

/// Icon for a file kind, shared by the chat sheet and the file browser.
IconData iconFor(FileKind kind) => switch (kind) {
      FileKind.pdf => Icons.picture_as_pdf_outlined,
      FileKind.markdown => Icons.article_outlined,
      FileKind.text => Icons.description_outlined,
      FileKind.image => Icons.image_outlined,
      FileKind.binary => Icons.insert_drive_file_outlined,
    };
