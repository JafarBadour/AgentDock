import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/archon_chat.dart';
import '../../data/models/host.dart';
import '../../data/secure/safe_log.dart';
import '../agents/agents_screen.dart';
import '../agents/chat_screen.dart';
import 'archon_settings.dart';

/// Where Archon currently runs, or null when it has not been placed yet.
final archonHostProvider = FutureProvider.autoDispose<Host?>((ref) async {
  ref.watch(agentsCatalogEpochProvider);
  return ref.watch(archonServiceProvider).currentHost();
});

/// Archon: one manager for every agent on every host.
///
/// Once placed this is the ordinary chat screen pointed at Archon's reserved
/// chat, so the transcript, streaming and reconnect behaviour are the ones
/// already in use rather than a second copy of them.
class ArchonScreen extends ConsumerWidget {
  const ArchonScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final host = ref.watch(archonHostProvider);
    return host.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Archon')),
        body: Center(child: Text('Could not load Archon — $e')),
      ),
      data: (placed) => placed == null
          ? const _ChooseArchonHost()
          : const ChatScreen(chatId: kArchonChatId),
    );
  }
}

/// Archon runs on exactly one host at a time, chosen here.
class _ChooseArchonHost extends ConsumerStatefulWidget {
  const _ChooseArchonHost();

  @override
  ConsumerState<_ChooseArchonHost> createState() => _ChooseArchonHostState();
}

class _ChooseArchonHostState extends ConsumerState<_ChooseArchonHost> {
  String? _placing;

  Future<void> _place(Host host) async {
    setState(() => _placing = host.id);
    try {
      await ref.read(archonServiceProvider).placeOn(host);
      ref.read(agentsCatalogEpochProvider.notifier).state++;
      ref.invalidate(archonHostProvider);
    } catch (e) {
      SafeLog.d('placing archon failed', e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not start Archon — $e')));
    } finally {
      if (mounted) setState(() => _placing = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tree = ref.watch(agentsTreeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Archon'),
        actions: [
          IconButton(
            tooltip: 'Archon settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => unawaited(ArchonSettingsSheet.show(context)),
          ),
        ],
      ),
      body: tree.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load hosts — $e')),
        data: (data) {
          if (data.hosts.isEmpty) {
            return const _Explainer(
              icon: Icons.dns_outlined,
              title: 'Add a host first',
              body:
                  'Archon runs on one of your hosts and directs the agents on '
                  'all of them. Add a host, then come back.',
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pick a host for Archon',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Archon runs there in a folder of its own and reaches '
                      'your other hosts from it. You can move it later; the '
                      'conversation comes with it.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              for (final host in data.hosts)
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(host.alias),
                  subtitle: Text('${host.username}@${host.hostname}'),
                  trailing: _placing == host.id
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right),
                  onTap: _placing == null ? () => unawaited(_place(host)) : null,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
