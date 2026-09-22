import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../app/platform_layout.dart';
import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/models/mcp_server.dart';
import '../../data/models/skill.dart';
import '../../data/secure/safe_log.dart';
import '../../services/skill_folder_importer.dart';
import '../agents/agents_screen.dart';
import '../connect/connect_screen.dart';
import '../hosts/hosts_screen.dart';

final mcpListProvider = FutureProvider.autoDispose<List<McpServer>>((ref) {
  ref.watch(agentsCatalogEpochProvider);
  return ref.watch(appDatabaseProvider).listMcpServers();
});

final mcpHostLinksProvider = FutureProvider.autoDispose<List<McpHostLink>>((
  ref,
) {
  ref.watch(agentsCatalogEpochProvider);
  return ref.watch(appDatabaseProvider).listMcpHostLinks();
});

final skillListProvider = FutureProvider.autoDispose<List<AgentSkill>>((ref) {
  ref.watch(agentsCatalogEpochProvider);
  return ref.watch(appDatabaseProvider).listSkills();
});

final skillHostLinksProvider = FutureProvider.autoDispose<List<SkillHostLink>>((
  ref,
) {
  ref.watch(agentsCatalogEpochProvider);
  return ref.watch(appDatabaseProvider).listSkillHostLinks();
});

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key, this.embedded = false});

  final bool embedded;

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
    final enabled = await ref.read(backgroundKeepAliveProvider).isEnabled();
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

  Future<void> _importSkillFolder() async {
    setState(() {
      _busy = true;
      _status = 'Pick a skill folder…';
    });
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Import skill folder(s)',
      );
      if (path == null) {
        if (mounted) {
          setState(() {
            _busy = false;
            _status = null;
          });
        }
        return;
      }

      final imports = await SkillFolderImporter.loadAll(path);
      final db = ref.read(appDatabaseProvider);
      String? firstId;
      for (final item in imports) {
        final existing = await db.findSkillByName(item.name);
        final skill = AgentSkill(
          id: existing?.id ?? const Uuid().v4(),
          name: item.name,
          description: item.description,
          bodyMarkdown: item.bodyMarkdown,
          disableModelInvocation: item.disableModelInvocation,
          createdAt: existing?.createdAt ?? DateTime.now(),
          bundleFiles: item.bundleFiles,
        );
        await db.upsertSkill(skill);
        firstId ??= skill.id;
      }
      ref.invalidate(skillListProvider);
      ref.invalidate(skillHostLinksProvider);
      if (!mounted) return;
      final label = imports.length == 1
          ? 'Imported ${imports.first.name}'
              '${imports.first.fileCount == 0 ? '' : ' (+${imports.first.fileCount} files)'}'
          : 'Imported ${imports.length} skills';
      setState(() {
        _busy = false;
        _status = label;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(label)));
      if (firstId != null && imports.length == 1) {
        openSettingsSubpage(context, ref, '/settings/skills/$firstId');
      }
    } catch (e) {
      SafeLog.d('Skill folder import failed', e);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Import failed: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Exported config to $saved')));
    } catch (e) {
      SafeLog.d('export .ag failed', e);
      // Some desktops fail saveFile — fall back to Documents.
      try {
        final dir = await getApplicationDocumentsDirectory();
        final fallback = p.join(
          dir.path,
          'agent-dock-${DateTime.now().millisecondsSinceEpoch}.ag',
        );
        final saved = await ref
            .read(configBackupServiceProvider)
            .exportToFile(fallback);
        if (!mounted) return;
        setState(() => _status = 'Exported to $saved');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Exported config to $saved')));
      } catch (e2) {
        if (!mounted) return;
        setState(() => _status = 'Export failed: $e2');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $e2')));
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

      final imported = await ref
          .read(configBackupServiceProvider)
          .importFromFile(path);
      ref.invalidate(mcpListProvider);
      ref.invalidate(mcpHostLinksProvider);
      ref.invalidate(skillListProvider);
      ref.invalidate(skillHostLinksProvider);
      ref.invalidate(hostsListProvider);
      ref.invalidate(agentsTreeProvider);

      if (!mounted) return;
      setState(() => _status = imported.summary);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(imported.summary)));
    } catch (e) {
      SafeLog.d('import .ag failed', e);
      if (!mounted) return;
      setState(() => _status = 'Import failed: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mcps = ref.watch(mcpListProvider);
    final links = ref.watch(mcpHostLinksProvider);
    final skills = ref.watch(skillListProvider);
    final skillLinks = ref.watch(skillHostLinksProvider);
    final hostsAsync = ref.watch(hostsListProvider);

    final body = ListView(
      padding: EdgeInsets.fromLTRB(16, 12, 16, widget.embedded ? 16 : 88),
      children: [
        Text('SSH & device', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const ConnectScreen(embedded: true, nestedInParentScroll: true),
        const SizedBox(height: 28),
        Text('API keys', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Cursor, Anthropic, OpenAI, and related agent keys.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('API keys'),
            subtitle: const Text('View and set Cursor, Anthropic, OpenAI, …'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openSettingsSubpage(context, ref, '/settings/keys'),
          ),
        ),
        const SizedBox(height: 28),
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
          'Enabling a host always writes ~/.cursor/mcp.json, ~/.claude.json, '
          'and ~/.codex/config.toml over SSH in the background.',
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
            final linkRows = links.valueOrNull ?? const <McpHostLink>[];
            final hosts = hostsAsync.valueOrNull ?? const <Host>[];
            final hostById = {for (final h in hosts) h.id: h};
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
                        _mcpListSubtitle(mcp, linkRows, hostById),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openSettingsSubpage(
                        context,
                        ref,
                        '/settings/mcp/${mcp.id}',
                      ),
                    ),
                  ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error: $e'),
        ),
        const SizedBox(height: 28),
        Row(
          children: [
            Expanded(
              child: Text(
                'Skills',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              onPressed: _busy ? null : () => unawaited(_importSkillFolder()),
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Import folder'),
            ),
            TextButton.icon(
              onPressed: () =>
                  openSettingsSubpage(context, ref, '/settings/skills/new'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Markdown Agent Skills (SKILL.md + optional scripts/references/assets). '
          'Import a skill folder, or a parent folder of several skills. '
          'Refresh Agents to probe hosts for ~/.cursor/skills and ~/.claude/skills — '
          'status shows under each skill.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        skills.when(
          data: (list) {
            if (list.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('No skills yet.'),
              );
            }
            final linkRows =
                skillLinks.valueOrNull ?? const <SkillHostLink>[];
            final hosts = hostsAsync.valueOrNull ?? const <Host>[];
            final hostById = {for (final h in hosts) h.id: h};
            return Column(
              children: [
                for (final skill in list)
                  Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(
                        linkRows.any(
                              (l) =>
                                  l.skillId == skill.id &&
                                  l.installStatus ==
                                      SkillHostInstallStatus.installed,
                            )
                            ? Icons.check_circle_outline
                            : Icons.auto_awesome_outlined,
                      ),
                      title: Text(skill.name),
                      subtitle: Text(
                        _skillListSubtitle(skill, linkRows, hostById),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openSettingsSubpage(
                        context,
                        ref,
                        '/settings/skills/${skill.id}',
                      ),
                    ),
                  ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Error: $e'),
        ),
      ],
    );

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () =>
                    openSettingsSubpage(context, ref, '/settings/mcp/new'),
                icon: const Icon(Icons.add),
                label: const Text('Add MCP'),
              ),
            ),
          ),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => openSettingsSubpage(context, ref, '/settings/mcp/new'),
        icon: const Icon(Icons.add),
        label: const Text('Add MCP'),
      ),
      body: body,
    );
  }
}

String _mcpListSubtitle(
  McpServer mcp,
  List<McpHostLink> links,
  Map<String, Host> hostById,
) {
  final base = mcp.transport == McpTransport.http
      ? (mcp.url ?? 'HTTP')
      : '${mcp.command ?? ''} ${(mcp.args).join(' ')}'.trim();
  final bits = <String>[if (base.isNotEmpty) base];
  for (final link in links) {
    if (link.mcpId != mcp.id) continue;
    if (!link.enabled && link.installStatus != McpHostInstallStatus.installed) {
      continue;
    }
    if (link.targets.isEmpty &&
        link.installStatus != McpHostInstallStatus.installed) {
      continue;
    }
    final host = hostById[link.hostId];
    final hostName = host?.displayLabel ?? link.hostId;
    final clients = link.targetsLabel.isNotEmpty
        ? link.targetsLabel
        : (link.installStatus == McpHostInstallStatus.installed
              ? 'installed'
              : '');
    if (clients.isEmpty) continue;
    bits.add('$hostName ($clients)');
  }
  return bits.join(' · ');
}

String _skillListSubtitle(
  AgentSkill skill,
  List<SkillHostLink> links,
  Map<String, Host> hostById,
) {
  final bits = <String>[
    if (skill.description.trim().isNotEmpty) skill.description.trim(),
    if (skill.bundleFiles.isNotEmpty)
      '${skill.bundleFiles.length} bundled file'
          '${skill.bundleFiles.length == 1 ? '' : 's'}',
  ];
  final onHosts = <String>[];
  for (final link in links) {
    if (link.skillId != skill.id) continue;
    if (link.installStatus != SkillHostInstallStatus.installed) continue;
    final host = hostById[link.hostId];
    final hostName = host?.displayLabel ?? link.hostId;
    final where = link.targetsLabel.isNotEmpty
        ? link.targetsLabel
        : 'installed';
    onHosts.add('$hostName ($where)');
  }
  if (onHosts.isEmpty) {
    // After a catalog refresh we record removed links per host — use that to
    // show we probed, otherwise "not synced yet".
    final probed = links.any(
      (l) =>
          l.skillId == skill.id &&
          (l.installStatus == SkillHostInstallStatus.removed ||
              l.installStatus == SkillHostInstallStatus.failed),
    );
    bits.add(probed ? 'Not on any host' : 'Host status unknown — tap refresh');
  } else {
    bits.addAll(onHosts);
  }
  return bits.join(' · ');
}
