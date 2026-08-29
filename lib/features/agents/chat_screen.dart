import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/models/agent_mode.dart';
import '../../data/models/agent_provider.dart';
import '../../data/models/chat.dart';
import '../../data/models/chat_message.dart';
import '../../data/models/host.dart';
import '../../data/models/repo.dart';
import '../../data/models/tool_call_state.dart';
import '../../data/secure/safe_log.dart';
import '../../services/chat_session_runtime.dart';
import '../../services/cursor_acp_service.dart';
import '../../services/ssh_service.dart';
import 'agent_setup_guide.dart';
import 'project_files_screen.dart';
import 'tool_call_card.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.chatId});

  final String chatId;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  /// Offline / pre-connect transcript from DB.
  final List<TranscriptEntry> _dbEntries = [];

  Chat? _chat;
  Repo? _repo;
  Host? _host;
  bool _loading = true;
  bool _connecting = false;
  bool _sending = false;
  String? _connectStatus;
  String? _error;
  bool _showSdkInstallGuide = false;

  AgentSessionMode _mode = AgentSessionMode.agent;
  PermissionPolicy _permission = PermissionPolicy.ask;

  ChatSessionRuntime? _runtime;
  VoidCallback? _runtimeListener;
  Future<void>? _ensureAcpInFlight;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final db = ref.read(appDatabaseProvider);
    final chat = await db.getChat(widget.chatId);
    if (chat == null) {
      setState(() {
        _loading = false;
        _error = 'Chat not found';
      });
      return;
    }
    final repo = await db.getRepo(chat.repoId);
    final host = repo == null ? null : await db.getHost(repo.hostId);

    if (host != null) {
      try {
        final hasKey = await ref.read(secureStoreProvider).hasSshPrivateKey();
        if (hasKey) {
          final pulled = await ref.read(agentDockServiceProvider).syncChatMessages(
                host: host,
                chatId: chat.id,
              );
          if (pulled) {
            SafeLog.d('agentdock pulled messages for ${chat.id}');
          }
        }
      } catch (e) {
        SafeLog.d('agentdock message sync failed', e);
      }
    }

    final messages = await db.listMessages(chat.id);

    _dbEntries
      ..clear()
      ..addAll(_entriesFromMessages(messages));

    setState(() {
      _chat = chat;
      _repo = repo;
      _host = host;
      _loading = false;
    });

    final existing = ref.read(activeAcpSessionsProvider.notifier).get(chat.id);
    if (existing != null && !existing.closed) {
      _bindRuntime(existing);
    }
    // Don't auto-connect on open — reconnect when you send or tap Connect.
    // Auto-connect was blocking messaging when SSH hung.

    if (chat.provider == AgentProvider.claude) {
      setState(() {
        _showSdkInstallGuide = true;
        _error =
            'Claude is beta in Agentic Phone. Install Claude Code on the remote if you want to try it later; Cursor is the supported provider for now.';
      });
    }
  }

  List<TranscriptEntry> _entriesFromMessages(List<ChatMessage> messages) {
    final out = <TranscriptEntry>[];
    for (final m in messages) {
      if (m.role == MessageRole.tool) {
        final tool = ToolCallState.tryParseContent(m.content);
        if (tool != null) {
          out.add(TranscriptEntry.tool(tool, messageId: m.id));
          continue;
        }
      }
      out.add(TranscriptEntry.message(m));
    }
    return out;
  }

  void _bindRuntime(ChatSessionRuntime runtime) {
    if (_runtimeListener != null && _runtime != null) {
      _runtime!.removeListener(_runtimeListener!);
    }
    _runtime = runtime;
    runtime.chatMeta = _chat;
    _mode = runtime.mode;
    _permission = runtime.permissionPolicy;
    _runtimeListener = () {
      if (!mounted) return;
      if (runtime.chatMeta != null) {
        _chat = runtime.chatMeta;
      }
      _mode = runtime.mode;
      if (runtime.lastError != null && runtime.closed) {
        _error = runtime.lastError;
      }
      setState(() {});
      _scrollToEnd();
    };
    runtime.addListener(_runtimeListener!);
    setState(() {});
    _scrollToEnd();
  }

  Future<void> _ensureAcp() {
    _ensureAcpInFlight ??= _ensureAcpBody().whenComplete(() {
      _ensureAcpInFlight = null;
    });
    return _ensureAcpInFlight!;
  }

  Future<void> _ensureAcpBody() async {
    final chat = _chat;
    final repo = _repo;
    final host = _host;
    if (chat == null || repo == null || host == null) return;
    if (chat.provider != AgentProvider.cursor) {
      setState(() {
        _showSdkInstallGuide = true;
        _error =
            'Claude is beta. Switch to a Cursor chat, or install Claude Code on the remote for later.';
      });
      return;
    }

    final hasKey = await ref.read(secureStoreProvider).hasSshPrivateKey();
    if (!hasKey) {
      if (mounted) {
        setState(() {
          _error = 'No SSH private key. Add one in the Connect tab first.';
          _showSdkInstallGuide = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Add an SSH key in Connect first.')),
        );
      }
      return;
    }

    final existing = ref.read(activeAcpSessionsProvider.notifier).get(chat.id);
    if (existing != null && !existing.closed) {
      existing.setPermissionPolicy(_permission);
      _bindRuntime(existing);
      if (existing.mode != _mode) {
        try {
          await existing.setMode(_mode);
        } catch (e) {
          SafeLog.d('setMode on existing session failed', e);
        }
      }
      return;
    }

    setState(() {
      _connecting = true;
      _connectStatus = 'Resolving Cursor CLI…';
      _error = null;
      _showSdkInstallGuide = false;
    });

    try {
      final ssh = ref.read(sshServiceProvider);
      final tmux = ref.read(tmuxServiceProvider);
      String binary;
      try {
        binary = await tmux
            .resolveCursorBinary(host)
            .timeout(const Duration(seconds: 20));
      } on MissingToolException {
        rethrow;
      } on TimeoutException {
        throw TimeoutException(
          'Timed out looking for Cursor CLI. Check Terminal SSH, then try again.',
        );
      }
      if (mounted) setState(() => _connectStatus = 'Starting agent ($binary)…');
      try {
        await ssh.ensureTmux(host);
      } catch (e) {
        SafeLog.d('tmux missing; continuing with ACP over SSH', e);
      }

      final mcps = await ref.read(appDatabaseProvider).listEnabledMcpsForHost(host.id);
      final mcpConfigs = mcps.map((m) => m.toAcpConfig()).toList();

      if (mounted) setState(() => _connectStatus = 'ACP handshake…');
      final session = await AcpSession.start(
        ssh: ssh,
        secureStore: ref.read(secureStoreProvider),
        host: host,
        cwd: repo.remotePath,
        binary: binary,
        mcpServers: mcpConfigs,
        initialMode: _mode,
        permissionPolicy: _permission,
      ).timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException(
          'Connect timed out. Try `agent login` on the remote in the Terminal tab, then Connect again.',
        ),
      );

      final runtime = await ref.read(activeAcpSessionsProvider.notifier).attach(
            chatId: chat.id,
            session: session,
          );
      runtime.chatMeta = chat;
      _bindRuntime(runtime);

      final updated = chat.copyWith(
        status: ChatStatus.running,
        acpSessionId: session.sessionId,
        updatedAt: DateTime.now(),
      );
      runtime.chatMeta = updated;
      await ref.read(appDatabaseProvider).upsertChat(updated);
      ref.read(agentDockServiceProvider).schedulePushChat(updated.id);
      if (mounted) {
        setState(() {
          _chat = updated;
          _showSdkInstallGuide = false;
          _error = null;
        });
      }
    } on MissingToolException catch (e) {
      if (mounted) {
        setState(() {
          _showSdkInstallGuide = true;
          _error =
              'Cursor CLI / SDK not found on ${host.displayLabel}.\n'
              'Install it on the remote, then try Connect again.\n\n'
              '${e.tool} missing.';
        });
      }
    } catch (e) {
      SafeLog.d('ACP connect failed', e);
      final lower = e.toString().toLowerCase();
      final looksLikeMissingSdk = lower.contains('cursor') ||
          lower.contains('agent') ||
          lower.contains('not found') ||
          lower.contains('no such file');
      if (mounted) {
        setState(() {
          _showSdkInstallGuide = looksLikeMissingSdk;
          _error = looksLikeMissingSdk
              ? 'Could not start Cursor agent — CLI/SDK may be missing on the remote.\n$e'
              : 'Could not start Cursor ACP: $e';
        });
      }
      final updated = chat.copyWith(status: ChatStatus.error, updatedAt: DateTime.now());
      await ref.read(appDatabaseProvider).upsertChat(updated);
      ref.read(agentDockServiceProvider).schedulePushChat(updated.id);
      if (mounted) setState(() => _chat = updated);
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectStatus = null;
        });
      }
    }
  }

  Future<void> _setMode(AgentSessionMode mode) async {
    setState(() => _mode = mode);
    final runtime = _runtime ??
        ref.read(activeAcpSessionsProvider.notifier).get(widget.chatId);
    if (runtime == null) return;
    try {
      await runtime.setMode(mode);
    } catch (e) {
      SafeLog.d('setMode failed', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not set mode: $e')),
        );
      }
    }
  }

  void _setPermission(PermissionPolicy policy) {
    setState(() => _permission = policy);
    (_runtime ?? ref.read(activeAcpSessionsProvider.notifier).get(widget.chatId))
        ?.setPermissionPolicy(policy);
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _chat == null || _sending) return;
    if (!_chat!.provider.isAvailable) return;

    // Keep text until the agent actually accepts the prompt.
    setState(() => _sending = true);
    try {
      await _ensureAcp();
      final runtime = ref.read(activeAcpSessionsProvider.notifier).get(_chat!.id);
      if (runtime == null || runtime.closed) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _error ?? 'Could not connect to agent. Check Connect / SSH, then try again.',
              ),
            ),
          );
        }
        return;
      }
      _bindRuntime(runtime);

      final userMessage = ChatMessage(
        id: const Uuid().v4(),
        chatId: _chat!.id,
        role: MessageRole.user,
        content: text,
        createdAt: DateTime.now(),
      );

      _composer.clear();
      await runtime.appendUserMessage(userMessage);
      _scrollToEnd();
      await runtime.prompt(text).timeout(
        const Duration(minutes: 10),
        onTimeout: () => throw TimeoutException('Agent prompt timed out'),
      );
    } catch (e) {
      SafeLog.d('prompt failed', e);
      if (mounted) {
        setState(() {
          _showSdkInstallGuide = false;
          _error = 'Send failed: $e';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Send failed: $e')),
        );
      }
    } finally {
      // Always clear in-flight flags so the composer never stays locked.
      _runtime?.promptInFlight = false;
      if (mounted) setState(() => _sending = false);
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    // Keep remote ACP alive — only detach UI listener.
    if (_runtimeListener != null && _runtime != null) {
      _runtime!.removeListener(_runtimeListener!);
    }
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when runtime map changes (attach/detach).
    final live = ref.watch(activeAcpSessionsProvider)[widget.chatId];
    if (live != null && live != _runtime) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _bindRuntime(live);
      });
    }

    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_chat == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(_error ?? 'Missing chat')),
      );
    }

    final theme = Theme.of(context);
    final guide = _chat!.provider == AgentProvider.claude
        ? kRemoteClaudeSetupGuide
        : kRemoteCursorSetupGuide;

    final runtime = _runtime;
    final entries = runtime?.entries ?? _dbEntries;
    final thoughtBuffer = runtime?.thoughtBuffer ?? '';
    final assistantBuffer = runtime?.assistantBuffer ?? '';
    final sending = _sending;
    final streaming = sending || (runtime?.promptInFlight ?? false);
    final liveError = runtime?.lastError;
    final displayError = _error ?? liveError;
    final connected = runtime != null && !runtime.closed;

    final extra = <Widget>[];
    if (thoughtBuffer.isNotEmpty) {
      extra.add(_Bubble(role: MessageRole.system, text: thoughtBuffer, streaming: true));
    }
    if (assistantBuffer.isNotEmpty || streaming) {
      extra.add(
        _Bubble(
          role: MessageRole.assistant,
          text: assistantBuffer,
          streaming: true,
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_chat!.title),
            Text(
              '${_repo?.name ?? ''} · ${_chat!.provider.label}'
              '${connected ? ' · live' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          if (_repo != null && _host != null)
            IconButton(
              tooltip: 'Project files',
              onPressed: () {
                ProjectFilesScreen.open(
                  context,
                  host: _host!,
                  rootPath: _repo!.remotePath,
                  title: _repo!.name,
                );
              },
              icon: const Icon(Icons.folder_open_outlined),
            ),
          if (_connecting)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_connectStatus != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Text(
                        _connectStatus!,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ),
            )
          else
            IconButton(
              tooltip: connected
                  ? 'Agent live (stays connected in background)'
                  : 'Reconnect ACP',
              onPressed: _connecting ? null : _ensureAcp,
              icon: Icon(connected ? Icons.sensors : Icons.link),
            ),
          PopupMenuButton<String>(
            tooltip: 'Mode & permissions',
            icon: const Icon(Icons.tune),
            onSelected: (value) {
              if (value.startsWith('mode:')) {
                unawaited(_setMode(AgentSessionMode.fromId(value.substring(5))));
              } else if (value.startsWith('perm:')) {
                _setPermission(
                  value.endsWith('allowAll')
                      ? PermissionPolicy.allowAll
                      : PermissionPolicy.ask,
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(enabled: false, child: Text('Mode')),
              for (final m in AgentSessionMode.values)
                CheckedPopupMenuItem(
                  value: 'mode:${m.id}',
                  checked: _mode == m,
                  child: Text('${m.label} — ${m.subtitle}'),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(enabled: false, child: Text('Permissions')),
              CheckedPopupMenuItem(
                value: 'perm:ask',
                checked: _permission == PermissionPolicy.ask,
                child: const Text('Ask — approve each tool'),
              ),
              CheckedPopupMenuItem(
                value: 'perm:allowAll',
                checked: _permission == PermissionPolicy.allowAll,
                child: const Text('Allow all — auto-approve'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedButton<AgentSessionMode>(
                        segments: [
                          for (final m in AgentSessionMode.values)
                            ButtonSegment(value: m, label: Text(m.label)),
                        ],
                        selected: {_mode},
                        onSelectionChanged: (s) => unawaited(_setMode(s.first)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: Text(
                      _permission == PermissionPolicy.allowAll ? 'Allow all' : 'Ask',
                    ),
                    selected: _permission == PermissionPolicy.allowAll,
                    onSelected: (v) => _setPermission(
                      v ? PermissionPolicy.allowAll : PermissionPolicy.ask,
                    ),
                    avatar: Icon(
                      _permission == PermissionPolicy.allowAll
                          ? Icons.verified_user_outlined
                          : Icons.privacy_tip_outlined,
                      size: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (displayError != null && _showSdkInstallGuide)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.38,
              ),
              child: SingleChildScrollView(
                child: AgentSetupErrorBanner(
                  message: displayError,
                  setupGuide: guide,
                  onDismiss: () => setState(() {
                    _error = null;
                    _showSdkInstallGuide = false;
                  }),
                ),
              ),
            )
          else if (displayError != null)
            Material(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                title: SelectableText(
                  displayError,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!connected)
                      TextButton(
                        onPressed: _connecting
                            ? null
                            : () {
                                setState(() {
                                  _error = null;
                                  _showSdkInstallGuide = false;
                                });
                                runtime?.lastError = null;
                                unawaited(_ensureAcp());
                              },
                        child: const Text('Reconnect'),
                      ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        setState(() => _error = null);
                        runtime?.lastError = null;
                      },
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: entries.length + extra.length,
              itemBuilder: (context, index) {
                if (index >= entries.length) {
                  return extra[index - entries.length];
                }
                final entry = entries[index];
                if (entry.tool != null) {
                  return ToolCallCard(tool: entry.tool!);
                }
                final m = entry.message!;
                return _Bubble(role: m.role, text: m.content);
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      minLines: 1,
                      maxLines: 5,
                      enabled: _chat!.provider.isAvailable,
                      decoration: InputDecoration(
                        hintText: _chat!.provider.isAvailable
                            ? (_connecting
                                ? 'Connecting agent…'
                                : connected
                                    ? 'Message Cursor agent…'
                                    : 'Message agent…')
                            : 'Claude is beta',
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) {
                        if (!_sending) _send();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending || !_chat!.provider.isAvailable ? null : _send,
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.role,
    required this.text,
    this.streaming = false,
  });

  final MessageRole role;
  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = role == MessageRole.user;

    if (role == MessageRole.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.psychology_alt, size: 14, color: theme.colorScheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: SelectableLinkify(
                text: text,
                onOpen: _openLink,
                options: const LinkifyOptions(humanize: false, looseUrl: true),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
                linkStyle: TextStyle(
                  color: theme.colorScheme.primary,
                  decoration: TextDecoration.underline,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final bg = isUser
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.88),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.smart_toy_outlined, size: 14, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'Agent',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (streaming) ...[
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            SelectableLinkify(
              text: streaming && text.isEmpty ? '…' : text,
              onOpen: _openLink,
              options: const LinkifyOptions(humanize: false, looseUrl: true),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
              linkStyle: TextStyle(
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openLink(LinkableElement link) async {
  var raw = link.url.trim();
  if (!raw.contains('://')) {
    raw = 'https://$raw';
  }
  final uri = Uri.tryParse(raw);
  if (uri == null) return;
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  } catch (_) {
    // Ignore — bad URL or no handler.
  }
}
