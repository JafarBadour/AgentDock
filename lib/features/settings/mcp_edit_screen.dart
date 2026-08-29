import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/models/mcp_server.dart';
import '../../data/secure/safe_log.dart';
import 'settings_screen.dart';

class McpEditScreen extends ConsumerStatefulWidget {
  const McpEditScreen({super.key, this.mcpId});

  final String? mcpId;

  @override
  ConsumerState<McpEditScreen> createState() => _McpEditScreenState();
}

class _McpEditScreenState extends ConsumerState<McpEditScreen> {
  final _name = TextEditingController();
  final _command = TextEditingController(text: 'npx');
  final _args = TextEditingController();
  final _url = TextEditingController();
  final _env = TextEditingController();
  McpTransport _transport = McpTransport.stdio;
  bool _loading = true;
  bool _saving = false;
  McpServer? _existing;
  List<Host> _hosts = const [];
  Map<String, McpHostLink> _links = {};
  final Set<String> _busyHosts = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    _hosts = await db.listHosts();
    if (widget.mcpId != null) {
      final mcp = await db.getMcpServer(widget.mcpId!);
      if (mcp != null) {
        _existing = mcp;
        _name.text = mcp.name;
        _transport = mcp.transport;
        _command.text = mcp.command ?? 'npx';
        _args.text = mcp.args.join(' ');
        _url.text = mcp.url ?? '';
        _env.text = mcp.env.entries.map((e) => '${e.key}=${e.value}').join('\n');
        final links = await db.listMcpHostLinks(mcpId: mcp.id);
        _links = {for (final l in links) l.hostId: l};
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, String> _parseEnv() {
    final map = <String, String>{};
    for (final line in _env.text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.contains('=')) continue;
      final i = trimmed.indexOf('=');
      map[trimmed.substring(0, i).trim()] = trimmed.substring(i + 1).trim();
    }
    return map;
  }

  List<String> _parseArgs() {
    final raw = _args.text.trim();
    if (raw.isEmpty) return const [];
    // Simple whitespace split; quoted args can come later.
    return raw.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  }

  Future<McpServer?> _saveDefinition() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name is required.')),
      );
      return null;
    }
    if (_transport == McpTransport.stdio && _command.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Command is required for stdio MCP.')),
      );
      return null;
    }
    if (_transport == McpTransport.http && _url.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('URL is required for HTTP MCP.')),
      );
      return null;
    }

    final server = McpServer(
      id: _existing?.id ?? const Uuid().v4(),
      name: name,
      transport: _transport,
      command: _transport == McpTransport.stdio ? _command.text.trim() : null,
      args: _transport == McpTransport.stdio ? _parseArgs() : const [],
      url: _transport == McpTransport.http ? _url.text.trim() : null,
      env: _parseEnv(),
      createdAt: _existing?.createdAt ?? DateTime.now(),
    );
    await ref.read(appDatabaseProvider).upsertMcpServer(server);
    ref.invalidate(mcpListProvider);
    setState(() => _existing = server);
    return server;
  }

  Future<void> _saveOnly() async {
    setState(() => _saving = true);
    try {
      final server = await _saveDefinition();
      if (server != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('MCP saved.')),
        );
        if (widget.mcpId == null) {
          context.replace('/settings/mcp/${server.id}');
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleHost(Host host, bool enable) async {
    final server = await _saveDefinition();
    if (server == null || !mounted) return;

    setState(() => _busyHosts.add(host.id));
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          enable
              ? 'Installing ${server.name} on ${host.displayLabel}…'
              : 'Removing ${server.name} from ${host.displayLabel}…',
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final deploy = ref.read(mcpDeployServiceProvider);
      final link = enable
          ? await deploy.deployToHost(mcp: server, host: host)
          : await deploy.removeFromHost(mcp: server, host: host);
      if (!mounted) return;
      setState(() {
        _links[host.id] = link;
        _busyHosts.remove(host.id);
      });
      final ok = link.installStatus == McpHostInstallStatus.installed ||
          link.installStatus == McpHostInstallStatus.removed;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? (enable
                    ? 'Done — ${server.name} installed on ${host.displayLabel}'
                    : 'Done — ${server.name} removed from ${host.displayLabel}')
                : 'Failed on ${host.displayLabel}: ${link.installDetail ?? link.installStatus.name}',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      SafeLog.d('MCP host toggle failed', e);
      if (!mounted) return;
      setState(() => _busyHosts.remove(host.id));
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _delete() async {
    if (_existing == null) return;
    await ref.read(appDatabaseProvider).deleteMcpServer(_existing!.id);
    ref.invalidate(mcpListProvider);
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _args.dispose();
    _url.dispose();
    _env.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? 'Add MCP' : _existing!.name),
        actions: [
          if (_existing != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _delete,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'filesystem',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<McpTransport>(
            segments: const [
              ButtonSegment(value: McpTransport.stdio, label: Text('stdio'), icon: Icon(Icons.terminal)),
              ButtonSegment(value: McpTransport.http, label: Text('HTTP'), icon: Icon(Icons.cloud_outlined)),
            ],
            selected: {_transport},
            onSelectionChanged: (s) => setState(() => _transport = s.first),
          ),
          const SizedBox(height: 12),
          if (_transport == McpTransport.stdio) ...[
            TextField(
              controller: _command,
              decoration: const InputDecoration(
                labelText: 'Command',
                hintText: 'npx',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _args,
              decoration: const InputDecoration(
                labelText: 'Args',
                hintText: '-y @modelcontextprotocol/server-filesystem /path',
                border: OutlineInputBorder(),
              ),
            ),
          ] else
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://mcp.example.com/sse',
                border: OutlineInputBorder(),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _env,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Env (KEY=value per line)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _saveOnly,
            child: Text(_saving ? 'Saving…' : 'Save MCP'),
          ),
          const SizedBox(height: 28),
          Text('Visible on hosts', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Toggle a host to install or remove this MCP over SSH (background).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (_hosts.isEmpty)
            const Text('Add a host first in the Hosts tab.')
          else
            ..._hosts.map((host) {
              final link = _links[host.id];
              final enabled = link?.enabled == true &&
                  link?.installStatus != McpHostInstallStatus.removed &&
                  link?.installStatus != McpHostInstallStatus.failed;
              final busy = _busyHosts.contains(host.id) ||
                  link?.installStatus == McpHostInstallStatus.installing;
              return SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(host.displayLabel),
                subtitle: Text(
                  [
                    host.endpointLabel,
                    if (link?.installStatus != null) link!.installStatus.name,
                    if (link?.installDetail != null &&
                        link!.installDetail!.isNotEmpty)
                      link.installDetail!,
                  ].join(' · '),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                value: enabled || busy && link?.enabled == true,
                onChanged: busy
                    ? null
                    : (v) => unawaited(_toggleHost(host, v)),
                secondary: busy
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        link?.installStatus == McpHostInstallStatus.installed
                            ? Icons.check_circle_outline
                            : Icons.dns_outlined,
                      ),
              );
            }),
          if (_existing != null) ...[
            const SizedBox(height: 16),
            Text(
              'ACP preview: ${jsonEncode(_existing!.toAcpConfig())}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
            ),
          ],
        ],
      ),
    );
  }
}
