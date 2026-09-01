import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/agent_mode.dart';
import '../../data/models/agent_model.dart';
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
import 'agent_status_indicators.dart';
import 'message_body.dart';
import 'model_picker_sheet.dart';
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

  /// True when the last connect attached to an agent that was still running,
  /// so the conversation carried over untouched.
  bool _resumedInPlace = false;

  AgentSessionMode _mode = AgentSessionMode.agent;
  PermissionPolicy _permission = PermissionPolicy.allowAll;

  ChatSessionRuntime? _runtime;
  VoidCallback? _runtimeListener;
  Future<void>? _ensureAcpInFlight;
  Timer? _markReadTimer;
  bool _landedAtBottom = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Paint from SQLite immediately; the network only ever upgrades what is
  /// already on screen.
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
    _landAtBottom();

    final existing = ref.read(activeAcpSessionsProvider.notifier).get(chat.id);
    if (existing != null) {
      _bindRuntime(existing);
      // Closed runtimes reconnect in the background — do not leave the UI
      // stuck on a stale DB-only transcript until the user taps Connect.
      unawaited(existing.syncTranscriptFromDb());
      if (existing.closed) {
        existing.resume();
      }
    }
    // Don't auto-connect a brand-new chat — reconnect when you send or tap
    // Connect. Auto-connect was blocking messaging when SSH hung.

    unawaited(_syncFromRemote());
  }

  Future<void> _syncFromRemote() async {
    final host = _host;
    if (host == null) return;
    try {
      if (!await ref.read(secureStoreProvider).hasSshPrivateKey()) return;
      final dock = ref.read(agentDockServiceProvider);
      final recordChanged = await dock.syncChatRecord(
        host: host,
        chatId: widget.chatId,
      );
      if (recordChanged && mounted) {
        final refreshed =
            await ref.read(appDatabaseProvider).getChat(widget.chatId);
        if (refreshed != null) _chat = refreshed;
      }
      final changed = await dock.syncChatMessages(
            host: host,
            chatId: widget.chatId,
          );
      if (!mounted) return;
      final runtime = _runtime;
      if (runtime != null) {
        if (changed) {
          await runtime.syncTranscriptFromDb();
        }
        return;
      }
      if (!changed) return;
      final messages =
          await ref.read(appDatabaseProvider).listMessages(widget.chatId);
      if (!mounted || _runtime != null) return;
      setState(() {
        _dbEntries
          ..clear()
          ..addAll(_entriesFromMessages(messages));
      });
    } catch (e) {
      SafeLog.d('agentdock message sync failed', e);
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

  /// Stable chronological order for the transcript list.
  static List<TranscriptEntry> _entriesByTime(List<TranscriptEntry> input) {
    if (input.length < 2) return input;
    final indexed = [for (var i = 0; i < input.length; i++) (i, input[i])];
    indexed.sort((a, b) {
      final at = a.$2.createdAt;
      final bt = b.$2.createdAt;
      if (at == null && bt == null) return a.$1.compareTo(b.$1);
      if (at == null) return 1;
      if (bt == null) return -1;
      final byTime = at.compareTo(bt);
      if (byTime != 0) return byTime;
      return a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// Collapse tool spam between user messages into one expandable row.
  ///
  /// Assistant text between tools used to break consecutive runs, so a turn
  /// with 20 tools rendered as 20 separate cards. Group every tool that sits
  /// between two user bubbles when there are more than two.
  static List<_ChatBlock> _blocksFor(List<TranscriptEntry> entries) {
    final blocks = <_ChatBlock>[];
    var i = 0;
    while (i < entries.length) {
      final entry = entries[i];
      if (entry.message?.role == MessageRole.user) {
        blocks.add(_ChatBlock.single(entry));
        i++;
        continue;
      }

      final segment = <TranscriptEntry>[];
      while (i < entries.length &&
          entries[i].message?.role != MessageRole.user) {
        segment.add(entries[i]);
        i++;
      }

      final tools = [for (final e in segment) if (e.tool != null) e];
      if (tools.length > 2) {
        var emittedTools = false;
        for (final e in segment) {
          if (e.tool != null) {
            if (!emittedTools) {
              blocks.add(_ChatBlock.tools(tools));
              emittedTools = true;
            }
          } else {
            blocks.add(_ChatBlock.single(e));
          }
        }
      } else {
        for (final e in segment) {
          blocks.add(_ChatBlock.single(e));
        }
      }
    }
    return blocks;
  }

  /// While the transcript is on screen the user is by definition seeing it, so
  /// keep the read watermark moving. Debounced: a streaming turn notifies far
  /// too often to write on every tick.
  void _scheduleMarkRead() {
    _markReadTimer ??= Timer(const Duration(milliseconds: 600), () {
      _markReadTimer = null;
      if (!mounted) return;
      unawaited(
        ref.read(appDatabaseProvider).markChatRead(widget.chatId).then((_) {
          if (!mounted) return;
          ref.read(agentDockServiceProvider).schedulePushChat(widget.chatId);
        }),
      );
    });
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
      _permission = runtime.permissionPolicy;
      if (runtime.lastError != null && runtime.closed) {
        _error = runtime.lastError;
      }
      setState(() {});
      _scrollToEnd();
      _scheduleMarkRead();
    };
    runtime.addListener(_runtimeListener!);
    setState(() {});
    _scrollToEnd();
    // Coming back to a chat whose turn already finished should drain the queue.
    runtime.resumeOutboundQueue();
    unawaited(_prefetchModelCatalogIfNeeded(runtime));
  }

  Future<void> _prefetchModelCatalogIfNeeded(ChatSessionRuntime runtime) async {
    if (runtime.closed ||
        runtime.availableModels.isNotEmpty ||
        runtime.isWorking) {
      return;
    }
    final host = _host;
    if (host == null) return;
    try {
      final mcps =
          await ref.read(appDatabaseProvider).listEnabledMcpsForHost(host.id);
      await runtime.ensureModelCatalog(
        mcps.map((m) => m.toAcpConfig()).toList(growable: false),
      );
      if (mounted) setState(() {});
    } catch (e) {
      SafeLog.d('prefetch model catalog failed', e);
    }
  }

  Future<void> _ensureAcp() {
    _ensureAcpInFlight ??= _ensureAcpBody().whenComplete(() {
      _ensureAcpInFlight = null;
    });
    return _ensureAcpInFlight!;
  }

  /// A closure that can open a transport for this chat at any later time.
  ///
  /// It captures the services directly instead of `ref`, because the runtime
  /// keeps reconnecting in the background after this screen is disposed.
  Future<AcpSession> Function() _buildSessionFactory({
    required String chatId,
    required String cwd,
  }) {
    final ssh = ref.read(sshServiceProvider);
    final secureStore = ref.read(secureStoreProvider);
    final db = ref.read(appDatabaseProvider);
    final runtimeHost = ref.read(agentRuntimeHostProvider);
    final sessions = ref.read(activeAcpSessionsProvider.notifier);
    final host = _host!;
    final provider = _chat?.provider ?? AgentProvider.cursor;
    // Fallbacks for the first connect, before a runtime exists.
    final fallbackMode = _mode;
    final fallbackPermission = _permission;

    return () async {
      final live = sessions.get(chatId);
      final mode = live?.preferredMode ?? fallbackMode;
      final permission =
          live?.preferredPermissionPolicy ?? fallbackPermission;

      void status(String message) {
        // Factory outlives the screen; only paint when this chat is open.
        if (!mounted) return;
        setState(() => _connectStatus = message);
      }

      status(
        provider == AgentProvider.claude
            ? 'Checking Claude on the remote…'
            : 'Checking Cursor CLI on the remote…',
      );

      // Install tmux first so durable sessions work once the agent binary is up.
      try {
        await ssh.ensureTmux(host, onProgress: status);
      } catch (e) {
        SafeLog.d('tmux ensure failed (will run without durable session)', e);
      }

      final binary = switch (provider) {
        AgentProvider.cursor => await ssh.ensureCursorCli(
              host,
              onProgress: status,
            ).timeout(
              const Duration(minutes: 8),
              onTimeout: () => throw TimeoutException(
                'Timed out installing/finding Cursor CLI on the remote.',
              ),
            ),
        AgentProvider.claude => await ssh.ensureClaudeAcpBinary(
              host,
              onProgress: status,
            ).timeout(
              const Duration(minutes: 12),
              onTimeout: () => throw TimeoutException(
                'Timed out installing/finding Claude ACP on the remote.',
              ),
            ),
      };
      // Without tmux we can still run, just not durably.
      final durable = await ssh.hasTmux(host);
      final mcps = await db.listEnabledMcpsForHost(host.id);
      final latest = await db.getChat(chatId);

      status('Starting agent…');

      return AcpSession.start(
        ssh: ssh,
        secureStore: secureStore,
        host: host,
        cwd: cwd,
        binary: binary,
        chatId: chatId,
        runtimeHost: runtimeHost,
        provider: provider,
        mcpServers: mcps.map((m) => m.toAcpConfig()).toList(),
        initialMode: mode,
        permissionPolicy: permission,
        resumeSessionId: latest?.acpSessionId,
        preferredModelId: latest?.modelId,
        journalOffset: latest?.journalOffset ?? 0,
        durable: durable,
        onJournalAdvance: (bytes) => sessions.noteJournalOffset(chatId, bytes),
      ).timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException(
          provider == AgentProvider.claude
              ? 'Connect timed out. Set ANTHROPIC_API_KEY in Connect or run '
                  '`claude login` on the remote, then Connect again.'
              : 'Connect timed out. Try `agent login` on the remote in the Terminal '
                  'tab, then Connect again.',
        ),
      );
    };
  }

  Future<void> _ensureAcpBody() async {
    final repo = _repo;
    final host = _host;
    if (_chat == null || repo == null || host == null) return;
    var chat = _chat!;

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
      existing.sessionFactory = _buildSessionFactory(
        chatId: chat.id,
        cwd: repo.remotePath,
      );
      _bindRuntime(existing);
      if (existing.permissionPolicy != _permission) {
        try {
          await existing.applyPermissionPolicy(_permission);
        } catch (e) {
          SafeLog.d('applyPermissionPolicy on existing session failed', e);
        }
      }
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
      _connectStatus = chat.provider == AgentProvider.claude
          ? 'Preparing Claude on the remote…'
          : 'Preparing Cursor on the remote…';
      _error = null;
      _showSdkInstallGuide = false;
    });

    try {
      // Pull the live session id Mac wrote before we attach — without it the
      // agent starts over and only sees messages sent on this device.
      try {
        final changed = await ref.read(agentDockServiceProvider).syncChatRecord(
              host: host,
              chatId: chat.id,
            );
        if (changed) {
          final refreshed =
              await ref.read(appDatabaseProvider).getChat(chat.id);
          if (refreshed != null) {
            chat = refreshed;
            if (mounted) setState(() => _chat = refreshed);
          }
        }
      } catch (e) {
        SafeLog.d('sync chat record before connect failed', e);
      }

      final factory = _buildSessionFactory(chatId: chat.id, cwd: repo.remotePath);

      final session = await factory();

      final runtime = await ref.read(activeAcpSessionsProvider.notifier).attach(
            chatId: chat.id,
            session: session,
            sessionFactory: factory,
          );
      runtime.chatMeta = chat;
      _bindRuntime(runtime);

      final sessionId = session.sessionId;
      if (sessionId != null) {
        unawaited(
          ref.read(agentRuntimeHostProvider).writeSessionId(
                host,
                chat.id,
                sessionId,
              ),
        );
      }

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
          _resumedInPlace = session.resumedInPlace;
        });
      }
      if (session.resumedInPlace) {
        unawaited(_prefetchModelCatalogIfNeeded(runtime));
      }
    } on MissingToolException catch (e) {
      if (mounted) {
        final isClaude = chat.provider == AgentProvider.claude;
        setState(() {
          _showSdkInstallGuide = true;
          _error = isClaude
              ? 'Could not install Claude on ${host.displayLabel}.\n'
                  'Agent Dock tried automatically — run the setup below on the '
                  'remote (or fix network/sudo), then Connect again.\n\n'
                  '${e.tool} still missing.'
              : 'Could not install Cursor CLI on ${host.displayLabel}.\n'
                  'Agent Dock tried automatically — run the setup below on the '
                  'remote, then Connect again.\n\n'
                  '${e.tool} still missing.';
        });
      }
    } catch (e) {
      SafeLog.d('ACP connect failed', e);
      final lower = e.toString().toLowerCase();
      final isClaude = chat.provider == AgentProvider.claude;
      final looksLikeMissingSdk = lower.contains('cursor') ||
          lower.contains('claude') ||
          lower.contains('claude-code-acp') ||
          lower.contains('agent') ||
          lower.contains('not found') ||
          lower.contains('no such file') ||
          lower.contains('install');
      if (mounted) {
        setState(() {
          _showSdkInstallGuide = looksLikeMissingSdk;
          _error = looksLikeMissingSdk
              ? (isClaude
                  ? 'Could not start Claude — install may have failed on the remote.\n$e'
                  : 'Could not start Cursor — install may have failed on the remote.\n$e')
              : 'Could not start ${isClaude ? 'Claude' : 'Cursor'} ACP: $e';
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

  /// The live session's model when connected, otherwise the stored preference.
  AgentModel? get _selectedModel {
    final id = _runtime?.currentModelId ?? _chat?.modelId;
    if (id == null || id.isEmpty) return null;
    for (final model in _runtime?.availableModels ?? const <AgentModel>[]) {
      if (model.modelId == id) return model;
    }
    // Not connected yet, so derive what we can from the id itself.
    return AgentModel.parse(id);
  }

  Future<void> _pickMode() async {
    final chosen = await showModalBottomSheet<AgentSessionMode>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in AgentSessionMode.values)
              ListTile(
                leading: Icon(
                  m == _mode
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: m == _mode ? Theme.of(context).colorScheme.primary : null,
                ),
                title: Text(m.label),
                subtitle: Text(m.subtitle),
                onTap: () => Navigator.pop(context, m),
              ),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != _mode) await _setMode(chosen);
  }

  Future<void> _pickModel() async {
    // The model list only exists on a live session, so connect first rather
    // than showing an empty picker.
    if ((_runtime?.availableModels ?? const []).isEmpty && !_connecting) {
      await _ensureAcp();
    }
    if (!mounted) return;

    final runtime = _runtime ??
        ref.read(activeAcpSessionsProvider.notifier).get(widget.chatId);

    if ((runtime?.availableModels ?? const []).isEmpty &&
        runtime != null &&
        !runtime.closed) {
      await _prefetchModelCatalogIfNeeded(runtime);
    }
    if (!mounted) return;

    final chosen = await ModelPickerSheet.show(
      context,
      models: runtime?.availableModels ?? const [],
      selectedId: _selectedModel?.modelId,
    );
    if (chosen == null || !mounted) return;

    try {
      if (runtime != null && !runtime.closed) {
        await runtime.setModel(chosen);
      } else {
        // Offline: remember it so the next connect applies it.
        final chat = _chat;
        if (chat != null) {
          final updated = chat.copyWith(modelId: chosen, updatedAt: DateTime.now());
          await ref.read(appDatabaseProvider).upsertChat(updated);
          ref.read(agentDockServiceProvider).schedulePushChat(updated.id);
        }
      }
      if (!mounted) return;
      setState(() => _chat = _chat?.copyWith(modelId: chosen));
    } catch (e) {
      SafeLog.d('setModel failed', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not switch model: $e')),
        );
      }
    }
  }

  void _setPermission(PermissionPolicy policy) {
    setState(() => _permission = policy);
    final runtime = _runtime ??
        ref.read(activeAcpSessionsProvider.notifier).get(widget.chatId);
    if (runtime == null) return;
    // Keep reconnect factory current even before apply finishes.
    final repo = _repo;
    if (repo != null) {
      runtime.sessionFactory = _buildSessionFactory(
        chatId: widget.chatId,
        cwd: repo.remotePath,
      );
    }
    unawaited(() async {
      try {
        await runtime.applyPermissionPolicy(policy);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not switch permission: $e')),
        );
      }
      if (mounted) setState(() => _permission = runtime.permissionPolicy);
    }());
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _chat == null) return;
    if (!_chat!.provider.isAvailable) return;

    // Composer stays usable while a turn runs — messages go on the outbound
    // queue. Only block the button briefly while we ensure the transport.
    _composer.clear();
    setState(() => _sending = true);
    try {
      await _ensureAcp();
      final runtime =
          ref.read(activeAcpSessionsProvider.notifier).get(_chat!.id);
      if (runtime == null || runtime.closed) {
        // Put the text back so the user does not lose it.
        _composer.text = text;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                _error ??
                    'Could not connect to agent. Check Connect / SSH, then try again.',
              ),
            ),
          );
        }
        return;
      }
      _bindRuntime(runtime);
      // Returns as soon as the message is appended (and queued if busy).
      // The turn itself runs in the background on the runtime.
      await runtime.enqueueOrPrompt(text);
      _scrollToEnd(force: true);
    } catch (e) {
      SafeLog.d('send failed', e);
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
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _forceRun({String? messageId}) async {
    final runtime = _runtime ??
        ref.read(activeAcpSessionsProvider.notifier).get(widget.chatId);
    if (runtime == null) return;
    try {
      await runtime.forceRun(messageId: messageId);
      _scrollToEnd(force: true);
    } catch (e) {
      SafeLog.d('force-run failed', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Force run failed: $e')),
        );
      }
    }
  }

  /// Open on the newest message rather than the top of the history.
  ///
  /// The list is lazy, so its scroll extent keeps growing for several frames as
  /// rows are built and markdown lays out. Animating would chase a target that
  /// is still moving and stop short, so pin to the end until it settles.
  void _landAtBottom({int framesLeft = 10}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) {
        final max = _scroll.position.maxScrollExtent;
        if ((_scroll.position.pixels - max).abs() > 1) _scroll.jumpTo(max);
      }
      if (framesLeft > 1) {
        _landAtBottom(framesLeft: framesLeft - 1);
      } else {
        _landedAtBottom = true;
      }
    });
  }

  /// Close enough to the end that the user is following the live turn rather
  /// than reading back through history.
  bool get _isNearBottom {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    return position.maxScrollExtent - position.pixels < 160;
  }

  void _scrollToEnd({bool force = false}) {
    // Don't fight the initial landing, and don't yank the view down while the
    // user is scrolled up reading something.
    if (!force && (!_landedAtBottom || !_isNearBottom)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
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
    _markReadTimer?.cancel();
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
    final queue = runtime?.outboundQueue ?? const <ChatMessage>[];
    final queuedIds = {for (final m in queue) m.id};
    // Queued messages live in the DB but stay out of [entries] until promoted,
    // so filter defensively in case a stale row is still present.
    final rawEntries = runtime?.entries ?? _dbEntries;
    final liveAssistantId = runtime?.liveAssistantMessageId;
    final filtered = [
      for (final e in rawEntries)
        if (e.messageId == null ||
            (!queuedIds.contains(e.messageId) &&
                e.messageId != liveAssistantId))
          e,
    ];
    // Hide persisted thought/system crumbs from the main thread — they still
    // stream live above the agent bubble while a turn is open.
    final visible = [
      for (final e in filtered)
        if (e.message?.role != MessageRole.system) e,
    ];
    // Late flushes can append an older assistant row after a newer user row.
    // Paint in clock order so the thread reads like a normal chat.
    final entries = _entriesByTime(visible);
    final blocks = _blocksFor(entries);
    final thoughtBuffer = runtime?.thoughtBuffer ?? '';
    final assistantBuffer = runtime?.assistantBuffer ?? '';
    // Composer no longer locks for the whole turn — only the live buffer
    // counts as "working" for the agent bubble.
    final streaming = runtime?.isWorking ?? false;
    final liveError = runtime?.lastError;
    final displayError = _error ?? liveError;
    final connected = runtime != null && !runtime.closed;
    final reconnecting = runtime?.reconnecting ?? false;
    final remoteRunning = runtime?.remoteTurnActive == true;
    final activeTools = runtime == null
        ? 0
        : runtime.entries.where((e) => e.tool?.isActive ?? false).length;
    final statusLabel = switch (true) {
      _ when reconnecting => ' · reconnecting…',
      _ when remoteRunning && !connected => ' · running on host',
      _ when streaming && activeTools > 0 =>
        ' · working · $activeTools tool${activeTools == 1 ? '' : 's'}',
      _ when streaming => ' · working',
      _ when connected && _resumedInPlace => ' · live · resumed',
      _ when connected => ' · live',
      _ => '',
    };

    final extra = <Widget>[];
    // Keep live text visible even if isWorking cleared a tick before flush —
    // that race used to make the answer vanish until reopen.
    if (thoughtBuffer.isNotEmpty || assistantBuffer.isNotEmpty) {
      if (thoughtBuffer.isNotEmpty) {
        extra.add(_Bubble(
          role: MessageRole.system,
          text: thoughtBuffer,
          streaming: true,
        ));
      }
      // Live answer stays above queued user bubbles so the current turn can
      // finish without burying what the user just scheduled.
      if (assistantBuffer.isNotEmpty) {
        extra.add(
          _Bubble(
            role: MessageRole.assistant,
            text: assistantBuffer,
            streaming: true,
          ),
        );
      }
    }
    for (final m in queue) {
      extra.add(
        _Bubble(
          role: MessageRole.user,
          text: m.content,
          at: m.createdAt,
          queued: true,
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
              '${_repo?.name ?? ''} · ${_chat!.provider.label}$statusLabel',
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
          if (_connecting || reconnecting)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_connectStatus != null || reconnecting)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Text(
                        _connectStatus ??
                            'Reconnecting (${runtime?.reconnectAttempts ?? 0})…',
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
                  ? 'Agent live — keeps running on the host if you disconnect'
                  : 'Reconnect ACP',
              onPressed: _connecting ? null : _ensureAcp,
              icon: Icon(connected ? Icons.sensors : Icons.link),
            ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  _ToolbarChip(
                    icon: Icons.tune,
                    label: _mode.label,
                    opensMenu: true,
                    onTap: _pickMode,
                  ),
                  const SizedBox(width: 8),
                  _ToolbarChip(
                    icon: Icons.auto_awesome_outlined,
                    label: _selectedModel?.name ?? 'Model',
                    detail: _selectedModel?.badges.join(' · '),
                    opensMenu: true,
                    onTap: _pickModel,
                  ),
                  const SizedBox(width: 8),
                  _ToolbarChip(
                    icon: _permission == PermissionPolicy.allowAll
                        ? Icons.verified_user_outlined
                        : Icons.privacy_tip_outlined,
                    label: _permission.label,
                    selected: _permission == PermissionPolicy.allowAll,
                    onTap: () => _setPermission(
                      _permission == PermissionPolicy.allowAll
                          ? PermissionPolicy.ask
                          : PermissionPolicy.allowAll,
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
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 140),
                child: ListTile(
                  dense: true,
                  title: SingleChildScrollView(
                    child: SelectableText(
                      displayError,
                      style: TextStyle(
                        color: theme.colorScheme.onErrorContainer,
                      ),
                    ),
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
                          setState(() {
                            _error = null;
                            _showSdkInstallGuide = false;
                          });
                          runtime?.lastError = null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(12),
              itemCount: blocks.length + extra.length,
              itemBuilder: (context, index) {
                if (index >= blocks.length) {
                  return extra[index - blocks.length];
                }
                final block = blocks[index];
                final prevAt =
                    index > 0 ? blocks[index - 1].createdAt : null;
                final at = block.createdAt;
                final showDate = at != null &&
                    (prevAt == null ||
                        prevAt.year != at.year ||
                        prevAt.month != at.month ||
                        prevAt.day != at.day);

                final Widget body;
                final tools = block.tools;
                if (tools != null) {
                  body = ToolCallGroupCard(
                    tools: [for (final e in tools) e.tool!],
                  );
                } else if (block.entry!.tool != null) {
                  body = ToolCallCard(tool: block.entry!.tool!);
                } else {
                  final m = block.entry!.message!;
                  body = _Bubble(
                    role: m.role,
                    text: m.content,
                    at: m.createdAt,
                  );
                }
                if (!showDate) return body;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _DateChip(at),
                    body,
                  ],
                );
              },
            ),
          ),
          if (queue.isNotEmpty)
            _OutboundQueueBar(
              queue: queue,
              busy: streaming,
              onForceRun: (id) => unawaited(_forceRun(messageId: id)),
              onForceRunNext: () => unawaited(_forceRun()),
              onRemove: (id) =>
                  unawaited(runtime?.removeFromQueue(id) ?? Future<void>.value()),
            ),
          if (runtime?.pendingPermission != null)
            _PermissionPromptBar(
              request: runtime!.pendingPermission!,
              onSelect: (optionId) {
                runtime.resolvePermission(
                  runtime.pendingPermission!.requestId,
                  optionId,
                );
              },
            ),
          if (streaming)
            Material(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        activeTools > 0
                            ? 'Agent is working · $activeTools tool${activeTools == 1 ? '' : 's'} running'
                            : assistantBuffer.isEmpty && thoughtBuffer.isEmpty
                                ? 'Waiting on agent…'
                                : 'Agent is working',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        try {
                          await runtime?.unstick();
                        } catch (e) {
                          SafeLog.d('unstick failed', e);
                        }
                      },
                      child: const Text('Unstick'),
                    ),
                  ],
                ),
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
                      enabled: _chat!.provider.isAvailable && !_connecting,
                      decoration: InputDecoration(
                        hintText: _connecting
                            ? 'Connecting agent…'
                            : streaming
                                ? 'Message (queued until Force run)…'
                                : connected
                                    ? 'Message ${_chat!.provider.label} agent…'
                                    : 'Message agent…',
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) {
                        if (!_sending) unawaited(_send());
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    // Only block while connecting or during the brief enqueue
                    // handshake — never for the whole agent turn.
                    onPressed: _connecting ||
                            _sending ||
                            !_chat!.provider.isAvailable
                        ? null
                        : () => unawaited(_send()),
                    icon: _connecting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(streaming ? Icons.playlist_add : Icons.send),
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

/// One paint unit in the transcript list: a message, a lone tool, or a
/// collapsed run of consecutive tools.
class _ChatBlock {
  const _ChatBlock._({this.entry, this.tools});

  factory _ChatBlock.single(TranscriptEntry entry) =>
      _ChatBlock._(entry: entry);

  factory _ChatBlock.tools(List<TranscriptEntry> tools) =>
      _ChatBlock._(tools: tools);

  final TranscriptEntry? entry;
  final List<TranscriptEntry>? tools;

  DateTime? get createdAt =>
      tools?.first.createdAt ?? entry?.createdAt;
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.role,
    required this.text,
    this.streaming = false,
    this.queued = false,
    this.at,
  });

  final MessageRole role;
  final String text;
  final bool streaming;
  final bool queued;
  final DateTime? at;

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
              child: MessageBody(
                text: text,
                dense: true,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.35,
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
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.88),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: queued
              ? Border.all(
                  color: theme.colorScheme.primary.withValues(alpha: 0.45),
                )
              : null,
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
                    Shimmer(
                      enabled: streaming,
                      child: Text(
                        streaming ? 'Agent is working' : 'Agent',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (queued)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.schedule,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Queued',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            MessageBody(
              text: streaming && text.isEmpty ? '…' : text,
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!streaming && !queued && text.trim().isNotEmpty) ...[
                  IconButton(
                    tooltip: 'Copy text for Teams',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () => copyMessageForTeams(context, text),
                    icon: Icon(
                      Icons.copy_rounded,
                      size: 14,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy HTML for Teams',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () => copyMessageHtmlForTeams(context, text),
                    icon: Icon(
                      Icons.html,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
                if (at != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      _formatClock(at!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                        fontSize: 10,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatClock(DateTime at) {
  final local = at.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

class _DateChip extends StatelessWidget {
  const _DateChip(this.day);

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(day.year, day.month, day.day);
    final label = switch (today.difference(that).inDays) {
      0 => 'Today',
      1 => 'Yesterday',
      _ => '${_month(that.month)} ${that.day}, ${that.year}',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  static String _month(int m) => _months[m - 1];
}

/// Pending outbound prompts while the agent is still on a turn.
class _OutboundQueueBar extends StatelessWidget {
  const _OutboundQueueBar({
    required this.queue,
    required this.busy,
    required this.onForceRun,
    required this.onForceRunNext,
    required this.onRemove,
  });

  final List<ChatMessage> queue;
  final bool busy;
  final void Function(String id) onForceRun;
  final VoidCallback onForceRunNext;
  final void Function(String id) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.schedule, size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  busy
                      ? 'Queued · agent is working'
                      : 'Queued',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: onForceRunNext,
                  child: const Text('Force run'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            for (final m in queue)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        m.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => onForceRun(m.id),
                      child: const Text('Run'),
                    ),
                    IconButton(
                      tooltip: 'Remove from queue',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => onRemove(m.id),
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Ask-mode approval strip — one action the agent is blocked on.
class _PermissionPromptBar extends StatelessWidget {
  const _PermissionPromptBar({
    required this.request,
    required this.onSelect,
  });

  final PendingPermissionRequest request;
  final void Function(String optionId) onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final options = request.options.isNotEmpty
        ? request.options
        : const [
            PermissionOption(
              optionId: 'allow-once',
              name: 'Allow once',
              kind: 'allow_once',
            ),
            PermissionOption(
              optionId: 'reject-once',
              name: 'Reject',
              kind: 'reject_once',
            ),
          ];

    return Material(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.privacy_tip_outlined,
                    size: 18, color: scheme.onTertiaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    request.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: scheme.onTertiaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (request.description != null &&
                request.description!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                request.description!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final o in options)
                  o.isReject
                      ? OutlinedButton(
                          onPressed: () => onSelect(o.optionId),
                          child: Text(o.name),
                        )
                      : FilledButton(
                          onPressed: () => onSelect(o.optionId),
                          child: Text(o.name),
                        ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact toolbar control. Sized for a phone: icon, short label, and an
/// optional detail line that is dropped when there is no room.
class _ToolbarChip extends StatelessWidget {
  const _ToolbarChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.detail,
    this.selected = false,
    this.opensMenu = false,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final bool selected;
  final bool opensMenu;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected ? scheme.onSecondaryContainer : scheme.onSurface;

    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surface,
      shape: StadiumBorder(
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 7),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                      ),
                    ),
                    if (detail != null && detail!.isNotEmpty)
                      Text(
                        detail!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (opensMenu)
                Icon(Icons.expand_more, size: 16, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
