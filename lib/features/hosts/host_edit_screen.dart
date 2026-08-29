import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/secure/safe_log.dart';
import '../agents/agents_screen.dart';
import 'hosts_screen.dart';

class HostEditScreen extends ConsumerStatefulWidget {
  const HostEditScreen({super.key, this.hostId});

  final String? hostId;

  @override
  ConsumerState<HostEditScreen> createState() => _HostEditScreenState();
}

class _HostEditScreenState extends ConsumerState<HostEditScreen> {
  final _alias = TextEditingController();
  final _hostname = TextEditingController();
  final _username = TextEditingController();
  final _port = TextEditingController(text: '22');
  String? _jumpHostId;
  bool _loading = true;
  bool _saving = false;
  String? _testResult;
  Host? _existing;
  List<Host> _allHosts = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    _allHosts = await db.listHosts();
    if (widget.hostId != null) {
      final host = await db.getHost(widget.hostId!);
      if (host != null) {
        _existing = host;
        _alias.text = host.alias;
        _hostname.text = host.hostname;
        _username.text = host.username;
        _port.text = '${host.port}';
        _jumpHostId = host.jumpHostId;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Host _draftHost({required String id}) {
    return Host(
      id: id,
      alias: _alias.text.trim().isEmpty
          ? _hostname.text.trim()
          : _alias.text.trim(),
      hostname: _hostname.text.trim(),
      username: _username.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      jumpHostId: _jumpHostId,
      sortOrder: _existing?.sortOrder ?? 0,
      createdAt: _existing?.createdAt ?? DateTime.now(),
    );
  }

  Future<void> _save() async {
    final hostname = _hostname.text.trim();
    final username = _username.text.trim();
    if (hostname.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hostname and username are required.')),
      );
      return;
    }
    if (_jumpHostId != null && _jumpHostId == (_existing?.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A host cannot use itself as ProxyJump.')),
      );
      return;
    }
    setState(() => _saving = true);
    final db = ref.read(appDatabaseProvider);
    final id = _existing?.id ?? const Uuid().v4();
    var host = _draftHost(id: id);
    if (_existing == null) {
      host = host.copyWith(sortOrder: await db.nextHostSortOrder());
    }
    await db.upsertHost(host);
    ref.invalidate(hostsListProvider);
    ref.invalidate(agentsTreeProvider);
    if (mounted) {
      setState(() => _saving = false);
      context.pop();
    }
  }

  Future<void> _test() async {
    setState(() {
      _saving = true;
      _testResult = 'Connecting…';
    });
    try {
      final host = _draftHost(id: _existing?.id ?? 'test');
      final result = await ref.read(sshServiceProvider).testConnection(host);
      setState(() {
        _testResult = result.ok ? 'OK: ${result.detail}' : 'Failed: ${result.error}';
      });
    } catch (e) {
      SafeLog.d('host test failed', e);
      setState(() => _testResult = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (_existing == null) return;
    await ref.read(appDatabaseProvider).deleteHost(_existing!.id);
    ref.invalidate(hostsListProvider);
    ref.invalidate(agentsTreeProvider);
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    _alias.dispose();
    _hostname.dispose();
    _username.dispose();
    _port.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final jumpCandidates = _allHosts
        .where((h) => h.id != _existing?.id)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: Text(_existing == null ? 'Add host' : 'Edit host'),
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
            controller: _alias,
            decoration: const InputDecoration(
              labelText: 'Alias',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _hostname,
            decoration: const InputDecoration(
              labelText: 'Hostname',
              hintText: 'localhost or example.com',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Port',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'ProxyJump (optional)',
              border: OutlineInputBorder(),
              helperText:
                  'Like SSH config ProxyJump: connect via another saved host first.',
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                isExpanded: true,
                value: jumpCandidates.any((h) => h.id == _jumpHostId)
                    ? _jumpHostId
                    : null,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('None — direct connection'),
                  ),
                  ...jumpCandidates.map(
                    (h) => DropdownMenuItem<String?>(
                      value: h.id,
                      child: Text('${h.displayLabel} (${h.endpointLabel})'),
                    ),
                  ),
                ],
                onChanged: (value) => setState(() => _jumpHostId = value),
              ),
            ),
          ),
          if (jumpCandidates.isEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Save a jump host first (e.g. tunneluser@16.62.171.242), then edit this host to select it as ProxyJump.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
              const SizedBox(width: 12),
              OutlinedButton(onPressed: _saving ? null : _test, child: const Text('Test')),
            ],
          ),
          if (_testResult != null) ...[
            const SizedBox(height: 16),
            SelectableText(_testResult!),
          ],
        ],
      ),
    );
  }
}
