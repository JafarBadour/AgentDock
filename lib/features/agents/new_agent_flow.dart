import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/models/agent_provider.dart';
import '../../data/models/chat.dart';
import '../../data/models/host.dart';
import '../../data/models/repo.dart';
import '../../data/secure/safe_log.dart';
import '../../services/tmux_service.dart';
import 'agents_screen.dart';

/// Dialog + create chat + navigate to `/agents/chat/:id`.
Future<void> startNewAgentChat({
  required BuildContext context,
  required WidgetRef ref,
  required Host host,
  required Repo repo,
}) async {
  AgentProvider provider = AgentProvider.cursor;
  final titleController = TextEditingController(text: 'New agent');

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setLocal) {
          return AlertDialog(
            title: Text('New agent · ${repo.name}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Title'),
                  onSubmitted: (_) {
                    if (provider.isAvailable) Navigator.pop(context, true);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<AgentProvider>(
                  initialValue: provider,
                  items: [
                    for (final p in AgentProvider.values)
                      DropdownMenuItem(
                        value: p,
                        enabled: p.isAvailable,
                        child: Text(
                          p.isAvailable ? p.label : '${p.label} (beta)',
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null || !value.isAvailable) return;
                    setLocal(() => provider = value);
                  },
                  decoration: const InputDecoration(labelText: 'Provider'),
                ),
                if (!provider.isAvailable)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Claude support is beta and not available yet.'),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: provider.isAvailable ? () => Navigator.pop(context, true) : null,
                child: const Text('Create'),
              ),
            ],
          );
        },
      );
    },
  );

  final title = titleController.text.trim().isEmpty
      ? 'New agent'
      : titleController.text.trim();
  titleController.dispose();

  if (confirmed != true || !context.mounted) return;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Expanded(child: Text('Creating chat…')),
        ],
      ),
    ),
  );

  try {
    final db = ref.read(appDatabaseProvider);
    final tmux = ref.read(tmuxServiceProvider);

    final chatId = const Uuid().v4();
    final session = TmuxService.sessionNameForChat(chatId);
    final now = DateTime.now();
    final chat = Chat(
      id: chatId,
      repoId: repo.id,
      title: title,
      provider: provider,
      tmuxSession: session,
      status: ChatStatus.idle,
      sortOrder: await db.nextChatSortOrder(repo.id),
      createdAt: now,
      updatedAt: now,
    );

    await db.upsertChat(chat);

    unawaited(() async {
      try {
        await ref.read(agentDockServiceProvider).pushAgent(
              host: host,
              chat: chat,
              repo: repo,
            );
      } catch (e) {
        SafeLog.d('agentdock push on create failed', e);
      }
    }());

    try {
      await tmux.createSession(
        host: host,
        session: session,
        cwd: repo.remotePath,
        command: 'bash',
      );
    } catch (e) {
      SafeLog.d('tmux create skipped/failed', e);
    }

    ref.invalidate(agentsTreeProvider);
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      context.go('/agents/chat/$chatId');
    }
  } catch (e) {
    SafeLog.d('new chat failed', e);
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Could not create chat'),
          content: Text('$e'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
          ],
        ),
      );
    }
  }
}
