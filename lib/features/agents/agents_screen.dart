import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_theme.dart';
import '../../app/platform_layout.dart';
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
///
/// Do **not** watch [chatActivityTickProvider] here — that tick fires while a
/// turn streams and was forcing a full SQLite reload (and loading flash) every
/// ~700ms. Live working/delta UI comes from [activeAcpSessionsProvider] +
/// ListenableBuilder on each row.
final agentsTreeProvider = FutureProvider.autoDispose<AgentsTree>((ref) async {
  ref.watch(agentsCatalogEpochProvider);
  final db = ref.watch(appDatabaseProvider);
  final hosts = await db.listHosts();
  final repos = await db.listRepos();
  final chatsByRepo = <String, List<Chat>>{};
  for (final repo in repos) {
    chatsByRepo[repo.id] = await db.listChats(repo.id);
  }
  return AgentsTree(hosts: hosts, repos: repos, chatsByRepo: chatsByRepo);
});

/// Unread agent replies per chat id. Recomputed on [chatActivityTickProvider]
/// (debounced ~8s while a turn runs). The Agents screen must not watch this at
/// the list root — only badge widgets — or the sidebar remounts and flickers.
final unreadCountsProvider =
    FutureProvider.autoDispose<Map<String, int>>((ref) async {
  ref.watch(chatActivityTickProvider);
  return ref.watch(appDatabaseProvider).unreadCounts();
});

/// Background catalog sync — runs once per Agents screen lifetime, not on a
/// timer. Manual refresh re-invalidates this provider.
final agentsSyncProvider = FutureProvider.autoDispose<String?>((ref) async {
  final hasKey = await ref.watch(secureStoreProvider).hasSshPrivateKey();
  // Catalog sync needs some form of SSH auth; password-only hosts are fine —
  // syncAllHostsCatalog will skip hosts it can't reach.
  final store = ref.watch(secureStoreProvider);
  final hosts = await ref.watch(appDatabaseProvider).listHosts();
  var canAuth = hasKey;
  if (!canAuth) {
    for (final h in hosts) {
      if (await store.hasHostPassword(h.id)) {
        canAuth = true;
        break;
      }
    }
  }
  if (!canAuth) return null;
  try {
    final note = await ref.read(agentDockServiceProvider).syncAllHostsCatalog();
    // Only reload the tree when something actually merged — otherwise the
    // sidebar flashes for a no-op sync.
    if (note != null && note.startsWith('Synced')) {
      ref.invalidate(agentsTreeProvider);
    }
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

/// Flat chat row for the phone Agents list.
class _FlatChat {
  const _FlatChat({
    required this.chat,
    required this.host,
    required this.repo,
  });

  final Chat chat;
  final Host host;
  final Repo repo;

  DateTime get lastInteracted {
    final read = chat.lastReadAt;
    if (read == null) return chat.updatedAt;
    return read.isAfter(chat.updatedAt) ? read : chat.updatedAt;
  }
}

class AgentsScreen extends ConsumerStatefulWidget {
  const AgentsScreen({
    super.key,
    this.embedded = false,
    this.selectedChatId,
  });

  /// Sidebar mode for macOS / desktop shell.
  final bool embedded;
  final String? selectedChatId;

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

  List<_FlatChat> _flatChats(AgentsTree tree) {
    final hostsById = {for (final h in tree.hosts) h.id: h};
    final reposById = {for (final r in tree.repos) r.id: r};
    final out = <_FlatChat>[];
    for (final entry in tree.chatsByRepo.entries) {
      final repo = reposById[entry.key];
      if (repo == null) continue;
      final host = hostsById[repo.hostId];
      if (host == null) continue;
      for (final chat in entry.value) {
        if (_dismissedChats.contains(chat.id)) continue;
        out.add(_FlatChat(chat: chat, host: host, repo: repo));
      }
    }
    out.sort((a, b) => b.lastInteracted.compareTo(a.lastInteracted));
    return out;
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
    // Tear down the live bridge first so it cannot recreate the host record.
    try {
      await ref.read(activeAcpSessionsProvider.notifier).close(chat.id);
    } catch (e) {
      SafeLog.d('closing ACP session on delete failed', e);
    }
    await ref.read(appDatabaseProvider).deleteChat(chat.id);
    ref.invalidate(agentsTreeProvider);
    ref.invalidate(unreadCountsProvider);

    final agentDock = ref.read(agentDockServiceProvider);
    final runtimeHost = ref.read(agentRuntimeHostProvider);
    try {
      await runtimeHost.stop(host, chat.id);
    } catch (e) {
      SafeLog.d('stopping remote agent failed', e);
    }
    try {
      await agentDock.deleteAgent(host: host, chatId: chat.id);
    } catch (e) {
      SafeLog.d('agentdock delete failed', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Removed locally, but host delete failed — sync may bring it back. $e',
            ),
          ),
        );
      }
    }
  }

  Future<void> _markRead(Chat chat) async {
    await ref.read(appDatabaseProvider).markChatRead(chat.id);
    // Let the host know, so the badge is already cleared on your other devices.
    ref.read(agentDockServiceProvider).schedulePushChat(chat.id);
    ref.invalidate(unreadCountsProvider);
  }

  Future<void> _renameChat(Chat chat) async {
    final controller = TextEditingController(text: chat.title);
    final next = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename agent'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // Dialog disposed the field; copy before using.
    if (next == null || next.isEmpty || next == chat.title) return;
    final now = DateTime.now();
    final updated = chat.copyWith(
      title: next,
      titleUpdatedAt: now,
      updatedAt: now,
    );
    await ref.read(appDatabaseProvider).upsertChat(updated);
    ref.read(agentDockServiceProvider).pushChatNow(chat.id);
    ref.invalidate(agentsTreeProvider);
  }

  Future<void> _openChat(Chat chat) async {
    await _markRead(chat);
    if (!mounted) return;
    if (widget.embedded || useDesktopShell(context)) {
      context.go('/agents/chat/${chat.id}');
    } else {
      await context.push('/agents/chat/${chat.id}');
    }
    if (!mounted) return;
    // The transcript almost certainly moved on while we were inside it.
    await _markRead(chat);
    // Do not invalidate agentsTreeProvider here — that reloads the sidebar
    // and flickers every time you open a chat on desktop.
  }

  void _startWizard() {
    unawaited(startNewAgentWizard(context: context, ref: ref));
  }

  @override
  Widget build(BuildContext context) {
    final treeAsync = ref.watch(agentsTreeProvider);
    // Only rebuild when the sync *message* changes, not while loading.
    final syncNote = ref.watch(
      agentsSyncProvider.select((async) => async.hasValue
          ? async.valueOrNull
          : (async.isLoading ? 'Syncing agents from remotes…' : null)),
    );
    final runtimes = ref.watch(activeAcpSessionsProvider);
    final phoneList = !widget.embedded;

    final list = treeAsync.when(
        skipLoadingOnReload: true,
        skipLoadingOnRefresh: true,
        data: (tree) {
          if (phoneList) {
            return _buildPhoneList(tree, runtimes, syncNote);
          }
          return _buildDesktopTree(tree, runtimes, syncNote);
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
      );

    if (widget.embedded) {
      return ClipRect(child: list);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agents'),
        actions: [
          IconButton(
            tooltip: 'New agent',
            onPressed: _startWizard,
            icon: const Icon(Icons.add),
          ),
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
      body: list,
    );
  }

  Widget _buildPhoneList(
    AgentsTree tree,
    Map<String, ChatSessionRuntime> runtimes,
    String? syncNote,
  ) {
    final flat = _flatChats(tree);
    if (flat.isEmpty) {
      return _EmptyState(
        hasHosts: tree.hosts.isNotEmpty,
        embedded: false,
        onNewAgent: _startWizard,
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        setState(_dismissedChats.clear);
        ref.invalidate(agentsSyncProvider);
        await ref.read(agentsSyncProvider.future);
        ref.invalidate(agentsTreeProvider);
        ref.invalidate(unreadCountsProvider);
        await ref.read(agentsTreeProvider.future);
      },
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        itemCount: flat.length + (syncNote == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (syncNote != null) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(
                  syncNote,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            }
            index -= 1;
          }
          final item = flat[index];
          final chat = item.chat;
          return Dismissible(
            key: ValueKey('dismiss-${chat.id}'),
            direction: DismissDirection.endToStart,
            background: const _DeleteBackground(),
            confirmDismiss: (_) => _confirmDeleteChat(item.host, chat),
            onDismissed: (_) {
              setState(() => _dismissedChats.add(chat.id));
              unawaited(_deleteChat(item.host, chat));
            },
            child: _PhoneChatCard(
              chat: chat,
              host: item.host,
              repo: item.repo,
              runtime: runtimes[chat.id],
              onTap: () => _openChat(chat),
              onRename: () => unawaited(_renameChat(chat)),
              onDelete: () async {
                if (await _confirmDeleteChat(item.host, chat)) {
                  unawaited(_deleteChat(item.host, chat));
                }
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildDesktopTree(
    AgentsTree tree,
    Map<String, ChatSessionRuntime> runtimes,
    String? syncNote,
  ) {
    final sections = _sections(tree);
    if (sections.isEmpty) {
      return _EmptyState(
        hasHosts: tree.hosts.isNotEmpty,
        embedded: true,
        onNewAgent: _startWizard,
      );
    }

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
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        buildDefaultDragHandles: false,
        header: syncNote == null
            ? null
            : Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text(
                  syncNote,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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
            collapsed: _collapsedRepos.contains(section.repo.id),
            selectedChatId: widget.selectedChatId,
            compact: true,
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
            onRenameChat: (chat) => unawaited(_renameChat(chat)),
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
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState({
    required this.hasHosts,
    this.embedded = false,
    this.onNewAgent,
  });

  final bool hasHosts;
  final bool embedded;
  final VoidCallback? onNewAgent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              hasHosts
                  ? 'No agents yet. Tap + to pick a host and folder, '
                      'then start a chat.'
                  : 'Add a host first, then tap + to create an agent '
                      'in a remote folder.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (onNewAgent != null && hasHosts)
              FilledButton.icon(
                onPressed: onNewAgent,
                icon: const Icon(Icons.add),
                label: const Text('New agent'),
              )
            else
              FilledButton(
                onPressed: () => openAppPanel(
                  context,
                  ref,
                  DesktopRightPanel.hosts,
                ),
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
    required this.collapsed,
    required this.onToggle,
    required this.onNewAgent,
    required this.onOpenChat,
    required this.onRenameChat,
    required this.onConfirmDeleteChat,
    required this.onDeleteChat,
    required this.onDismissChat,
    required this.onReorderChats,
    this.selectedChatId,
    this.compact = false,
  });

  final int index;
  final _Section section;
  final Map<String, ChatSessionRuntime> runtimes;
  final bool collapsed;
  final String? selectedChatId;
  final bool compact;
  final VoidCallback onToggle;
  final VoidCallback onNewAgent;
  final void Function(Chat chat) onOpenChat;
  final void Function(Chat chat) onRenameChat;
  final Future<bool> Function(Chat chat) onConfirmDeleteChat;
  final void Function(Chat chat) onDeleteChat;
  final void Function(Chat chat) onDismissChat;
  final void Function(int oldIndex, int newIndex) onReorderChats;

  @override
  Widget build(BuildContext context) {
    final chats = section.chats;
    final busy = chats.any((c) => runtimes[c.id]?.isWorking ?? false);

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
            chatIds: [for (final c in chats) c.id],
            compact: compact,
            onToggle: onToggle,
            onNewAgent: onNewAgent,
          ),
        ),
        if (!collapsed)
          if (chats.isEmpty)
            _EmptyRepoRow(onNewAgent: onNewAgent, compact: compact)
          else
            Padding(
              // Indent agents under their folder on desktop sidebar.
              padding: EdgeInsets.only(left: compact ? 14 : 0),
              child: ReorderableListView.builder(
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
                        selected: chat.id == selectedChatId,
                        compact: compact,
                        onTap: () => onOpenChat(chat),
                        onRename: () => onRenameChat(chat),
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
    required this.chatIds,
    required this.onToggle,
    required this.onNewAgent,
    this.compact = false,
  });

  final Repo repo;
  final Host host;
  final bool collapsed;
  final bool busy;
  final List<String> chatIds;
  final bool compact;
  final VoidCallback onToggle;
  final VoidCallback onNewAgent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: EdgeInsets.fromLTRB(compact ? 10 : 12, 12, 2, 4),
        child: Row(
          children: [
            Expanded(
              child: compact
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              collapsed
                                  ? Icons.folder_outlined
                                  : Icons.folder_open_outlined,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                repo.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (busy) ...[
                              const SizedBox(width: 6),
                              WorkingDots(key: ValueKey('busy-${repo.id}'), size: 4),
                            ],
                            if (collapsed)
                              _FolderUnreadBadge(chatIds: chatIds),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 26, top: 2),
                          child: _HostTag(host: host, expand: true),
                        ),
                      ],
                    )
                  : Row(
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
                          WorkingDots(key: ValueKey('busy-${repo.id}'), size: 4),
                        ],
                        if (collapsed) _FolderUnreadBadge(chatIds: chatIds),
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

/// Watches unread counts without rebuilding the whole agents list.
class _FolderUnreadBadge extends ConsumerWidget {
  const _FolderUnreadBadge({required this.chatIds});

  final List<String> chatIds;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(
      unreadCountsProvider.select((async) {
        final map = async.valueOrNull;
        if (map == null) return 0;
        var sum = 0;
        for (final id in chatIds) {
          sum += map[id] ?? 0;
        }
        return sum;
      }),
    );
    if (n <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: UnreadBadge(count: n),
    );
  }
}

class _ChatUnreadBadge extends ConsumerWidget {
  const _ChatUnreadBadge({required this.chatId});

  final String chatId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(
      unreadCountsProvider.select((async) => async.valueOrNull?[chatId] ?? 0),
    );
    if (n <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: UnreadBadge(count: n),
    );
  }
}

/// Which machine a folder lives on, shown inline so the host tree does not
/// need its own level of nesting.
class _HostTag extends StatelessWidget {
  const _HostTag({required this.host, this.expand = false});

  final Host host;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = Text(
      host.alias,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.2,
      ),
    );
    return Tooltip(
      message: '${host.username}@${host.hostname}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Icon(
              Icons.dns_outlined,
              size: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            if (expand) Expanded(child: label) else Flexible(child: label),
          ],
        ),
      ),
    );
  }
}

class _EmptyRepoRow extends StatelessWidget {
  const _EmptyRepoRow({required this.onNewAgent, this.compact = false});

  final VoidCallback onNewAgent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onNewAgent,
      child: Padding(
        padding: EdgeInsets.fromLTRB(compact ? 40 : 42, 8, 12, 12),
        child: Text(
          'No agents yet — tap to start one',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
      ),
    );
  }
}

/// Phone Agents list: chat-style card with host + folder tags.
class _PhoneChatCard extends StatelessWidget {
  const _PhoneChatCard({
    required this.chat,
    required this.host,
    required this.repo,
    required this.runtime,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Chat chat;
  final Host host;
  final Repo repo;
  final ChatSessionRuntime? runtime;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: runtime ?? Listenable.merge(const []),
      builder: (context, _) => _build(context),
    );
  }

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
          value: 'rename',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('Rename'),
          ),
        ),
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
    if (choice == 'rename') onRename();
    if (choice == 'delete') onDelete();
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final working = runtime?.isWorking ?? false;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition),
          onLongPress: () => _showMenu(
            context,
            (context.findRenderObject() as RenderBox)
                .localToGlobal(Offset.zero),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    working
                        ? WorkingDots(
                            key: ValueKey('phone-dots-${chat.id}'),
                            color: AppColors.accent,
                          )
                        : Icon(
                            chat.provider == AgentProvider.cursor
                                ? Icons.auto_awesome
                                : Icons.psychology_alt_outlined,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      shortTimeAgo(chat.updatedAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                    _ChatUnreadBadge(chatId: chat.id),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _HostTag(host: host),
                    _FolderTag(name: repo.name),
                    if (chat.lastAutoNumber != null)
                      AutoNumberBadge(number: chat.lastAutoNumber!),
                  ],
                ),
                if (working) ...[
                  const SizedBox(height: 6),
                  Builder(
                    builder: (context) {
                      final explore = runtime?.turnExploreStats;
                      if (explore != null && explore.isNotEmpty) {
                        return ExploreStatsLabel(
                          files: explore.fileCount,
                          searches: explore.searchCount,
                          showEllipsis: true,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.accent.withValues(alpha: 0.9),
                            fontWeight: FontWeight.w500,
                          ),
                        );
                      }
                      return Text(
                        'Working…',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.accent.withValues(alpha: 0.9),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderTag extends StatelessWidget {
  const _FolderTag({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.folder_outlined,
            size: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              name,
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
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({
    required this.chat,
    required this.runtime,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
    this.selected = false,
    this.compact = false,
  });

  final Chat chat;
  final ChatSessionRuntime? runtime;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final bool selected;
  final bool compact;

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
          value: 'rename',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('Rename'),
          ),
        ),
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
    if (choice == 'rename') onRename();
    if (choice == 'delete') onDelete();
  }

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final working = runtime?.isWorking ?? false;

    return InkWell(
      onTap: onTap,
      onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition),
      borderRadius: BorderRadius.circular(compact ? 8 : 10),
      child: Container(
        margin: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 8,
          vertical: 1,
        ),
        decoration: BoxDecoration(
          color: selected ? AppColors.agentSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(compact ? 8 : 10),
          border: selected
              ? Border.all(
                  color: AppColors.agentSelectedBorder.withValues(alpha: 0.55),
                )
              : null,
        ),
        padding: EdgeInsets.fromLTRB(compact ? 8 : 10, 8, compact ? 8 : 10, 8),
        child: Row(
          children: [
            SizedBox(
              width: compact ? 22 : 28,
              child: Center(
                child: working
                    ? WorkingDots(
                        key: ValueKey('dots-${chat.id}'),
                        color: AppColors.accent,
                      )
                    : Icon(
                        chat.provider == AgentProvider.cursor
                            ? Icons.auto_awesome
                            : Icons.psychology_alt_outlined,
                        size: 16,
                        color: selected
                            ? AppColors.accent
                            : theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.7),
                      ),
              ),
            ),
            SizedBox(width: compact ? 6 : 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          chat.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w500,
                            color: selected
                                ? AppColors.mist
                                : theme.colorScheme.onSurface
                                    .withValues(alpha: 0.88),
                          ),
                        ),
                      ),
                      if (chat.lastAutoNumber != null) ...[
                        const SizedBox(width: 4),
                        AutoNumberBadge(number: chat.lastAutoNumber!),
                      ],
                      const SizedBox(width: 6),
                      Text(
                        shortTimeAgo(chat.updatedAt),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline
                              .withValues(alpha: 0.85),
                        ),
                      ),
                      _ChatUnreadBadge(chatId: chat.id),
                    ],
                  ),
                  if (working) ...[
                    Builder(
                      builder: (context) {
                        final explore = runtime?.turnExploreStats;
                        if (explore != null && explore.isNotEmpty) {
                          return ExploreStatsLabel(
                            files: explore.fileCount,
                            searches: explore.searchCount,
                            showEllipsis: true,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: AppColors.accent.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w500,
                            ),
                          );
                        }
                        return Text(
                          'Working…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.accent.withValues(alpha: 0.9),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
            ),
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
