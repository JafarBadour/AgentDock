import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../services/adsm_client.dart';
import 'archon_screen.dart';

/// One thing Archon did.
class ArchonAction {
  const ArchonAction({
    required this.id,
    required this.at,
    required this.command,
    this.target,
    this.summary,
    this.ok = true,
  });

  final int id;
  final DateTime at;
  final String command;
  final String? target;
  final String? summary;
  final bool ok;

  static ArchonAction? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at']}');
    final command = raw['command'];
    if (at == null || command is! String) return null;
    return ArchonAction(
      id: (raw['id'] as num?)?.toInt() ?? 0,
      at: at.toLocal(),
      command: command,
      target: raw['target'] as String?,
      summary: raw['summary'] as String?,
      ok: raw['ok'] != false,
    );
  }
}

/// What Archon has been doing, read from its host.
///
/// Pulled from the daemon rather than asked of Archon: the point of the log is
/// that it can be checked without asking the thing being checked.
final archonActivityProvider = FutureProvider.autoDispose<List<ArchonAction>>((
  ref,
) async {
  final host = await ref.watch(archonHostProvider.future);
  if (host == null) return const [];
  final pool = ref.watch(adsmBridgePoolProvider);
  final client = await pool.acquire(host);
  try {
    final result = await client.request('archon.log', {
      'limit': 200,
    }, timeout: const Duration(seconds: 30));
    final raw = result['actions'];
    if (raw is! List) return const [];
    return [
      for (final row in raw)
        if (ArchonAction.tryParse(row) case final action?) action,
    ];
  } finally {
    await pool.releaseClient(host.id, client);
  }
});

/// Everything Archon has done, newest first.
class ArchonActivityPanel extends ConsumerWidget {
  const ArchonActivityPanel({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const FractionallySizedBox(
      heightFactor: 0.9,
      child: ArchonActivityPanel(),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final actions = ref.watch(archonActivityProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('What Archon did', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      'Every command it ran, newest first. Reading and '
                      'listing are left out; this is what it changed.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: const Icon(Icons.refresh),
                onPressed: () => ref.invalidate(archonActivityProvider),
              ),
            ],
          ),
        ),
        Expanded(
          child: actions.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _Message(text: 'Could not read the log — $e'),
            data: (list) => list.isEmpty
                ? const _Message(text: 'Archon has not done anything yet.')
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => _ActionRow(action: list[i]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.action});

  final ArchonAction action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final time =
        '${action.at.hour.toString().padLeft(2, '0')}:'
        '${action.at.minute.toString().padLeft(2, '0')}';

    return ListTile(
      dense: true,
      leading: Icon(
        // A refusal is as worth seeing as an action — more, usually.
        action.ok ? Icons.check_circle_outline : Icons.block,
        size: 18,
        color: action.ok
            ? theme.colorScheme.primary
            : theme.colorScheme.error,
      ),
      title: Row(
        children: [
          Text(
            action.command,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (action.target != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                action.target!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: action.summary == null
          ? null
          : Text(
              action.summary!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
      trailing: Text(
        time,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}
