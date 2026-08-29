import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/models/agent_provider.dart';
import '../../data/models/chat.dart';
import '../../data/models/host.dart';
import '../../data/models/repo.dart';
import '../../data/secure/safe_log.dart';
import 'new_agent_flow.dart';

class AgentsTree {
  const AgentsTree({
    required this.hosts,
    required this.repos,
    required this.chatsByRepo,
    this.syncNote,
  });

  final List<Host> hosts;
  final List<Repo> repos;
  final Map<String, List<Chat>> chatsByRepo;
  final String? syncNote;
}

final agentsTreeProvider = FutureProvider.autoDispose<AgentsTree>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final hasKey = await ref.watch(secureStoreProvider).hasSshPrivateKey();
  String? syncNote;
  if (hasKey) {
    try {
      syncNote = await ref.read(agentDockServiceProvider).syncAllHostsCatalog();
    } catch (e) {
      SafeLog.d('agentdock catalog sync failed', e);
      syncNote = 'Could not sync agents from remotes';
    }
  }

  final hosts = await db.listHosts();
  final repos = await db.listRepos();
  final chatsByRepo = <String, List<Chat>>{};
  for (final repo in repos) {
    chatsByRepo[repo.id] = await db.listChats(repo.id);
  }
  return AgentsTree(
    hosts: hosts,
    repos: repos,
    chatsByRepo: chatsByRepo,
    syncNote: syncNote,
  );
});

class AgentsScreen extends ConsumerStatefulWidget {
  const AgentsScreen({super.key});

  @override
  ConsumerState<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends ConsumerState<AgentsScreen> {
  final Set<String> _expandedHosts = {};
  final Set<String> _expandedRepos = {};
  bool _seededExpanded = false;

  void _seedExpanded(AgentsTree tree) {
    if (_seededExpanded) return;
    _seededExpanded = true;
    for (final h in tree.hosts) {
      _expandedHosts.add(h.id);
    }
    for (final r in tree.repos) {
      _expandedRepos.add(r.id);
    }
  }

  Future<void> _reorderHosts(List<Host> hosts, int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final next = [...hosts];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    await ref.read(appDatabaseProvider).reorderHosts(next.map((h) => h.id).toList());
    ref.invalidate(agentsTreeProvider);
  }

  Future<void> _reorderRepos(
    Host host,
    List<Repo> repos,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final next = [...repos];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    await ref.read(appDatabaseProvider).reorderRepos(
          host.id,
          next.map((r) => r.id).toList(),
        );
    ref.invalidate(agentsTreeProvider);
  }

  Future<void> _reorderChats(
    Repo repo,
    List<Chat> chats,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final next = [...chats];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    await ref.read(appDatabaseProvider).reorderChats(
          repo.id,
          next.map((c) => c.id).toList(),
        );
    ref.invalidate(agentsTreeProvider);
  }

  Future<void> _deleteChat(Host host, Chat chat) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete agent?'),
        content: Text(
          'Remove “${chat.title}” from this device and ~/.agentdock on ${host.displayLabel}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    await ref.read(appDatabaseProvider).deleteChat(chat.id);
    unawaited(() async {
      try {
        await ref.read(agentDockServiceProvider).deleteAgent(
              host: host,
              chatId: chat.id,
            );
      } catch (e) {
        SafeLog.d('agentdock delete failed', e);
      }
    }());
    ref.invalidate(agentsTreeProvider);
  }

  @override
  Widget build(BuildContext context) {
    final treeAsync = ref.watch(agentsTreeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agents'),
        actions: [
          IconButton(
            tooltip: 'Refresh / sync ~/.agentdock',
            onPressed: () => ref.invalidate(agentsTreeProvider),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: treeAsync.when(
        data: (tree) {
          _seedExpanded(tree);

          if (tree.hosts.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Add a host, then a repo (remote folder). Chats under each repo are agents.\n'
                      'Long-press the handle to drag hosts, folders, and agents.',
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

          final byHost = <String, List<Repo>>{};
          for (final repo in tree.repos) {
            byHost.putIfAbsent(repo.hostId, () => []).add(repo);
          }

          final hosts = [
            ...tree.hosts,
            for (final hostId in byHost.keys)
              if (!tree.hosts.any((h) => h.id == hostId))
                Host(
                  id: hostId,
                  alias: 'Unknown host',
                  hostname: '?',
                  username: '?',
                  createdAt: DateTime.now(),
                ),
          ];

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(agentsTreeProvider);
              await ref.read(agentsTreeProvider.future);
            },
            child: ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              buildDefaultDragHandles: false,
              proxyDecorator: (child, index, animation) {
                return Material(
                  elevation: 4,
                  color: Theme.of(context).colorScheme.surface,
                  child: child,
                );
              },
              itemCount: hosts.length + (tree.syncNote != null ? 1 : 0),
              onReorder: (oldIndex, newIndex) {
                var o = oldIndex;
                var n = newIndex;
                if (tree.syncNote != null) {
                  if (o == 0 || n == 0) return;
                  o -= 1;
                  n -= 1;
                }
                unawaited(_reorderHosts(hosts, o, n));
              },
              itemBuilder: (context, index) {
                if (tree.syncNote != null) {
                  if (index == 0) {
                    return Padding(
                      key: const ValueKey('sync-note'),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        tree.syncNote!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    );
                  }
                  index -= 1;
                }

                final host = hosts[index];
                final repos = byHost[host.id] ?? const <Repo>[];
                final expanded = _expandedHosts.contains(host.id);

                return Card(
                  key: ValueKey('host-${host.id}'),
                  margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Column(
                    children: [
                      ListTile(
                        leading: IconButton(
                          tooltip: expanded ? 'Collapse' : 'Expand',
                          icon: Icon(
                            expanded
                                ? Icons.expand_more
                                : Icons.chevron_right,
                          ),
                          onPressed: () {
                            setState(() {
                              if (expanded) {
                                _expandedHosts.remove(host.id);
                              } else {
                                _expandedHosts.add(host.id);
                              }
                            });
                          },
                        ),
                        title: Text(host.displayLabel),
                        subtitle: Text(
                          repos.isNotEmpty
                              ? '${repos.length} folder(s)'
                              : 'No folders yet',
                        ),
                        trailing: ReorderableDragStartListener(
                          index: tree.syncNote != null ? index + 1 : index,
                          child: const Icon(Icons.drag_handle),
                        ),
                      ),
                      if (expanded) ...[
                        if (repos.isEmpty)
                          ListTile(
                            leading: const Icon(Icons.create_new_folder_outlined),
                            title: const Text('Add a folder'),
                            subtitle: const Text('Pick a remote directory on this host'),
                            onTap: () =>
                                context.push('/hosts/${host.id}/repos/new'),
                          )
                        else
                          ReorderableListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            buildDefaultDragHandles: false,
                            itemCount: repos.length,
                            onReorder: (oldIndex, newIndex) {
                              unawaited(
                                _reorderRepos(host, repos, oldIndex, newIndex),
                              );
                            },
                            itemBuilder: (context, repoIndex) {
                              final repo = repos[repoIndex];
                              final chats =
                                  tree.chatsByRepo[repo.id] ?? const <Chat>[];
                              final repoExpanded =
                                  _expandedRepos.contains(repo.id);
                              return _RepoTile(
                                key: ValueKey('repo-${repo.id}'),
                                host: host,
                                repo: repo,
                                chats: chats,
                                expanded: repoExpanded,
                                dragIndex: repoIndex,
                                onToggle: () {
                                  setState(() {
                                    if (repoExpanded) {
                                      _expandedRepos.remove(repo.id);
                                    } else {
                                      _expandedRepos.add(repo.id);
                                    }
                                  });
                                },
                                onReorderChats: (o, n) =>
                                    unawaited(_reorderChats(repo, chats, o, n)),
                                onDeleteChat: (chat) =>
                                    unawaited(_deleteChat(host, chat)),
                                onNewAgent: () => startNewAgentChat(
                                  context: context,
                                  ref: ref,
                                  host: host,
                                  repo: repo,
                                ),
                              );
                            },
                          ),
                        const SizedBox(height: 4),
                      ],
                    ],
                  ),
                );
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      ),
    );
  }
}

class _RepoTile extends StatelessWidget {
  const _RepoTile({
    super.key,
    required this.host,
    required this.repo,
    required this.chats,
    required this.expanded,
    required this.dragIndex,
    required this.onToggle,
    required this.onReorderChats,
    required this.onDeleteChat,
    required this.onNewAgent,
  });

  final Host host;
  final Repo repo;
  final List<Chat> chats;
  final bool expanded;
  final int dragIndex;
  final VoidCallback onToggle;
  final void Function(int oldIndex, int newIndex) onReorderChats;
  final void Function(Chat chat) onDeleteChat;
  final VoidCallback onNewAgent;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: const EdgeInsets.only(left: 8, right: 8),
          leading: IconButton(
            tooltip: expanded ? 'Collapse' : 'Expand',
            icon: Icon(expanded ? Icons.expand_more : Icons.chevron_right),
            onPressed: onToggle,
          ),
          title: Text(repo.name),
          subtitle: Text(
            repo.remotePath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: ReorderableDragStartListener(
            index: dragIndex,
            child: const Icon(Icons.drag_handle),
          ),
        ),
        if (expanded) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: onNewAgent,
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('New agent'),
              ),
            ),
          ),
          if (chats.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(72, 0, 16, 12),
              child: Text('No agents yet'),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: chats.length,
              onReorder: onReorderChats,
              itemBuilder: (context, chatIndex) {
                final chat = chats[chatIndex];
                return ListTile(
                  key: ValueKey('chat-${chat.id}'),
                  contentPadding: const EdgeInsets.only(left: 48, right: 4),
                  leading: Icon(
                    chat.provider == AgentProvider.cursor
                        ? Icons.smart_toy_outlined
                        : Icons.psychology_alt,
                  ),
                  title: Text(chat.title),
                  subtitle: Text('${chat.provider.label} · ${chat.status.name}'),
                  onTap: () => context.push('/agents/chat/${chat.id}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Delete agent',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => onDeleteChat(chat),
                      ),
                      ReorderableDragStartListener(
                        index: chatIndex,
                        child: const Icon(Icons.drag_handle),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ],
    );
  }
}
