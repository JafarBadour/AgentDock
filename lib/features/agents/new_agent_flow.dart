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
import '../../services/ssh_service.dart';
import '../repos/remote_browser_screen.dart';
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

/// Top-level + flow: pick host → browse/create folder → name agent.
Future<void> startNewAgentWizard({
  required BuildContext context,
  required WidgetRef ref,
}) async {
  final db = ref.read(appDatabaseProvider);
  final hosts = await db.listHosts();
  if (!context.mounted) return;
  if (hosts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Add a host first under Hosts.')),
    );
    return;
  }

  Host? host;
  if (hosts.length == 1) {
    host = hosts.first;
  } else {
    host = await showDialog<Host>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Choose host'),
        children: [
          for (final h in hosts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, h),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined),
                title: Text(h.displayLabel),
                subtitle: Text(h.endpointLabel),
              ),
            ),
        ],
      ),
    );
  }
  if (host == null || !context.mounted) return;

  final path = await RemoteBrowserScreen.open(context, host: host);
  if (path == null || !context.mounted) return;

  final folderName = path == '/'
      ? 'root'
      : path.split('/').where((s) => s.isNotEmpty).last;

  try {
    final exists =
        await ref.read(sshServiceProvider).remotePathExists(host, path);
    if (!exists) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Folder does not exist: $path')),
        );
      }
      return;
    }
  } catch (e) {
    SafeLog.d('new agent path check failed', e);
  }

  final repo = await db.findOrCreateRepoByPath(
    hostId: host.id,
    remotePath: SshService.normalizeRemotePath(path),
    name: folderName,
  );
  ref.invalidate(agentsTreeProvider);
  if (!context.mounted) return;

  await startNewAgentChat(
    context: context,
    ref: ref,
    host: host,
    repo: repo,
  );
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
      titleUpdatedAt: now,
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
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
}
