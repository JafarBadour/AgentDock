import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../app/providers.dart';
import '../../data/models/mcp_server.dart';
import '../../data/secure/safe_log.dart';
import '../agents/agents_screen.dart';
import '../hosts/hosts_screen.dart';

final mcpListProvider = FutureProvider.autoDispose<List<McpServer>>((ref) {
  return ref.watch(appDatabaseProvider).listMcpServers();
});

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _busy = false;
  String? _status;
  bool? _runInBackground;

  @override
  void initState() {
    super.initState();
    unawaited(_loadBackgroundPref());
  }

  Future<void> _loadBackgroundPref() async {
    final enabled =
        await ref.read(backgroundKeepAliveProvider).isEnabled();
    if (mounted) setState(() => _runInBackground = enabled);
  }

  Future<void> _setRunInBackground(bool value) async {
    setState(() => _runInBackground = value);
    await ref.read(backgroundKeepAliveProvider).setEnabled(value);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value
              ? 'Background mode on — like a pedometer, Agent Dock keeps running'
              : 'Background mode off — connections drop when you leave the app',
        ),
      ),
    );
  }

  Future<void> _exportAg() async {
    setState(() {
      _busy = true;
      _status = 'Building export…';
    });
    try {
      final backup = ref.read(configBackupServiceProvider);
      final suggested =
          'agent-dock-${DateTime.now().toIso8601String().split('T').first}.ag';

      String? path = await FilePicker.saveFile(
        dialogTitle: 'Export Agent Dock config',
        fileName: suggested,
        type: FileType.custom,
        allowedExtensions: const ['ag', 'json'],
      );

      if (path == null) {
        // Fallback: write under Downloads / docs if user cancels save dialog
        // on platforms that return null for cancel — stop quietly.
        if (mounted) {
          setState(() {
            _busy = false;
            _status = null;
          });
        }
        return;
      }
      if (!path.endsWith('.ag') && !path.endsWith('.json')) {
        path = '$path.ag';
      }

      final saved = await backup.exportToFile(path);
      if (!mounted) return;
      setState(() => _status = 'Exported to $saved');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported config to $saved')),
      );
    } catch (e) {
      SafeLog.d('export .ag failed', e);
      // Some desktops fail saveFile — fall back to Documents.
      try {
        final dir = await getApplicationDocumentsDirectory();
        final fallback = p.join(
          dir.path,
          'agent-dock-${DateTime.now().millisecondsSinceEpoch}.ag',
        );
        final saved =
            await ref.read(configBackupServiceProvider).exportToFile(fallback);
        if (!mounted) return;
        setState(() => _status = 'Exported to $saved');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported config to $saved')),
        );
      } catch (e2) {
        if (!mounted) return;
        setState(() => _status = 'Export failed: $e2');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e2')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importAg() async {
    setState(() {
      _busy = true;
      _status = 'Pick a .ag file…';
    });
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: 'Import Agent Dock config',
        type: FileType.custom,
        allowedExtensions: const ['ag', 'json'],
        withData: false,
      );
      if (result == null || result.files.isEmpty) {
        if (mounted) {
          setState(() {
            _busy = false;
            _status = null;
          });
        }
        return;
      }
      final path = result.files.single.path;
      if (path == null) {
        throw StateError('Could not read picked file path');
      }

      final imported =
          await ref.read(configBackupServiceProvider).importFromFile(path);
      ref.invalidate(mcpListProvider);
      ref.invalidate(hostsListProvider);
      ref.invalidate(agentsTreeProvider);

      if (!mounted) return;
      setState(() => _status = imported.summary);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(imported.summary)),
      );
    } catch (e) {
      SafeLog.d('import .ag failed', e);
      if (!mounted) return;
      setState(() => _status = 'Import failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mcps = ref.watch(mcpListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/settings/mcp/new'),
        icon: const Icon(Icons.add),
        label: const Text('Add MCP'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
        children: [
          if (!kIsWeb &&
              (defaultTargetPlatform == TargetPlatform.android ||
                  defaultTargetPlatform == TargetPlatform.iOS)) ...[
            Text('Background', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Stay running when you switch apps (same idea as a pedometer). '
              'Shows a persistent notification and keeps agent connections warm.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Run in background'),
              subtitle: Text(
                _runInBackground == true
                    ? 'On — notification stays up'
                    : 'Off — reconnect after leaving the app',
              ),
              value: _runInBackground ?? true,
              onChanged: _runInBackground == null ? null : _setRunInBackground,
            ),
            const SizedBox(height: 28),
          ],
          Text('Backup', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Export hosts, repos, and MCP configs to a .ag file (JSON). '
            'SSH keys and API keys are never included.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _exportAg,
                icon: const Icon(Icons.upload_file),
                label: const Text('Export .ag'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _importAg,
                icon: const Icon(Icons.download),
                label: const Text('Import .ag'),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 28),
          Text('MCP servers', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Define servers here, then choose which hosts can see them. '
            'Enabling a host writes ~/.cursor/mcp.json over SSH in the background.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          mcps.when(
            data: (list) {
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('No MCP servers yet.'),
                );
              }
              return Column(
                children: [
                  for (final mcp in list)
                    Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Icon(
                          mcp.transport == McpTransport.http
                              ? Icons.cloud_outlined
                              : Icons.terminal,
                        ),
                        title: Text(mcp.name),
                        subtitle: Text(
                          mcp.transport == McpTransport.http
                              ? (mcp.url ?? 'HTTP')
                              : '${mcp.command ?? ''} ${(mcp.args).join(' ')}'
                                  .trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/settings/mcp/${mcp.id}'),
                      ),
                    ),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('Error: $e'),
          ),
          const SizedBox(height: 24),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.vpn_key_outlined),
            title: const Text('SSH & Cursor keys'),
            subtitle: const Text('Managed in the Connect tab'),
            onTap: () => context.go('/connect'),
          ),
        ],
      ),
    );
  }
}
