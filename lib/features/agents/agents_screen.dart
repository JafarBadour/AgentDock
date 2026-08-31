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
import '../../services/chat_session_runtime.dart';
import 'agent_status_indicators.dart';
import 'new_agent_flow.dart';

class AgentsTree {
  const AgentsTree({
    required this.hosts,
    required this.repos,
    required this.chatsByRepo,
  });

  final List<Host> hosts;
  final List<Repo> repos;
  final Map<String, List<Chat>> chatsByRepo;
}

/// Local-only tree. Never touches the network, so the list paints immediately.
final agentsTreeProvider = FutureProvider.autoDispose<AgentsTree>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final hosts = await db.listHosts();
  final repos = await db.listRepos();
  final chatsByRepo = <String, List<Chat>>{};
  for (final repo in repos) {
    chatsByRepo[repo.id] = await db.listChats(repo.id);
  }
  return AgentsTree(hosts: hosts, repos: repos, chatsByRepo: chatsByRepo);
});

/// Unread agent replies per chat id. Recomputed whenever a runtime writes.
final unreadCountsProvider =
    FutureProvider.autoDispose<Map<String, int>>((ref) async {
  ref.watch(chatActivityTickProvider);
  return ref.watch(appDatabaseProvider).unreadCounts();
});

/// Background catalog + transcript sync, kept off the render path.
final agentsSyncProvider = FutureProvider.autoDispose<String?>((ref) async {
  final hasKey = await ref.watch(secureStoreProvider).hasSshPrivateKey();
  if (!hasKey) return null;
  try {
    final note = await ref.read(agentDockServiceProvider).syncAllHostsCatalog();
    ref.invalidate(agentsTreeProvider);
    return note;
  } catch (e) {
    SafeLog.d('agentdock catalog sync failed', e);
    return 'Could not sync agents from remotes';
  }
});

/// One directory and everything under it.
class _Section {
  const _Section({required this.repo, required this.host, required this.chats});

  final Repo repo;
  final Host host;
  final List<Chat> chats;
}

class AgentsScreen extends ConsumerStatefulWidget {
  const AgentsScreen({super.key});

  @override
  ConsumerState<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends ConsumerState<AgentsScreen> {
  final Set<String> _collapsedRepos = {};

  /// Rows a swipe has already dismissed. Deleting is asynchronous, but a
  /// Dismissible must leave the tree the moment its handler fires, so drop it
  /// from the rendered list right away rather than waiting for the reload.
  final Set<String> _dismissedChats = {};

  List<_Section> _sections(AgentsTree tree) {
    final hostsById = {for (final h in tree.hosts) h.id: h};
    final hostRank = {
      for (var i = 0; i < tree.hosts.length; i++) tree.hosts[i].id: i,
    };

    Host hostFor(String id) =>
        hostsById[id] ??
        Host(
          id: id,
          alias: 'Unknown host',
          hostname: '?',
          username: '?',
          createdAt: DateTime.now(),
        );

    final sections = [
      for (final repo in tree.repos)
        _Section(
          repo: repo,
          host: hostFor(repo.hostId),
          chats: [
            for (final chat in tree.chatsByRepo[repo.id] ?? const <Chat>[])
              if (!_dismissedChats.contains(chat.id)) chat,
          ],
        ),
    ];
    // Keep each host's folders together so drag-to-reorder stays meaningful.
    sections.sort((a, b) {
      final ra = hostRank[a.repo.hostId] ?? 1 << 20;
      final rb = hostRank[b.repo.hostId] ?? 1 << 20;
      return ra == rb ? 0 : ra.compareTo(rb);
    });
    return sections;
  }

  Future<void> _reorderRepos(
    List<_Section> sections,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    // Folder order is stored per host, so dragging across hosts has no
    // meaning; snap back instead of silently writing a bogus order.
    if (sections[oldIndex].repo.hostId != sections[newIndex].repo.hostId) {
      return;
    }
    final hostId = sections[oldIndex].repo.hostId;
    final next = [...sections];
    next.insert(newIndex, next.removeAt(oldIndex));
    await ref.read(appDatabaseProvider).reorderRepos(
          hostId,
          [
            for (final s in next)
              if (s.repo.hostId == hostId) s.repo.id,
          ],
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
    next.insert(newIndex, next.removeAt(oldIndex));
    await ref.read(appDatabaseProvider).reorderChats(
          repo.id,
          next.map((c) => c.id).toList(),
        );
    ref.invalidate(agentsTreeProvider);
  }

  Future<bool> _confirmDeleteChat(Host host, Chat chat) async {
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
    return ok == true;
  }

  Future<void> _deleteChat(Host host, Chat chat) async {
    await ref.read(appDatabaseProvider).deleteChat(chat.id);
    final agentDock = ref.read(agentDockServiceProvider);
    final runtimeHost = ref.read(agentRuntimeHostProvider);
    unawaited(() async {
      try {
        // Also stop the detached agent, otherwise it keeps running on the host
        // with nothing pointing at it.
        await runtimeHost.stop(host, chat.id);
      } catch (e) {
        SafeLog.d('stopping remote agent failed', e);
      }
      try {
        await agentDock.deleteAgent(host: host, chatId: chat.id);
      } catch (e) {
        SafeLog.d('agentdock delete failed', e);
      }
    }());
    ref.invalidate(agentsTreeProvider);
    ref.invalidate(unreadCountsProvider);
  }

  Future<void> _markRead(Chat chat) async {
    await ref.read(appDatabaseProvider).markChatRead(chat.id);
    // Let the host know, so the badge is already cleared on your other devices.
    ref.read(agentDockServiceProvider).schedulePushChat(chat.id);
    ref.invalidate(unreadCountsProvider);
  }

  Future<void> _openChat(Chat chat) async {
    await _markRead(chat);
    if (!mounted) return;
    await context.push('/agents/chat/${chat.id}');
    if (!mounted) return;
    // The transcript almost certainly moved on while we were inside it.
    await _markRead(chat);
    ref.invalidate(agentsTreeProvider);
  }

  @override
  Widget build(BuildContext context) {
    final treeAsync = ref.watch(agentsTreeProvider);
    final syncAsync = ref.watch(agentsSyncProvider);
    final unread = ref.watch(unreadCountsProvider).valueOrNull ?? const {};
    final runtimes = ref.watch(activeAcpSessionsProvider);
    final syncNote = syncAsync.isLoading
        ? 'Syncing agents from remotes…'
        : syncAsync.valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agents'),
        actions: [
          IconButton(
            tooltip: 'Refresh / sync ~/.agentdock',
            onPressed: () {
              setState(_dismissedChats.clear);
              ref.invalidate(agentsTreeProvider);
              ref.invalidate(agentsSyncProvider);
              ref.invalidate(unreadCountsProvider);
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: treeAsync.when(
        data: (tree) {
          final sections = _sections(tree);
          if (sections.isEmpty) return _EmptyState(hasHosts: tree.hosts.isNotEmpty);

          return RefreshIndicator(
            onRefresh: () async {
              setState(_dismissedChats.clear);
              ref.invalidate(agentsSyncProvider);
              await ref.read(agentsSyncProvider.future);
              ref.invalidate(agentsTreeProvider);
              ref.invalidate(unreadCountsProvider);
              await ref.read(agentsTreeProvider.future);
            },
            child: ReorderableListView.builder(
              padding: const EdgeInsets.only(top: 4, bottom: 32),
              buildDefaultDragHandles: false,
              header: syncNote == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                      child: Text(
                        syncNote,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
              itemCount: sections.length,
              onReorder: (o, n) => unawaited(_reorderRepos(sections, o, n)),
              proxyDecorator: (child, index, animation) => Material(
                elevation: 6,
                color: Theme.of(context).colorScheme.surface,
                child: child,
              ),
              itemBuilder: (context, index) {
                final section = sections[index];
                return _RepoSection(
                  key: ValueKey('repo-${section.repo.id}'),
                  index: index,
                  section: section,
                  runtimes: runtimes,
                  unread: unread,
                  collapsed: _collapsedRepos.contains(section.repo.id),
                  onToggle: () => setState(() {
                    if (!_collapsedRepos.remove(section.repo.id)) {
                      _collapsedRepos.add(section.repo.id);
                    }
                  }),
                  onNewAgent: () => startNewAgentChat(
                    context: context,
                    ref: ref,
                    host: section.host,
                    repo: section.repo,
                  ),
                  onOpenChat: _openChat,
                  onConfirmDeleteChat: (chat) =>
                      _confirmDeleteChat(section.host, chat),
                  onDeleteChat: (chat) =>
                      unawaited(_deleteChat(section.host, chat)),
                  onDismissChat: (chat) {
                    setState(() => _dismissedChats.add(chat.id));
                    unawaited(_deleteChat(section.host, chat));
                  },
                  onReorderChats: (o, n) => unawaited(
                    _reorderChats(section.repo, section.chats, o, n),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasHosts});

  final bool hasHosts;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              hasHosts
                  ? 'No folders yet. Add a remote directory on one of your hosts, '
                      'then start agents inside it.'
                  : 'Add a host, then a folder (remote directory). '
                      'Agents live inside folders.',
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
}

class _RepoSection extends StatelessWidget {
  const _RepoSection({
    super.key,
    required this.index,
    required this.section,
    required this.runtimes,
    required this.unread,
    required this.collapsed,
    required this.onToggle,
    required this.onNewAgent,
    required this.onOpenChat,
    required this.onConfirmDeleteChat,
    required this.onDeleteChat,
    required this.onDismissChat,
    required this.onReorderChats,
  });

  final int index;
  final _Section section;
  final Map<String, ChatSessionRuntime> runtimes;
  final Map<String, int> unread;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback onNewAgent;
  final void Function(Chat chat) onOpenChat;
  final Future<bool> Function(Chat chat) onConfirmDeleteChat;
  final void Function(Chat chat) onDeleteChat;
  final void Function(Chat chat) onDismissChat;
  final void Function(int oldIndex, int newIndex) onReorderChats;

  @override
  Widget build(BuildContext context) {
    final chats = section.chats;
    final busy = chats.any((c) => runtimes[c.id]?.isWorking ?? false);
    final unreadHere = chats.fold<int>(0, (sum, c) => sum + (unread[c.id] ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReorderableDelayedDragStartListener(
          index: index,
          child: _RepoHeader(
            repo: section.repo,
            host: section.host,
            collapsed: collapsed,
            busy: busy,
            hiddenUnread: collapsed ? unreadHere : 0,
            onToggle: onToggle,
            onNewAgent: onNewAgent,
          ),
        ),
        if (!collapsed)
          if (chats.isEmpty)
            _EmptyRepoRow(onNewAgent: onNewAgent)
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: chats.length,
              onReorder: onReorderChats,
              proxyDecorator: (child, i, animation) => Material(
                elevation: 6,
                color: Theme.of(context).colorScheme.surface,
                child: child,
              ),
              itemBuilder: (context, i) {
                final chat = chats[i];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey('chat-${chat.id}'),
                  index: i,
                  child: Dismissible(
                    key: ValueKey('dismiss-${chat.id}'),
                    direction: DismissDirection.endToStart,
                    background: const _DeleteBackground(),
                    confirmDismiss: (_) => onConfirmDeleteChat(chat),
                    onDismissed: (_) => onDismissChat(chat),
                    child: _AgentRow(
                      chat: chat,
                      runtime: runtimes[chat.id],
                      unread: unread[chat.id] ?? 0,
                      onTap: () => onOpenChat(chat),
                      onDelete: () async {
                        if (await onConfirmDeleteChat(chat)) {
                          onDeleteChat(chat);
                        }
                      },
                    ),
                  ),
                );
              },
            ),
      ],
    );
  }
}

class _RepoHeader extends StatelessWidget {
  const _RepoHeader({
    required this.repo,
    required this.host,
    required this.collapsed,
    required this.busy,
    required this.hiddenUnread,
    required this.onToggle,
    required this.onNewAgent,
  });

  final Repo repo;
  final Host host;
  final bool collapsed;
  final bool busy;
  final int hiddenUnread;
  final VoidCallback onToggle;
  final VoidCallback onNewAgent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 14, 4, 6),
        child: Row(
          children: [
            // The whole label group is one flexible unit, so a long folder name
            // or host alias eats into itself rather than shoving the + inward.
            Expanded(
              child: Row(
                children: [
                  Icon(
                    collapsed
                        ? Icons.folder_outlined
                        : Icons.folder_open_outlined,
                    size: 20,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      repo.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(child: _HostTag(host: host)),
                  if (busy) ...[
                    const SizedBox(width: 8),
                    const WorkingDots(size: 4),
                  ],
                  if (hiddenUnread > 0) ...[
                    const SizedBox(width: 8),
                    UnreadBadge(count: hiddenUnread),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'New agent in ${repo.name}',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.add, size: 20),
              onPressed: onNewAgent,
            ),
          ],
        ),
      ),
    );
  }
}

/// Which machine a folder lives on, shown inline so the host tree does not
/// need its own level of nesting.
class _HostTag extends StatelessWidget {
  const _HostTag({required this.host});

  final Host host;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '${host.username}@${host.hostname}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dns_outlined,
              size: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 110),
              child: Text(
                host.alias,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyRepoRow extends StatelessWidget {
  const _EmptyRepoRow({required this.onNewAgent});

  final VoidCallback onNewAgent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onNewAgent,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(42, 8, 16, 12),
        child: Text(
          'No agents yet — tap to start one',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ),
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({
    required this.chat,
    required this.runtime,
    required this.unread,
    required this.onTap,
    required this.onDelete,
  });

  final Chat chat;
  final ChatSessionRuntime? runtime;
  final int unread;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // A null runtime still needs a Listenable; merging nothing gives one that
    // never fires, so the row simply renders its static state.
    return ListenableBuilder(
      listenable: runtime ?? Listenable.merge(const []),
      builder: (context, _) => _build(context),
    );
  }

  /// Swipe-to-delete is the phone gesture, but it is invisible with a mouse,
  /// so offer the same action on right-click.
  Future<void> _showMenu(BuildContext context, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline),
            title: Text('Delete agent'),
          ),
        ),
      ],
    );
    if (choice == 'delete') onDelete();
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final working = runtime?.isWorking ?? false;
    final hasUnread = unread > 0;

    return InkWell(
      onTap: onTap,
      onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition),
      child: Container(
        color: hasUnread
            ? unreadAccent(context).withValues(alpha: 0.06)
            : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Center(
                child: working
                    ? const WorkingDots()
                    : Icon(
                        chat.provider == AgentProvider.cursor
                            ? Icons.smart_toy_outlined
                            : Icons.psychology_alt_outlined,
                        size: 18,
                        color: hasUnread
                            ? unreadAccent(context)
                            : theme.colorScheme.onSurfaceVariant,
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chat.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          hasUnread ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (working)
                    Text(
                      'Working…',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: theme.colorScheme.primary),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              shortTimeAgo(chat.updatedAt),
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            if (hasUnread) ...[
              const SizedBox(width: 8),
              UnreadBadge(count: unread),
            ],
          ],
        ),
      ),
    );
  }
}

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.errorContainer,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      child: Icon(
        Icons.delete_outline,
        color: Theme.of(context).colorScheme.onErrorContainer,
      ),
    );
  }
}
