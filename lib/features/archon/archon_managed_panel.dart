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
                'Switch on the agents Archon should look after and say what '
                'done looks like. Archon switches each one off again when it '
                'gets there, and leaves a note.',
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

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool on) async {
    final existing = agent.brief;
    // Turning it on without a goal leaves nothing to call finished, so ask
    // for one at the moment it is needed rather than accepting a blank brief.
    if (on && !(existing?.hasGoal ?? false)) {
      final goal = await _askForGoal(context);
      if (goal == null || goal.trim().isEmpty) return;
      await _write(
        ref,
        (existing ??
                ArchonBrief(
                  chatId: agent.chat.id,
                  updatedAt: DateTime.now(),
                ))
            .copyWith(enabled: true, goal: goal.trim(), clearNote: true),
      );
      return;
    }
    await _write(
      ref,
      (existing ??
              ArchonBrief(chatId: agent.chat.id, updatedAt: DateTime.now()))
          .copyWith(enabled: on),
    );
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
          if (agent.enabled && goal != null) ...[
            const SizedBox(height: 4),
            Text(goal, style: theme.textTheme.bodySmall),
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
          if (agent.enabled)
            IconButton(
              tooltip: 'Edit goal',
              icon: const Icon(Icons.edit_outlined, size: 18),
              onPressed: () async {
                final goal = await _askForGoal(context);
                if (goal == null || goal.trim().isEmpty) return;
                await _write(
                  ref,
                  agent.brief!.copyWith(goal: goal.trim(), clearNote: true),
                );
              },
            ),
          Switch(
            value: agent.enabled,
            onChanged: (on) => unawaited(
              _toggle(context, ref, on).catchError((Object e) {
                SafeLog.d('archon brief write failed', e);
              }),
            ),
          ),
        ],
      ),
    );
  }
}
