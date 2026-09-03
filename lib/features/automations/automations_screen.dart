import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/models/scheduled_job.dart';
import '../agents/agent_status_indicators.dart';
import '../agents/agents_screen.dart';

final scheduledJobsProvider =
    FutureProvider.autoDispose<List<ScheduledJob>>((ref) async {
  ref.watch(scheduledJobsTickProvider);
  return ref.watch(appDatabaseProvider).listScheduledJobs();
});

class AutomationsScreen extends ConsumerStatefulWidget {
  const AutomationsScreen({super.key});

  @override
  ConsumerState<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends ConsumerState<AutomationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(scheduleRunnerProvider).tick());
    });
  }

  Future<void> _confirmDelete(ScheduledJob job) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${job.numberLabel}?'),
        content: Text(
          job.title.isEmpty
              ? 'Remove this automated agent. Past chat messages stay.'
              : 'Remove “${job.title}”. Past chat messages stay.',
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
    await ref.read(scheduleRunnerProvider).deleteJob(job.id);
  }

  @override
  Widget build(BuildContext context) {
    final jobsAsync = ref.watch(scheduledJobsProvider);
    final treeAsync = ref.watch(agentsTreeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Automated agents')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/automate/new'),
        icon: const Icon(Icons.add),
        label: const Text('Schedule'),
      ),
      body: jobsAsync.when(
        data: (jobs) {
          if (jobs.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Schedule a prompt to run once or on a repeat — '
                  'executed on the host even if this phone is offline.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final chatTitles = <String, String>{};
          treeAsync.whenData((tree) {
            for (final list in tree.chatsByRepo.values) {
              for (final c in list) {
                chatTitles[c.id] = c.title;
              }
            }
          });

          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: jobs.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final job = jobs[index];
              final agent = chatTitles[job.chatId] ?? 'Unknown agent';
              return Dismissible(
                key: ValueKey(job.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: Theme.of(context).colorScheme.errorContainer,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 20),
                  child: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
                confirmDismiss: (_) async {
                  await _confirmDelete(job);
                  return false;
                },
                child: ListTile(
                  title: Row(
                    children: [
                      AutoNumberBadge(number: job.number),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          job.title.isEmpty ? 'Untitled' : job.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text(
                    '$agent\n${job.scheduleSummary}'
                    '${job.lastError != null ? '\nLast error: ${job.lastError}' : ''}',
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _confirmDelete(job),
                      ),
                      Switch(
                        value: job.enabled,
                        onChanged: (on) async {
                          final now = DateTime.now();
                          var next = job.nextRunAt;
                          if (on && !next.isAfter(now)) {
                            next = ScheduledJob.initialNextRun(
                              kind: job.kind,
                              now: now,
                              intervalMinutes: job.intervalMinutes,
                              hour: job.hour,
                              minute: job.minute,
                              weekdays: job.weekdays,
                            );
                          }
                          await ref.read(scheduleRunnerProvider).saveJob(
                                job.copyWith(
                                  enabled: on,
                                  nextRunAt: next,
                                  clearError: true,
                                  updatedAt: now,
                                ),
                              );
                        },
                      ),
                    ],
                  ),
                  onTap: () => context.push('/automate/edit/${job.id}'),
                ),
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
