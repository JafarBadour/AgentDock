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

/// Flat chat row for the Agents list (phone + desktop sidebar).
class _FlatChat {
  const _FlatChat({
    required this.chat,
    required this.host,
    required this.repo,
  });

  final Chat chat;
  final Host host;
  final Repo repo;
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
  /// Rows a swipe has already dismissed. Deleting is asynchronous, but a
  /// Dismissible must leave the tree the moment its handler fires, so drop it
  /// from the rendered list right away rather than waiting for the reload.
  final Set<String> _dismissedChats = {};

  /// Collapsed directory ids in Directory view.
  final Set<String> _collapsedDirs = {};

  /// Expanded host ids in Hosts view (hosts start collapsed).
  final Set<String> _expandedHosts = {};

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
    out.sort((a, b) => b.chat.updatedAt.compareTo(a.chat.updatedAt));
    return out;
  }

  List<_DirSection> _directorySections(AgentsTree tree) {
    final hostsById = {for (final h in tree.hosts) h.id: h};
    final sections = <_DirSection>[];
    for (final repo in tree.repos) {
      final host = hostsById[repo.hostId];
      if (host == null) continue;
      final chats = [
        for (final c in tree.chatsByRepo[repo.id] ?? const <Chat>[])
          if (!_dismissedChats.contains(c.id)) c,
      ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      sections.add(_DirSection(repo: repo, host: host, chats: chats));
    }
    sections.sort((a, b) {
      final byName = a.repo.name.toLowerCase().compareTo(b.repo.name.toLowerCase());
      if (byName != 0) return byName;
      return a.host.alias.toLowerCase().compareTo(b.host.alias.toLowerCase());
    });
    return sections;
  }

  List<_HostSection> _hostSections(AgentsTree tree) {
    final byHost = <String, List<_FlatChat>>{};
    for (final item in _flatChats(tree)) {
      byHost.putIfAbsent(item.host.id, () => []).add(item);
    }
    final sections = <_HostSection>[];
    for (final host in tree.hosts) {
      final agents = [...(byHost[host.id] ?? const <_FlatChat>[])];
      // Under a host: group/sort by directory name, then recency within dir.
      agents.sort((a, b) {
        final byDir =
            a.repo.name.toLowerCase().compareTo(b.repo.name.toLowerCase());
        if (byDir != 0) return byDir;
        return b.chat.updatedAt.compareTo(a.chat.updatedAt);
      });
      sections.add(_HostSection(host: host, agents: agents));
    }
    sections.sort(
      (a, b) => a.host.alias.toLowerCase().compareTo(b.host.alias.toLowerCase()),
    );
    return sections;
  }

  void _toggleDir(String id) {
    setState(() {
      if (!_collapsedDirs.remove(id)) {
        _collapsedDirs.add(id);
      }
    });
  }

  void _toggleHost(String id) {
    setState(() {
      if (!_expandedHosts.remove(id)) {
        _expandedHosts.add(id);
      }
    });
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
    final mode = widget.embedded
        ? ref.watch(agentsSidebarModeProvider)
        : AgentsSidebarMode.agents;

    final list = treeAsync.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      data: (tree) => switch (mode) {
        AgentsSidebarMode.agents => _buildFlatList(tree, runtimes, syncNote),
        AgentsSidebarMode.directories =>
          _buildDirectoryList(tree, runtimes, syncNote),
        AgentsSidebarMode.hosts => _buildHostsList(tree, runtimes, syncNote),
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

  Future<void> _refreshLists() async {
    setState(_dismissedChats.clear);
    ref.invalidate(agentsSyncProvider);
    await ref.read(agentsSyncProvider.future);
    ref.invalidate(agentsTreeProvider);
    ref.invalidate(unreadCountsProvider);
    await ref.read(agentsTreeProvider.future);
  }

  Widget _nestedAgentTile({
    required Chat chat,
    required Host host,
    required Repo repo,
    required ChatSessionRuntime? runtime,
    Widget? tag,
  }) {
    return _NestedAgentRow(
      chat: chat,
      runtime: runtime,
      selected: chat.id == widget.selectedChatId,
      tag: tag,
      onTap: () => _openChat(chat),
      onRename: () => unawaited(_renameChat(chat)),
      onDelete: () async {
        if (await _confirmDeleteChat(host, chat)) {
          unawaited(_deleteChat(host, chat));
        }
      },
    );
  }

  Widget _buildDirectoryList(
    AgentsTree tree,
    Map<String, ChatSessionRuntime> runtimes,
    String? syncNote,
  ) {
    final sections = _directorySections(tree);
    if (sections.isEmpty) {
      return _EmptyState(
        hasHosts: tree.hosts.isNotEmpty,
        embedded: true,
        onNewAgent: _startWizard,
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshLists,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 32),
        itemCount: sections.length + (syncNote == null ? 0 : 1),
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
          final section = sections[index];
          final collapsed = _collapsedDirs.contains(section.repo.id);
          return _CollapsibleSection(
            key: ValueKey('dir-${section.repo.id}'),
            title: section.repo.name,
            titleIcon: Icons.folder_outlined,
            trailingTag: _HostTag(host: section.host),
            subtitle: section.chats.isEmpty
                ? 'No agents'
                : '${section.chats.length} agent${section.chats.length == 1 ? '' : 's'}',
            collapsed: collapsed,
            onToggle: () => _toggleDir(section.repo.id),
            children: [
              for (final chat in section.chats)
                _nestedAgentTile(
                  chat: chat,
                  host: section.host,
                  repo: section.repo,
                  runtime: runtimes[chat.id],
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHostsList(
    AgentsTree tree,
    Map<String, ChatSessionRuntime> runtimes,
    String? syncNote,
  ) {
    final sections = _hostSections(tree);
    if (sections.isEmpty) {
      return _EmptyState(
        hasHosts: false,
        embedded: true,
        onNewAgent: _startWizard,
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshLists,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 32),
        itemCount: sections.length + (syncNote == null ? 0 : 1),
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
          final section = sections[index];
          final collapsed = !_expandedHosts.contains(section.host.id);
          final n = section.agents.length;
          return _CollapsibleSection(
            key: ValueKey('host-${section.host.id}'),
            title: section.host.alias,
            titleIcon: Icons.dns_outlined,
            subtitle: n == 0
                ? 'No agents'
                : '$n agent${n == 1 ? '' : 's'}',
            collapsed: collapsed,
            onToggle: () => _toggleHost(section.host.id),
            children: [
              for (final item in section.agents)
                _nestedAgentTile(
                  chat: item.chat,
                  host: item.host,
                  repo: item.repo,
                  runtime: runtimes[item.chat.id],
                  tag: _FolderTag(name: item.repo.name),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFlatList(
    AgentsTree tree,
    Map<String, ChatSessionRuntime> runtimes,
    String? syncNote,
  ) {
    final flat = _flatChats(tree);
    if (flat.isEmpty) {
      return _EmptyState(
        hasHosts: tree.hosts.isNotEmpty,
        embedded: widget.embedded,
        onNewAgent: _startWizard,
      );
    }

    final list = ListView.builder(
      padding: EdgeInsets.fromLTRB(
        widget.embedded ? 10 : 12,
        8,
        widget.embedded ? 10 : 12,
        32,
      ),
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
        final card = _PhoneChatCard(
          chat: chat,
          host: item.host,
          repo: item.repo,
          runtime: runtimes[chat.id],
          selected: chat.id == widget.selectedChatId,
          compact: widget.embedded,
          onTap: () => _openChat(chat),
          onRename: () => unawaited(_renameChat(chat)),
          onDelete: () async {
            if (await _confirmDeleteChat(item.host, chat)) {
              unawaited(_deleteChat(item.host, chat));
            }
          },
        );
        if (widget.embedded) {
          // Desktop sidebar: right-click delete/rename; no swipe.
          return card;
        }
        return Dismissible(
          key: ValueKey('dismiss-${chat.id}'),
          direction: DismissDirection.endToStart,
          background: const _DeleteBackground(),
          confirmDismiss: (_) => _confirmDeleteChat(item.host, chat),
          onDismissed: (_) {
            setState(() => _dismissedChats.add(chat.id));
            unawaited(_deleteChat(item.host, chat));
          },
          child: card,
        );
      },
    );

    return RefreshIndicator(
      onRefresh: _refreshLists,
      child: list,
    );
  }

}

class _DirSection {
  const _DirSection({
    required this.repo,
    required this.host,
    required this.chats,
  });

  final Repo repo;
  final Host host;
  final List<Chat> chats;
}

class _HostSection {
  const _HostSection({required this.host, required this.agents});

  final Host host;
  final List<_FlatChat> agents;
}

class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    super.key,
    required this.title,
    required this.titleIcon,
    required this.subtitle,
    required this.collapsed,
    required this.onToggle,
    required this.children,
    this.trailingTag,
  });

  final String title;
  final IconData titleIcon;
  final String subtitle;
  final bool collapsed;
  final VoidCallback onToggle;
  final List<Widget> children;
  final Widget? trailingTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
                child: Row(
                  children: [
                    Icon(
                      collapsed
                          ? Icons.chevron_right_rounded
                          : Icons.expand_more_rounded,
                      size: 20,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Icon(titleIcon, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            subtitle,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (trailingTag != null) ...[
                      const SizedBox(width: 6),
                      trailingTag!,
                    ],
                  ],
                ),
              ),
            ),
            if (!collapsed && children.isNotEmpty) ...[
              Divider(
                height: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 6),
                child: Column(
                  children: children,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NestedAgentRow extends StatelessWidget {
  const _NestedAgentRow({
    required this.chat,
    required this.runtime,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    this.tag,
    this.selected = false,
  });

  final Chat chat;
  final ChatSessionRuntime? runtime;
  final Widget? tag;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final bool selected;

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
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: selected
            ? AppColors.agentSelected
            : scheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          onSecondaryTapDown: (d) => _showMenu(context, d.globalPosition),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Row(
              children: [
                working
                    ? WorkingDots(
                        key: ValueKey('nested-dots-${chat.id}'),
                        color: AppColors.accent,
                        size: 4,
                      )
                    : Icon(
                        chat.provider == AgentProvider.cursor
                            ? Icons.auto_awesome
                            : Icons.psychology_alt_outlined,
                        size: 15,
                        color: selected
                            ? AppColors.accent
                            : scheme.onSurfaceVariant,
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
                              selected ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                      if (tag != null) ...[
                        const SizedBox(height: 4),
                        tag!,
                      ],
                    ],
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
          ),
        ),
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

/// Which machine a chat lives on — shown as a tag next to the directory.
class _HostTag extends StatelessWidget {
  const _HostTag({required this.host});

  final Host host;

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
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.dns_outlined,
              size: 11,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Flexible(child: label),
          ],
        ),
      ),
    );
  }
}


class _PhoneChatCard extends StatelessWidget {
  const _PhoneChatCard({
    required this.chat,
    required this.host,
    required this.repo,
    required this.runtime,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    this.selected = false,
    this.compact = false,
  });

  final Chat chat;
  final Host host;
  final Repo repo;
  final ChatSessionRuntime? runtime;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final bool selected;
  final bool compact;

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
      padding: EdgeInsets.only(bottom: compact ? 6 : 8),
      child: Material(
        color: selected
            ? AppColors.agentSelected
            : scheme.surfaceContainerHigh.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(compact ? 12 : 14),
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
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 14,
              compact ? 10 : 12,
              compact ? 10 : 12,
              compact ? 10 : 12,
            ),
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
                            color: selected
                                ? AppColors.accent
                                : scheme.onSurfaceVariant,
                          ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        chat.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w600,
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
