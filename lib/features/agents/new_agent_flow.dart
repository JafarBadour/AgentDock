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
import '../../services/agent_runtime_host.dart';
import 'agents_screen.dart';

class _NewAgentRequest {
  const _NewAgentRequest({required this.title, required this.provider});

  final String title;
  final AgentProvider provider;
}

/// Owns its own [TextEditingController].
///
/// The controller cannot live in the calling function: `showDialog` returns as
/// soon as the route is popped, but the dialog keeps rebuilding through its
/// dismissal animation, so disposing there is a use-after-dispose.
class _NewAgentDialog extends StatefulWidget {
  const _NewAgentDialog({required this.repoName});

  final String repoName;

  @override
  State<_NewAgentDialog> createState() => _NewAgentDialogState();
}

class _NewAgentDialogState extends State<_NewAgentDialog> {
  final _title = TextEditingController(text: 'New agent');
  AgentProvider _provider = AgentProvider.cursor;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _title.text.trim();
    Navigator.pop(
      context,
      _NewAgentRequest(
        title: text.isEmpty ? 'New agent' : text,
        provider: _provider,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('New agent · ${widget.repoName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Title'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          Text(
            'Provider',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          // Segmented control — not a Dropdown — so the menu never paints
          // through the dialog / wavy background as a broken overlay.
          SegmentedButton<AgentProvider>(
            segments: [
              for (final p in AgentProvider.values)
                ButtonSegment(
                  value: p,
                  label: Text(p.label),
                  icon: Icon(
                    p == AgentProvider.cursor
                        ? Icons.terminal
                        : Icons.smart_toy_outlined,
                    size: 16,
                  ),
                ),
            ],
            selected: {_provider},
            onSelectionChanged: (next) {
              if (next.isEmpty) return;
              setState(() => _provider = next.first);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// Dialog + create chat + navigate to `/agents/chat/:id`.
Future<void> startNewAgentChat({
  required BuildContext context,
  required WidgetRef ref,
  required Host host,
  required Repo repo,
}) async {
  final request = await showDialog<_NewAgentRequest>(
    context: context,
    builder: (context) => _NewAgentDialog(repoName: repo.name),
  );

  if (request == null || !context.mounted) return;
  final title = request.title;
  final provider = request.provider;

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

    final chatId = const Uuid().v4();
    // The tmux session is created lazily by AgentRuntimeHost on first connect;
    // record the name now so the agent list can show where it will live.
    final session = AgentRuntimeHost.sessionNameForChat(chatId);
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
