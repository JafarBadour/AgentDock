import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/models/repo.dart';
import '../../data/secure/safe_log.dart';
import '../agents/agents_screen.dart';
import 'remote_browser_screen.dart';
import 'repos_screen.dart';

class RepoEditScreen extends ConsumerStatefulWidget {
  const RepoEditScreen({super.key, required this.hostId, this.repoId});

  final String hostId;
  final String? repoId;

  @override
  ConsumerState<RepoEditScreen> createState() => _RepoEditScreenState();
}

class _RepoEditScreenState extends ConsumerState<RepoEditScreen> {
  final _name = TextEditingController();
  final _path = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _browsing = false;
  String? _status;
  Repo? _existing;
  Host? _host;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _host = await ref.read(appDatabaseProvider).getHost(widget.hostId);
    if (widget.repoId != null) {
      _existing = await ref.read(appDatabaseProvider).getRepo(widget.repoId!);
      if (_existing != null) {
        _name.text = _existing!.name;
        _path.text = _existing!.remotePath;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _browse() async {
    if (_host == null) return;
    setState(() {
      _browsing = true;
      _status = null;
    });
    try {
      final selected = await RemoteBrowserScreen.open(
        context,
        host: _host!,
        initialPath: _path.text.trim().isEmpty ? null : _path.text.trim(),
      );
      if (selected == null || !mounted) return;
      setState(() {
        _path.text = selected;
        if (_name.text.trim().isEmpty) {
          final parts = selected.split('/').where((p) => p.isNotEmpty);
          if (parts.isNotEmpty) {
            _name.text = parts.last;
          }
        }
      });
    } catch (e) {
      SafeLog.d('browse failed', e);
      if (mounted) setState(() => _status = 'Browse failed: $e');
    } finally {
      if (mounted) setState(() => _browsing = false);
    }
  }

  Future<void> _save({bool validateRemote = true}) async {
    final name = _name.text.trim();
    final path = _path.text.trim();
    if (name.isEmpty || path.isEmpty || _host == null) {
      setState(() => _status = 'Name and absolute path are required.');
      return;
    }
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      if (validateRemote) {
        final exists = await ref.read(sshServiceProvider).remotePathExists(_host!, path);
        if (!exists) {
          setState(() => _status = 'Remote path does not exist (or is not a directory).');
          return;
        }
      }
      final repo = Repo(
        id: _existing?.id ?? const Uuid().v4(),
        hostId: widget.hostId,
        name: name,
        remotePath: path,
        sortOrder: _existing?.sortOrder ??
            await ref.read(appDatabaseProvider).nextRepoSortOrder(widget.hostId),
        createdAt: _existing?.createdAt ?? DateTime.now(),
      );
      await ref.read(appDatabaseProvider).upsertRepo(repo);
      ref.invalidate(reposForHostProvider(widget.hostId));
      ref.invalidate(agentsTreeProvider);
      if (mounted) context.pop();
    } catch (e) {
      SafeLog.d('save repo failed', e);
      setState(() => _status = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (_existing == null) return;
    await ref.read(appDatabaseProvider).deleteRepo(_existing!.id);
    ref.invalidate(reposForHostProvider(widget.hostId));
    ref.invalidate(agentsTreeProvider);
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? 'Add repo' : 'Edit repo'),
        actions: [
          if (_existing != null)
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _path,
            decoration: InputDecoration(
              labelText: 'Remote absolute path',
              hintText: '/home/you/projects/app',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Browse remote',
                onPressed: _saving || _browsing ? null : _browse,
                icon: _browsing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder_open),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _saving || _browsing ? null : _browse,
              icon: const Icon(Icons.travel_explore),
              label: const Text('Browse remote folders'),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _saving || _browsing ? null : () => _save(),
            child: const Text('Save & validate'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _saving || _browsing ? null : () => _save(validateRemote: false),
            child: const Text('Save without remote check'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 16),
            Text(_status!),
          ],
        ],
      ),
    );
  }
}
