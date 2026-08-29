import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../hosts/hosts_screen.dart';

class TerminalHostsScreen extends ConsumerWidget {
  const TerminalHostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Reuse same host list source as Hosts tab.
    final hostsAsync = ref.watch(hostsListProvider);
    final hasKey = ref.watch(hasSshKeyProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Terminal')),
      body: Column(
        children: [
          hasKey.when(
            data: (ok) => ok
                ? const SizedBox.shrink()
                : MaterialBanner(
                    content: const Text('Add an SSH private key in Connect first.'),
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
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'No hosts yet. Add one, then open a normal SSH shell here.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: () => context.go('/hosts'),
                            child: const Text('Go to Hosts'),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: hosts.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final host = hosts[index];
                    return ListTile(
                      leading: const Icon(Icons.terminal),
                      title: Text(host.displayLabel),
                      subtitle: Text(
                        host.jumpHostId == null
                            ? host.endpointLabel
                            : '${host.endpointLabel} (ProxyJump)',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => context.push('/terminal/session/${host.id}'),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
        ],
      ),
    );
  }
}
