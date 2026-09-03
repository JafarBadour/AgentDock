import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';

final hostsListProvider = FutureProvider.autoDispose<List<Host>>((ref) {
  return ref.watch(appDatabaseProvider).listHosts();
});

class HostsScreen extends ConsumerWidget {
  const HostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hostsAsync = ref.watch(hostsListProvider);
    final hasKey = ref.watch(hasSshKeyProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Hosts')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/hosts/new'),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          hasKey.when(
            data: (ok) => ok
                ? const SizedBox.shrink()
                : MaterialBanner(
                    content: const Text(
                      'Add an SSH private key in Connect before testing hosts.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => context.go('/connect'),
                        child: const Text('Connect'),
                      ),
                    ],
                  ),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          Expanded(
            child: hostsAsync.when(
              data: (hosts) {
                if (hosts.isEmpty) {
                  return const Center(
                    child: Text(
                      'No hosts yet. Add a remote like an SSH config entry.',
                    ),
                  );
                }
                final byId = {for (final h in hosts) h.id: h};
                return ListView.separated(
                  itemCount: hosts.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final host = hosts[index];
                    final jump = host.jumpHostId == null
                        ? null
                        : byId[host.jumpHostId!];
                    final via =
                        jump == null ? null : ' via ${jump.displayLabel}';
                    return ListTile(
                      title: Text(host.displayLabel),
                      subtitle: Text(
                        '${host.endpointLabel}${via ?? ''}\n'
                        'Tap repos · terminal opens SSH shell',
                      ),
                      isThreeLine: true,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Open terminal',
                            icon: const Icon(Icons.terminal),
                            onPressed: () => context.push(
                              '/hosts/terminal/${host.id}',
                            ),
                          ),
                          IconButton(
                            tooltip: 'Edit host',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () =>
                                context.push('/hosts/edit/${host.id}'),
                          ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      onTap: () => context.push('/hosts/${host.id}/repos'),
                      onLongPress: () =>
                          context.push('/hosts/edit/${host.id}'),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
            ),
          ),
        ],
      ),
    );
  }
}
