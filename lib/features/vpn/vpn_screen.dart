import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/secure/safe_log.dart';
import '../../services/local_host_bootstrap.dart';
import '../../services/ssh_socks_service.dart';
import '../hosts/hosts_screen.dart';

class VpnScreen extends ConsumerStatefulWidget {
  const VpnScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<VpnScreen> createState() => _VpnScreenState();
}

class _VpnScreenState extends ConsumerState<VpnScreen> {
  String? _selectedHostId;
  SshProxyKind _kind = SshProxyKind.socks5;
  String? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final socks = ref.read(sshSocksServiceProvider);
      if (socks.active != null) {
        setState(() => _kind = socks.active!.kind);
      } else {
        setState(() => _kind = socks.lastKind);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hostsAsync = ref.watch(hostsListProvider);
    final socks = ref.watch(sshSocksServiceProvider);
    final tunnel = socks.active;
    final running = socks.isRunning;
    final dropped = !running && socks.lastError != null;

    final body = ListView(
      padding: EdgeInsets.all(widget.embedded ? 12 : 16),
      children: [
        Text(
          'SSH proxy',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          'Starts a local proxy through a saved host (like ssh -D). '
          'This is not a system-wide VPN — set FoxyProxy / your browser to '
          'use the address below (type must match SOCKS5 or HTTP).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        SegmentedButton<SshProxyKind>(
          segments: const [
            ButtonSegment(
              value: SshProxyKind.socks5,
              label: Text('SOCKS5'),
              icon: Icon(Icons.hub_outlined, size: 18),
            ),
            ButtonSegment(
              value: SshProxyKind.http,
              label: Text('HTTP'),
              icon: Icon(Icons.http, size: 18),
            ),
          ],
          selected: {_kind},
          onSelectionChanged: running || socks.busy
              ? null
              : (next) {
                  if (next.isEmpty) return;
                  setState(() {
                    _kind = next.first;
                    _status = null;
                  });
                },
        ),
        const SizedBox(height: 16),
        hostsAsync.when(
          data: (hosts) {
            final remote = hosts
                .where(
                  (h) => !(isDesktopLocalHostPlatform &&
                      isLocalThisComputerHost(h)),
                )
                .toList();
            if (remote.isEmpty) {
              return const Text(
                'Add a remote host under Hosts first. '
                'This Mac/PC cannot be used as a proxy jump.',
              );
            }
            final selectedId = _selectedHostId ??
                tunnel?.hostId ??
                remote.first.id;
            Host? selected;
            for (final h in remote) {
              if (h.id == selectedId) {
                selected = h;
                break;
              }
            }
            selected ??= remote.first;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Host',
                    border: OutlineInputBorder(),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: selected.id,
                      items: [
                        for (final h in remote)
                          DropdownMenuItem(
                            value: h.id,
                            child: Text(h.displayLabel),
                          ),
                      ],
                      onChanged: running || socks.busy
                          ? null
                          : (id) {
                              if (id == null) return;
                              setState(() {
                                _selectedHostId = id;
                                _status = null;
                              });
                            },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (dropped) ...[
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: ListTile(
                      leading: Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      title: const Text('Proxy connection dropped'),
                      subtitle: Text(socks.lastError!),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (running && tunnel != null) ...[
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading:
                        const Icon(Icons.check_circle, color: Colors.green),
                    title: Text(
                      '${tunnel.kind.label} listening on ${tunnel.endpoint}',
                    ),
                    subtitle: Text('via ${tunnel.hostLabel}'),
                    trailing: IconButton(
                      tooltip: 'Copy address',
                      icon: const Icon(Icons.copy),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: tunnel.endpoint),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Copied ${tunnel.endpoint}'),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonalIcon(
                    onPressed: socks.busy
                        ? null
                        : () async {
                            await socks.stop();
                            if (!mounted) return;
                            setState(
                              () => _status = '${tunnel.kind.label} proxy stopped.',
                            );
                          },
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('Stop'),
                  ),
                ] else ...[
                  FilledButton.icon(
                    onPressed: socks.busy
                        ? null
                        : () => _start(selected!, socks),
                    icon: socks.busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.vpn_lock),
                    label: Text(
                      socks.busy
                          ? 'Starting…'
                          : 'Start ${_kind.label}',
                    ),
                  ),
                ],
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Failed to load hosts: $e'),
        ),
        if (_status != null) ...[
          const SizedBox(height: 16),
          Text(_status!, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 24),
        Text(
          'Only one tunnel runs at a time. Starting another stops the '
          'current one. While the proxy is up, Agent Dock keeps a foreground '
          'notification so Android does not suspend the tunnel when you open '
          'the browser. If SSH still drops, you get a notification and an '
          'automatic reconnect (up to twice).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('VPN')),
      body: body,
    );
  }

  Future<void> _start(Host host, SshSocksService socks) async {
    setState(() => _status = 'Opening SSH…');
    try {
      final tunnel = await socks.start(host, kind: _kind);
      if (!mounted) return;
      setState(
        () => _status =
            '${tunnel.kind.label} ready at ${tunnel.endpoint}. '
            'In FoxyProxy use type ${tunnel.kind.label} and host 127.0.0.1 '
            'port ${tunnel.port}.',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${tunnel.kind.label} proxy on ${tunnel.endpoint}',
          ),
        ),
      );
    } catch (e) {
      SafeLog.d('VPN start UI', e);
      if (!mounted) return;
      setState(() => _status = 'Failed: $e');
    }
  }
}
