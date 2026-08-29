import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/secure/safe_log.dart';
import '../../services/ssh_service.dart';

/// Browse / download / upload files under a project root on [host].
class ProjectFilesScreen extends ConsumerStatefulWidget {
  const ProjectFilesScreen({
    super.key,
    required this.host,
    required this.rootPath,
    this.title,
  });

  final Host host;
  final String rootPath;
  final String? title;

  static Future<void> open(
    BuildContext context, {
    required Host host,
    required String rootPath,
    String? title,
  }) {
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

  Future<Directory> _downloadsDir() async {
    try {
      final d = await getDownloadsDirectory();
      if (d != null) return d;
    } catch (_) {}
    return getApplicationDocumentsDirectory();
  }

  Future<void> _download(RemoteFileEntry entry) async {
    if (entry.isDirectory) return;
    final remote = SshService.joinRemotePath(_path ?? _root, entry.name);
    setState(() {
      _busy = true;
      _status = 'Downloading ${entry.name}…';
    });
    try {
      final dir = await _downloadsDir();
      var localPath = p.join(dir.path, entry.name);
      if (await File(localPath).exists()) {
        final stem = p.basenameWithoutExtension(entry.name);
        final ext = p.extension(entry.name);
        localPath = p.join(
          dir.path,
          '$stem-${DateTime.now().millisecondsSinceEpoch}$ext',
        );
      }
      final bytes = await ref.read(sshServiceProvider).downloadRemoteFile(
            widget.host,
            remote,
            localPath,
          );
      if (!mounted) return;
      setState(() => _status = 'Saved $bytes bytes → $localPath');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded ${entry.name}')),
      );
    } catch (e) {
      SafeLog.d('download failed', e);
      if (!mounted) return;
      setState(() => _status = 'Download failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Download failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
            if (!entry.isDirectory)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(context);
                  _download(entry);
                },
              ),
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
                leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
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
    final parent = _path == null ? null : SshService.parentRemotePath(_path!);
    final canGoUp = parent != null && SshService.isUnderRoot(_root, parent);
    final relative = _path == null
        ? ''
        : (_path == _root
            ? '/'
            : _path!.substring(_root.length).isEmpty
                ? '/'
                : _path!.substring(_root.length));

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
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
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
          ),
          if (_busy || _status != null)
            LinearProgressIndicator(
              value: _busy ? null : 1,
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
                            leading: Icon(
                              entry.isDirectory
                                  ? (entry.isSymlink
                                      ? Icons.link
                                      : Icons.folder_outlined)
                                  : Icons.insert_drive_file_outlined,
                            ),
                            title: Text(entry.name),
                            subtitle: entry.sizeLabel.isEmpty
                                ? null
                                : Text(entry.sizeLabel),
                            trailing: entry.isDirectory
                                ? const Icon(Icons.chevron_right)
                                : IconButton(
                                    tooltip: 'Download',
                                    icon: const Icon(Icons.download),
                                    onPressed: _busy ? null : () => _download(entry),
                                  ),
                            onTap: entry.isDirectory
                                ? () => _openDir(entry.name)
                                : () => _showEntryMenu(entry),
                            onLongPress: () => _showEntryMenu(entry),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
