import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/models/repo.dart';
import '../agents/new_agent_flow.dart';

final reposForHostProvider =
    FutureProvider.autoDispose.family<List<Repo>, String>((ref, hostId) {
  return ref.watch(appDatabaseProvider).listRepos(hostId: hostId);
});

class ReposScreen extends ConsumerWidget {
  const ReposScreen({super.key, required this.hostId});

  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reposAsync = ref.watch(reposForHostProvider(hostId));
    final hostAsync = ref.watch(_hostProvider(hostId));

    return Scaffold(
      appBar: AppBar(
        title: Text(hostAsync.valueOrNull?.displayLabel ?? 'Repos'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => context.push('/hosts/edit/$hostId'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/hosts/$hostId/repos/new'),
        child: const Icon(Icons.create_new_folder_outlined),
      ),
      body: reposAsync.when(
        data: (repos) {
          if (repos.isEmpty) {
            return const Center(
              child: Text('No repos yet. Add a remote directory path.'),
            );
          }
          final host = hostAsync.valueOrNull;
          return ListView.separated(
            itemCount: repos.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final repo = repos[index];
              return ListTile(
                title: Text(repo.name),
                subtitle: Text(repo.remotePath),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'New agent',
                      icon: const Icon(Icons.add_comment_outlined),
                      onPressed: host == null
                          ? null
                          : () => startNewAgentChat(
                                context: context,
                                ref: ref,
                                host: host,
                                repo: repo,
                              ),
                    ),
                    IconButton(
                      tooltip: 'Edit repo',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () =>
                          context.push('/hosts/$hostId/repos/edit/${repo.id}'),
                    ),
                  ],
                ),
                onTap: host == null
                    ? null
                    : () => startNewAgentChat(
                          context: context,
                          ref: ref,
                          host: host,
                          repo: repo,
                        ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
    );
  }
}

final _hostProvider = FutureProvider.autoDispose.family<Host?, String>((ref, hostId) {
  return ref.watch(appDatabaseProvider).getHost(hostId);
});
