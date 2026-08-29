import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/secure/safe_log.dart';
import '../../services/ssh_service.dart';

/// Full-screen remote directory browser. Returns the selected absolute path.
class RemoteBrowserScreen extends ConsumerStatefulWidget {
  const RemoteBrowserScreen({
    super.key,
    required this.host,
    this.initialPath,
  });

  final Host host;
  final String? initialPath;

  static Future<String?> open(
    BuildContext context, {
    required Host host,
    String? initialPath,
  }) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => RemoteBrowserScreen(host: host, initialPath: initialPath),
      ),
    );
  }

  @override
  ConsumerState<RemoteBrowserScreen> createState() => _RemoteBrowserScreenState();
}

class _RemoteBrowserScreenState extends ConsumerState<RemoteBrowserScreen> {
  String? _path;
  List<RemoteDirEntry> _dirs = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final ssh = ref.read(sshServiceProvider);
    try {
      final start = widget.initialPath?.trim().isNotEmpty == true
          ? SshService.normalizeRemotePath(widget.initialPath!)
          : await ssh.remoteHomeDirectory(widget.host);
      await _load(start);
    } catch (e) {
      SafeLog.d('remote browse bootstrap failed', e);
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await ref.read(sshServiceProvider).listRemoteDirectories(
            widget.host,
            path,
          );
      if (!mounted) return;
      setState(() {
        _path = listing.path;
        _dirs = listing.directories;
        _loading = false;
      });
    } catch (e) {
      SafeLog.d('list remote dirs failed', e);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not open $path\n$e';
      });
    }
  }

  Future<void> _goUp() async {
    final parent = SshService.parentRemotePath(_path ?? '/');
    if (parent == null) return;
    await _load(parent);
  }

  Future<void> _openDir(String name) async {
    final next = SshService.joinRemotePath(_path ?? '/', name);
    await _load(next);
  }

  void _selectCurrent() {
    final path = _path;
    if (path == null) return;
    Navigator.of(context).pop(path);
  }

  @override
  Widget build(BuildContext context) {
    final parent = _path == null ? null : SshService.parentRemotePath(_path!);

    return Scaffold(
      appBar: AppBar(
        title: Text('Browse · ${widget.host.displayLabel}'),
        actions: [
          TextButton(
            onPressed: _path == null || _loading ? null : _selectCurrent,
            child: const Text('Use this folder'),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Up',
                    onPressed: parent == null || _loading ? null : _goUp,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  Expanded(
                    child: SelectableText(
                      _path ?? '…',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh',
                    onPressed: _path == null || _loading ? null : () => _load(_path!),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _dirs.isEmpty
                    ? const Center(child: Text('No subfolders here'))
                    : ListView.separated(
                        itemCount: _dirs.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final dir = _dirs[index];
                          return ListTile(
                            leading: Icon(
                              dir.isSymlink ? Icons.link : Icons.folder_outlined,
                            ),
                            title: Text(dir.name),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _openDir(dir.name),
                            onLongPress: () {
                              final selected = SshService.joinRemotePath(
                                _path ?? '/',
                                dir.name,
                              );
                              Navigator.of(context).pop(selected);
                            },
                          );
                        },
                      ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton.icon(
                onPressed: _path == null || _loading ? null : _selectCurrent,
                icon: const Icon(Icons.check),
                label: const Text('Select this folder'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
