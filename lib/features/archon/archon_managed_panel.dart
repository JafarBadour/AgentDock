import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/archon_brief.dart';
import '../../data/models/chat.dart';
import '../../data/models/host.dart';
import '../../data/models/repo.dart';
import '../../data/secure/safe_log.dart';
import '../agents/agents_screen.dart';

/// One row of the panel: an agent, and Archon's brief about it.
class ManagedAgent {
  const ManagedAgent({
    required this.chat,
    required this.repo,
    required this.host,
    this.brief,
  });

  final Chat chat;
  final Repo repo;
  final Host host;
  final ArchonBrief? brief;

  bool get enabled => brief?.enabled ?? false;
  String? get goal => brief?.goal;
  String? get note => brief?.note;
  bool get isDone => brief?.isDone ?? false;
}

final managedAgentsProvider = FutureProvider.autoDispose<List<ManagedAgent>>((
  ref,
) async {
  ref.watch(agentsCatalogEpochProvider);
  final db = ref.watch(appDatabaseProvider);
  final tree = await ref.watch(agentsTreeProvider.future);
  final briefs = await db.archonBriefs();

  final hostsById = {for (final h in tree.hosts) h.id: h};
  final out = <ManagedAgent>[];
  for (final repo in tree.repos) {
    final host = hostsById[repo.hostId];
    if (host == null) continue;
    for (final chat in tree.chatsByRepo[repo.id] ?? const <Chat>[]) {
      out.add(
        ManagedAgent(
          chat: chat,
          repo: repo,
          host: host,
          brief: briefs[chat.id],
        ),
      );
    }
  }
  // Whatever Archon is working on first, then finished, then the rest.
  out.sort((a, b) {
    int rank(ManagedAgent m) => m.enabled ? 0 : (m.isDone ? 1 : 2);
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    return b.chat.updatedAt.compareTo(a.chat.updatedAt);
  });
  return out;
});

/// Which agents Archon looks after, and what done means for each.
class ArchonManagedPanel extends ConsumerWidget {
  const ArchonManagedPanel({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const FractionallySizedBox(
      heightFactor: 0.9,
      child: ArchonManagedPanel(),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final agents = ref.watch(managedAgentsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Auto-managed agents', style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(
                'Switch on the agents Archon should look after. Without a '
                'goal it keeps their chats moving the way you would and only '
                'comes to you when it matters. Give one a goal and it works '
                'to that instead, then switches itself off with a note.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: agents.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Could not load agents — $e')),
            data: (list) => list.isEmpty
                ? const Center(child: Text('No agents yet'))
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _ManagedRow(agent: list[i]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _ManagedRow extends ConsumerWidget {
  const _ManagedRow({required this.agent});

  final ManagedAgent agent;

  Future<void> _write(WidgetRef ref, ArchonBrief brief) async {
    final db = ref.read(appDatabaseProvider);
    await db.saveArchonBrief(brief);
    // Carry it to the host so Archon, which runs there, can act on it.
    ref.read(agentDockServiceProvider).pushChatNow(brief.chatId);
    ref.invalidate(managedAgentsProvider);
  }

  /// Switch Archon's attention on or off. Nothing else — a goal is optional
  /// and set from the pencil, because most agents only need their chat kept
  /// moving and asking for a brief first made this into paperwork.
  Future<void> _toggle(BuildContext context, WidgetRef ref, bool on) async {
    final messenger = ScaffoldMessenger.of(context);
    final existing =
        agent.brief ??
        ArchonBrief(chatId: agent.chat.id, updatedAt: DateTime.now());
    try {
      await _write(
        ref,
        // Turning it back on clears the last result: a note beside a live
        // switch would read as the finished thing still running.
        on
            ? existing.copyWith(enabled: true, clearNote: true)
            : existing.copyWith(enabled: false),
      );
    } catch (e) {
      // This used to be swallowed, so a switch that did not move looked like
      // the switch being broken rather than the write failing.
      SafeLog.d('archon brief write failed', e);
      messenger.showSnackBar(
        SnackBar(content: Text('Could not update ${agent.chat.title} — $e')),
      );
    }
  }

  Future<String?> _askForGoal(BuildContext context) async {
    final controller = TextEditingController(text: agent.goal ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(agent.chat.title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            labelText: 'Goal',
            hintText: 'What should be true when Archon is done?',
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final goal = agent.goal;
    final note = agent.note;

    return ListTile(
      title: Text(agent.chat.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${agent.repo.name} · ${agent.host.alias}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (agent.enabled) ...[
            const SizedBox(height: 4),
            Text(
              goal ?? ArchonBrief.defaultGoal,
              style: theme.textTheme.bodySmall?.copyWith(
                // The default is Archon's standing behaviour, not something
                // the user wrote; it should not read as their words.
                fontStyle: goal == null ? FontStyle.italic : null,
                color: goal == null
                    ? theme.colorScheme.onSurfaceVariant
                    : null,
              ),
            ),
          ],
          if (agent.isDone && note != null) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.check_circle_outline,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(note, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ],
        ],
      ),
      isThreeLine: agent.enabled || agent.isDone,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
              tooltip: agent.goal == null ? 'Add a goal' : 'Edit goal',
              icon: Icon(
                agent.goal == null
                    ? Icons.add_comment_outlined
                    : Icons.edit_outlined,
                size: 18,
              ),
              onPressed: () async {
                final goal = await _askForGoal(context);
                if (goal == null) return;
                final base =
                    agent.brief ??
                    ArchonBrief(
                      chatId: agent.chat.id,
                      updatedAt: DateTime.now(),
                    );
                await _write(
                  ref,
                  // An emptied box means "no particular goal", not "keep the
                  // old one" — so it falls back to the default.
                  base.copyWith(goal: goal.trim(), clearNote: true),
                );
              },
            ),
          Switch(
            value: agent.enabled,
            onChanged: (on) => unawaited(_toggle(context, ref, on)),
          ),
        ],
      ),
    );
  }
}
