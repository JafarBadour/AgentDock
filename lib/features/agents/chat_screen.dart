import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/app_theme.dart';
import '../../app/providers.dart';
import '../../data/models/agent_mode.dart';
import '../../data/models/agent_model.dart';
import '../../data/models/agent_provider.dart';
import '../../data/models/chat.dart';
import '../../data/models/chat_message.dart';
import '../../data/models/code_change_stats.dart';
import '../../data/models/host.dart';
import '../../data/models/prompt_image.dart';
import '../../data/models/repo.dart';
import '../../data/models/scheduled_job.dart';
import '../../data/models/thought_message.dart';
import '../../data/models/tool_call_state.dart';
import '../../data/secure/safe_log.dart';
import '../../services/adsm_client.dart';
import '../../services/agent_session.dart';
import '../../services/chat_session_runtime.dart';
import '../../services/cursor_acp_service.dart';
import '../../services/gcp_speech_service.dart';
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

class _ChatScreenState extends ConsumerState<ChatScreen>
    with SingleTickerProviderStateMixin {
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
  bool _showJumpToLatest = false;
  /// When true, keep the viewport pinned to new agent output.
  /// Cleared as soon as the user scrolls away from the bottom.
  bool _followOutput = true;
  bool _programmaticScroll = false;
  int _messageCount = 0;
  bool _dismissCompressHint = false;
  final List<ChatImageRef> _pendingImages = [];
  bool _pickingImages = false;
  bool _composerHasText = false;
  bool _recordingVoice = false;
  bool _transcribingVoice = false;
  /// Bumped when a new transcription starts or is abandoned so late results drop.
  int _transcribeEpoch = 0;
  bool _showSlashMenu = false;
  bool _compressing = false;

  /// Telegram-style: recording continues after finger-up until stop.
  bool _voiceLocked = false;
  bool _voiceCancelArmed = false;
  bool _voiceLockArmed = false;
  double _voiceDragDx = 0;
  double _voiceDragDy = 0;
  DateTime? _voiceStartedAt;
  Timer? _voiceTick;
  int _voiceElapsedSec = 0;
  late final AnimationController _voicePulse;
  bool _voiceStarting = false;
  bool _voiceReleasePending = false;
  bool _voiceCancelPending = false;

  static const _slashCommands = [
    (cmd: 'compress', hint: 'Summarize this conversation for later schedules'),
    (cmd: 'schedule', hint: 'Schedule a prompt on the host'),
  ];

  static const _voiceCancelThreshold = -72.0;
  static const _voiceLockThreshold = -56.0;

  @override
  void initState() {
    super.initState();
    _voicePulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _composer.addListener(_onComposerChanged);
    _scroll.addListener(_onScrollOffsetChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(focusedChatIdProvider.notifier).state = widget.chatId;
    });
    _bootstrap();
  }

  void _onComposerChanged() {
    final raw = _composer.text;
    final has = raw.trim().isNotEmpty;
    final slash = raw.startsWith('/') && !raw.contains('\n') && !raw.contains(' ');
    if (has != _composerHasText || slash != _showSlashMenu) {
      if (mounted) {
        setState(() {
          _composerHasText = has;
          _showSlashMenu = slash;
        });
      }
    } else if (mounted && slash) {
      setState(() {}); // refresh filter highlight
    }
  }

  void _onScrollOffsetChanged() {
    if (!_landedAtBottom || _programmaticScroll) return;
    final near = _isNearBottom;
    // User dragged away from the live turn — stop yanking them back.
    if (!near && _followOutput) {
      _followOutput = false;
    } else if (near && !_followOutput) {
      _followOutput = true;
    }
    final show = !_followOutput;
    if (show != _showJumpToLatest && mounted) {
      setState(() => _showJumpToLatest = show);
    }
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
      _messageCount = messages.length;
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
  /// System (thought) messages fold into the next assistant reply as a
  /// collapsible "Thinking" section.
  static List<_ChatBlock> _blocksFor(List<TranscriptEntry> entries) {
    final thinkingByAssistantId = <String, String>{};
    final pendingThoughts = <String>[];
    final compact = <TranscriptEntry>[];
    final orphanBeforeIndex = <int, String>{};
    String? trailingThinking;

    for (final e in entries) {
      final role = e.message?.role;
      if (role == MessageRole.system) {
        final body = ThoughtMessage.display(e.message!.content);
        if (body.isNotEmpty) pendingThoughts.add(body);
        continue;
      }
      if (role == MessageRole.user) {
        if (pendingThoughts.isNotEmpty) {
          orphanBeforeIndex[compact.length] = pendingThoughts.join('\n\n');
          pendingThoughts.clear();
        }
        compact.add(e);
        continue;
      }
      if (role == MessageRole.assistant && pendingThoughts.isNotEmpty) {
        final id = e.message?.id;
        if (id != null) {
          thinkingByAssistantId[id] = pendingThoughts.join('\n\n');
        }
        pendingThoughts.clear();
      }
      compact.add(e);
    }
    if (pendingThoughts.isNotEmpty) {
      trailingThinking = pendingThoughts.join('\n\n');
    }

    final blocks = <_ChatBlock>[];
    var i = 0;
    while (i < compact.length) {
      final orphan = orphanBeforeIndex[i];
      if (orphan != null && orphan.isNotEmpty) {
        blocks.add(_ChatBlock.thinking(orphan));
      }

      final entry = compact[i];
      if (entry.message?.role == MessageRole.user) {
        blocks.add(_ChatBlock.single(entry));
        i++;
        continue;
      }

      final segmentStart = i;
      final segment = <TranscriptEntry>[];
      while (i < compact.length &&
          compact[i].message?.role != MessageRole.user) {
        // Orphan thoughts are keyed at compact indices; if one sits mid-segment
        // (shouldn't — only before user), stop so the next loop emits it.
        if (i != segmentStart && orphanBeforeIndex.containsKey(i)) break;
        segment.add(compact[i]);
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
            final id = e.message?.id;
            blocks.add(
              _ChatBlock.single(
                e,
                thinking: e.message?.role == MessageRole.assistant && id != null
                    ? thinkingByAssistantId[id]
                    : null,
              ),
            );
          }
        }
      } else {
        for (final e in segment) {
          final id = e.message?.id;
          blocks.add(
            _ChatBlock.single(
              e,
              thinking: e.message?.role == MessageRole.assistant && id != null
                  ? thinkingByAssistantId[id]
                  : null,
            ),
          );
        }
      }
    }

    if (trailingThinking != null && trailingThinking.isNotEmpty) {
      blocks.add(_ChatBlock.thinking(trailingThinking));
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
      // Auto-reconnect clears runtime.lastError, but this screen used to copy
      // "ADSM channel closed" into sticky [_error] and keep it after · live.
      if (runtime.reconnecting || !runtime.closed) {
        if (_error != null && isTransientBridgeErrorText(_error!)) {
          _error = null;
        }
        if (runtime.lastError != null &&
            isTransientBridgeErrorText(runtime.lastError!)) {
          runtime.lastError = null;
        }
      } else if (runtime.lastError != null &&
          !isTransientBridgeErrorText(runtime.lastError!)) {
        _error = runtime.lastError;
      }
      final n = runtime.entries.length;
      if (n != _messageCount) _messageCount = n;
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
  Future<AgentSession> Function() _buildSessionFactory({
    required String chatId,
    required String cwd,
  }) {
    final ssh = ref.read(sshServiceProvider);
    final secureStore = ref.read(secureStoreProvider);
    final db = ref.read(appDatabaseProvider);
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

      // tmux is required for ADSM workers.
      await ssh.ensureTmux(host, onProgress: status);

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

      await ssh.ensureAdsm(host, onProgress: status).timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw TimeoutException(
          'Timed out installing/starting ADSM on the remote.',
        ),
      );

      final mcps = await db.listEnabledMcpsForHost(host.id);
      final latest = await db.getChat(chatId);

      status('Starting agent via ADSM…');

      return AdsmSession.start(
        ssh: ssh,
        secureStore: secureStore,
        host: host,
        cwd: cwd,
        binary: binary,
        chatId: chatId,
        provider: provider,
        mcpServers: mcps.map((m) => m.toAcpConfig()).toList(),
        initialMode: mode,
        permissionPolicy: permission,
        resumeSessionId: latest?.acpSessionId,
        preferredModelId: latest?.modelId,
      ).timeout(
        const Duration(seconds: 90),
        onTimeout: () => throw TimeoutException(
          provider == AgentProvider.claude
              ? 'Connect timed out. Set ANTHROPIC_API_KEY in Connect or run '
                  '`claude login` on the remote, then Connect again.'
              : 'Connect timed out. Try `agent login` on the remote from Hosts → terminal, '
                  'then Connect again.',
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
        final isAdsm = e.tool.toUpperCase().contains('ADSM');
        final mismatch = e.installHint.toLowerCase().contains('adsm mismatch');
        setState(() {
          _showSdkInstallGuide = true;
          _error = isAdsm
              ? (mismatch
                  ? 'ADSM mismatch — cannot run until the host matches this app '
                      '(needs v$kRequiredAdsmVersion).\n'
                      'Agent Dock tried to update automatically. Leave this chat '
                      'and open it again to retry, or update ADSM on the remote.\n\n'
                      '${e.installHint}'
                  : 'Could not install ADSM on ${host.displayLabel}.\n'
                      'Agent Dock tried automatically — run the setup below on the '
                      'remote, then Connect again.\n\n'
                      '${e.tool} still missing.')
              : isClaude
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

    var runtime = _runtime ??
        ref.read(activeAcpSessionsProvider.notifier).get(widget.chatId);

    if (runtime != null && !runtime.closed) {
      await _prefetchModelCatalogIfNeeded(runtime);
      // Session events can land a tick after Connect — retry once if empty.
      if (runtime.availableModels.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
        await _prefetchModelCatalogIfNeeded(runtime);
      }
    }
    if (!mounted) return;

    runtime = _runtime ??
        ref.read(activeAcpSessionsProvider.notifier).get(widget.chatId);

    if ((runtime?.availableModels ?? const []).isEmpty) {
      final connected = runtime != null && !runtime.closed;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            connected
                ? 'No models from the agent yet. Wait for Connect to finish, then try again.'
                : 'Connect to the agent first — models load from the live session.',
          ),
        ),
      );
    }

    final chosen = await ModelPickerSheet.show(
      context,
      models: runtime?.availableModels ?? const [],
      selectedId: _selectedModel?.modelId,
      connected: runtime != null && !runtime.closed,
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

  Future<void> _pickImages() async {
    if (_chat == null || _pickingImages) return;
    final room = ChatImageCodec.maxImagesPerPrompt - _pendingImages.length;
    if (room <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'You can attach up to ${ChatImageCodec.maxImagesPerPrompt} images.',
          ),
        ),
      );
      return;
    }
    setState(() => _pickingImages = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        allowMultiple: true,
        withData: false,
      );
      if (result == null || result.files.isEmpty || !mounted) return;
      final added = <ChatImageRef>[];
      for (final f in result.files.take(room)) {
        final path = f.path;
        if (path == null) continue;
        try {
          added.add(
            await ChatImageCodec.storePickedFile(
              chatId: _chat!.id,
              sourcePath: path,
              fileName: f.name,
              byteLength: f.size > 0 ? f.size : null,
            ),
          );
        } catch (e) {
          SafeLog.d('store image failed', e);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$e')),
            );
          }
        }
      }
      if (!mounted || added.isEmpty) return;
      setState(() => _pendingImages.addAll(added));
    } catch (e) {
      SafeLog.d('pick images failed', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not pick images: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _pickingImages = false);
    }
  }

  void _removePendingImage(int index) {
    if (index < 0 || index >= _pendingImages.length) return;
    setState(() => _pendingImages.removeAt(index));
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.startsWith('/')) {
      await _handleSlashCommand(text);
      return;
    }
    final images = List<ChatImageRef>.from(_pendingImages);
    if ((text.isEmpty && images.isEmpty) || _chat == null) return;
    if (!_chat!.provider.isAvailable) return;

    // Composer stays usable while a turn runs — messages go on the outbound
    // queue. Only block the button briefly while we ensure the transport.
    _composer.clear();
    setState(() {
      _sending = true;
      _pendingImages.clear();
      _showSlashMenu = false;
    });
    try {
      await _ensureAcp();
      final runtime =
          ref.read(activeAcpSessionsProvider.notifier).get(_chat!.id);
      if (runtime == null || runtime.closed) {
        // Put the text / images back so the user does not lose them.
        _composer.text = text;
        if (mounted) {
          setState(() => _pendingImages
            ..clear()
            ..addAll(images));
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
      await runtime.enqueueOrPrompt(text, images: images);
      _scrollToEnd(force: true);
    } catch (e) {
      SafeLog.d('send failed', e);
      if (mounted) {
        _composer.text = text;
        setState(() {
          _pendingImages
            ..clear()
            ..addAll(images);
          _showSdkInstallGuide = false;
          // Bridge blips reconnect underneath — don't sticky-banner them.
          if (!isTransientBridgeError(e)) {
            _error = 'Send failed: $e';
          }
        });
        if (!isTransientBridgeError(e)) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Send failed: $e')),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _handleSlashCommand(String raw) async {
    final trimmed = raw.trim();
    final space = trimmed.indexOf(' ');
    final cmd = (space < 0 ? trimmed : trimmed.substring(0, space))
        .toLowerCase()
        .replaceFirst('/', '');
    final arg = space < 0 ? '' : trimmed.substring(space + 1).trim();

    _composer.clear();
    setState(() => _showSlashMenu = false);

    if (cmd == 'compress' || cmd.startsWith('comp')) {
      await _runCompress();
      return;
    }
    if (cmd == 'schedule' || cmd.startsWith('sched')) {
      final q = <String, String>{
        'chatId': widget.chatId,
        if (arg.isNotEmpty) 'prompt': arg,
        'useCtx': '1',
      };
      final uri = Uri(path: '/automate/new', queryParameters: q);
      if (mounted) context.push(uri.toString());
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unknown command /$cmd — try /compress or /schedule')),
      );
    }
  }

  Future<void> _runCompress() async {
    if (_chat == null || _compressing) return;
    setState(() => _compressing = true);
    try {
      await _ensureAcp();
      final runtime =
          ref.read(activeAcpSessionsProvider.notifier).get(_chat!.id);
      if (runtime == null || runtime.closed) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connect the agent before /compress.'),
            ),
          );
        }
        return;
      }
      _bindRuntime(runtime);
      const compressPrompt =
          'Summarize this conversation for a future agent that will continue '
          'the work. Include goals, decisions, open tasks, key file paths, '
          'and constraints. Be concise but complete. Reply with only the summary.';
      await runtime.prompt(compressPrompt);
      String? summary;
      for (var i = runtime.entries.length - 1; i >= 0; i--) {
        final m = runtime.entries[i].message;
        if (m != null && m.role == MessageRole.assistant) {
          summary = m.content.trim();
          break;
        }
      }
      if (summary == null || summary.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Compress produced no summary.')),
          );
        }
        return;
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('compressed_ctx_${widget.chatId}', summary);
      if (mounted) {
        final preview =
            summary.length > 100 ? '${summary.substring(0, 100)}…' : summary;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Compressed context saved: $preview')),
        );
      }
    } catch (e) {
      SafeLog.d('compress failed', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Compress failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _compressing = false);
    }
  }

  void _pickSlashCommand(String cmd) {
    if (cmd == 'compress') {
      _composer.text = '/compress';
      unawaited(_handleSlashCommand('/compress'));
      return;
    }
    if (cmd == 'schedule') {
      _composer.text = '/schedule ';
      _composer.selection = const TextSelection.collapsed(offset: 10);
      setState(() {
        _composerHasText = true;
        _showSlashMenu = false;
      });
    }
  }

  Widget _buildSlashMenu(ThemeData theme) {
    final filter = _composer.text.trimLeft().replaceFirst('/', '').toLowerCase();
    final matches = _slashCommands
        .where((c) => filter.isEmpty || c.cmd.startsWith(filter))
        .toList();
    if (matches.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surfaceContainerHighest,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in matches)
              ListTile(
                dense: true,
                leading: Icon(
                  c.cmd == 'compress' ? Icons.compress : Icons.schedule,
                  size: 20,
                ),
                title: Text('/${c.cmd}'),
                subtitle: Text(c.hint),
                onTap: () => _pickSlashCommand(c.cmd),
              ),
          ],
        ),
      ),
    );
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
        if ((_scroll.position.pixels - max).abs() > 1) {
          _programmaticScroll = true;
          _scroll.jumpTo(max);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _programmaticScroll = false;
          });
        }
      }
      if (framesLeft > 1) {
        _landAtBottom(framesLeft: framesLeft - 1);
      } else {
        _landedAtBottom = true;
        _followOutput = true;
        if (mounted && _showJumpToLatest) {
          setState(() => _showJumpToLatest = false);
        }
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
    if (force) _followOutput = true;
    if (!force && (!_landedAtBottom || !_followOutput)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      // Re-check: user may have scrolled away since this was scheduled.
      if (!force && !_followOutput) return;
      final max = _scroll.position.maxScrollExtent;
      if ((_scroll.position.pixels - max).abs() < 1) return;
      _programmaticScroll = true;
      // jumpTo (not animateTo): streaming fires many times per second and
      // stacked animations lock the user out of manual scrolling.
      _scroll.jumpTo(max);
      if (mounted && _showJumpToLatest) {
        setState(() => _showJumpToLatest = false);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _programmaticScroll = false;
      });
    });
  }

  static const _compressMessageThreshold = 3000;

  bool get _shouldSuggestCompress =>
      !_dismissCompressHint && _messageCount >= _compressMessageThreshold;

  Future<void> _renameChat() async {
    final chat = _chat;
    if (chat == null) return;
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
    if (next == null || next.isEmpty || next == chat.title || !mounted) return;
    final updated = chat.copyWith(title: next, updatedAt: DateTime.now());
    await ref.read(appDatabaseProvider).upsertChat(updated);
    ref.read(agentDockServiceProvider).schedulePushChat(chat.id);
    final runtime =
        ref.read(activeAcpSessionsProvider.notifier).get(chat.id);
    if (runtime != null) runtime.chatMeta = updated;
    ref.read(chatActivityTickProvider.notifier).state++;
    if (mounted) setState(() => _chat = updated);
  }

  /// Wipe phone transcript + remote ACP session so the next Connect is a fresh
  /// conversation (new session/new under the same agent row).
  Future<void> _startFreshConversation() async {
    final chat = _chat;
    final host = _host;
    if (chat == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start fresh conversation?'),
        content: const Text(
          'Clears this chat’s messages on the phone and restarts the remote '
          'agent session so context is reset.\n\n'
          'The agent row stays — same folder and provider. Old transcript is '
          'removed (not archived).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Start fresh'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final sessions = ref.read(activeAcpSessionsProvider.notifier);
    await sessions.close(chat.id);

    if (host != null) {
      try {
        await ref.read(agentRuntimeHostProvider).stop(host, chat.id);
      } catch (e) {
        SafeLog.d('stop remote for fresh chat failed', e);
      }
    }

    final db = ref.read(appDatabaseProvider);
    await db.clearMessages(chat.id);
    await db.setOutboundQueue(chat.id, const []);
    final updated = chat.copyWith(
      clearTmuxSession: true,
      clearAcpSessionId: true,
      journalOffset: 0,
      status: ChatStatus.idle,
      updatedAt: DateTime.now(),
      clearLastAutoNumber: true,
      clearCodeDelta: true,
      lastReadAt: DateTime.now(),
    );
    await db.upsertChat(updated);
    ref.read(agentDockServiceProvider).schedulePushChat(chat.id);
    ref.read(chatActivityTickProvider.notifier).state++;

    if (!mounted) return;
    setState(() {
      _chat = updated;
      _dbEntries.clear();
      _messageCount = 0;
      _dismissCompressHint = true;
      _runtime = null;
      _error = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Fresh conversation ready — tap Connect to start.'),
      ),
    );
  }

  @override
  void dispose() {
    // Keep remote ACP alive — only detach UI listener.
    if (_runtimeListener != null && _runtime != null) {
      _runtime!.removeListener(_runtimeListener!);
    }
    if (ref.read(focusedChatIdProvider) == widget.chatId) {
      ref.read(focusedChatIdProvider.notifier).state = null;
    }
    _markReadTimer?.cancel();
    _voiceTick?.cancel();
    _voicePulse.dispose();
    _scroll.removeListener(_onScrollOffsetChanged);
    _composer.removeListener(_onComposerChanged);
    if (_recordingVoice) {
      unawaited(ref.read(gcpSpeechServiceProvider).cancel());
    }
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _startVoiceHold() async {
    if (_sending ||
        _connecting ||
        _recordingVoice ||
        _voiceStarting ||
        !_chat!.provider.isAvailable) {
      return;
    }
    // New recording abandons any in-flight transcription.
    if (_transcribingVoice) {
      _transcribeEpoch++;
      setState(() => _transcribingVoice = false);
    }
    final speech = ref.read(gcpSpeechServiceProvider);
    final available = await speech.isAvailable();
    if (!mounted) return;
    if (!available) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Speech recognition unavailable — enable mic + speech permissions.',
          ),
        ),
      );
      return;
    }

    _voiceStarting = true;
    _voiceReleasePending = false;
    _voiceCancelPending = false;
    try {
      await speech.start();
      if (!mounted) {
        await speech.cancel();
        return;
      }
      if (_voiceCancelPending) {
        await speech.cancel();
        _voiceCancelPending = false;
        _voiceReleasePending = false;
        return;
      }
      HapticFeedback.mediumImpact();
      _voiceTick?.cancel();
      setState(() {
        _recordingVoice = true;
        _voiceLocked = false;
        _voiceCancelArmed = false;
        _voiceLockArmed = false;
        _voiceDragDx = 0;
        _voiceDragDy = 0;
        _voiceStartedAt = DateTime.now();
        _voiceElapsedSec = 0;
      });
      unawaited(_voicePulse.repeat(reverse: true));
      _voiceTick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _voiceStartedAt == null) return;
        setState(() {
          _voiceElapsedSec =
              DateTime.now().difference(_voiceStartedAt!).inSeconds;
        });
      });
      if (_voiceReleasePending) {
        _voiceReleasePending = false;
        await _onVoicePointerUp();
      }
    } catch (e) {
      SafeLog.d('voice start failed', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Mic failed: ${GcpSpeechService.userFacingMessage(e)}',
            ),
          ),
        );
      }
    } finally {
      _voiceStarting = false;
    }
  }

  void _onVoiceDragUpdate(Offset delta) {
    if (!_recordingVoice || _voiceLocked) return;
    setState(() {
      _voiceDragDx = (_voiceDragDx + delta.dx).clamp(-160.0, 24.0);
      _voiceDragDy = (_voiceDragDy + delta.dy).clamp(-120.0, 24.0);
      final cancel = _voiceDragDx <= _voiceCancelThreshold;
      final lock = !cancel && _voiceDragDy <= _voiceLockThreshold;
      if (cancel != _voiceCancelArmed) {
        HapticFeedback.selectionClick();
      } else if (lock != _voiceLockArmed) {
        HapticFeedback.selectionClick();
      }
      _voiceCancelArmed = cancel;
      _voiceLockArmed = lock;
    });
  }

  Future<void> _onVoicePointerUp() async {
    if (_voiceStarting && !_recordingVoice) {
      _voiceReleasePending = true;
      if (_voiceCancelArmed) _voiceCancelPending = true;
      return;
    }
    if (!_recordingVoice) return;
    if (_voiceCancelArmed) {
      await _cancelVoiceRecord();
      return;
    }
    if (_voiceLockArmed || _voiceLocked) {
      if (!_voiceLocked) {
        HapticFeedback.lightImpact();
        setState(() {
          _voiceLocked = true;
          _voiceLockArmed = false;
          _voiceCancelArmed = false;
          _voiceDragDx = 0;
          _voiceDragDy = 0;
        });
      }
      return;
    }
    await _finishVoiceRecord();
  }

  Future<void> _cancelVoiceRecord() async {
    if (!_recordingVoice) return;
    final speech = ref.read(gcpSpeechServiceProvider);
    _voiceTick?.cancel();
    _voicePulse.stop();
    _voicePulse.value = 0;
    setState(() {
      _recordingVoice = false;
      _voiceLocked = false;
      _voiceCancelArmed = false;
      _voiceLockArmed = false;
      _voiceDragDx = 0;
      _voiceDragDy = 0;
      _voiceStartedAt = null;
      _voiceElapsedSec = 0;
    });
    HapticFeedback.heavyImpact();
    try {
      await speech.cancel();
    } catch (e) {
      SafeLog.d('voice cancel failed', e);
    }
  }

  Future<void> _finishVoiceRecord() async {
    if (!_recordingVoice || _transcribingVoice) return;
    final speech = ref.read(gcpSpeechServiceProvider);
    _voiceTick?.cancel();
    _voicePulse.stop();
    _voicePulse.value = 0;
    final epoch = ++_transcribeEpoch;
    final baseline = _composer.text;
    setState(() {
      _recordingVoice = false;
      _voiceLocked = false;
      _voiceCancelArmed = false;
      _voiceLockArmed = false;
      _voiceDragDx = 0;
      _voiceDragDy = 0;
      _voiceStartedAt = null;
      _transcribingVoice = true;
    });
    HapticFeedback.lightImpact();
    try {
      final text = await speech.stopAndTranscribe().timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw TimeoutException('Speech-to-text timed out'),
      );
      if (!mounted || epoch != _transcribeEpoch) return;
      // User typed while we waited — their text wins; drop the transcript.
      if (_composer.text != baseline) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Kept your typed text (skipped late transcript).'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
      if (text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No speech detected — try again.')),
        );
      } else {
        _composer.text =
            baseline.trim().isEmpty ? text : '${baseline.trim()} $text';
        _composer.selection = TextSelection.collapsed(
          offset: _composer.text.length,
        );
      }
    } on TimeoutException {
      SafeLog.d('voice transcribe timed out (>3s)');
      if (mounted && epoch == _transcribeEpoch) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Transcription took too long — type your message instead.',
            ),
          ),
        );
      }
    } catch (e) {
      SafeLog.d('voice transcribe failed', e);
      if (mounted && epoch == _transcribeEpoch) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(GcpSpeechService.userFacingMessage(e))),
        );
      }
    } finally {
      if (mounted && epoch == _transcribeEpoch) {
        setState(() {
          _transcribingVoice = false;
          _voiceElapsedSec = 0;
        });
      }
    }
  }

  String _fmtVoiceElapsed(int sec) {
    final m = sec ~/ 60;
    final s = sec % 60;
    return '${m.toString().padLeft(1, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _buildVoiceHintBar(ThemeData theme) {
    if (_transcribingVoice) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Finishing speech…',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    if (!_recordingVoice) return const SizedBox.shrink();

    final cancel = _voiceCancelArmed;
    final locked = _voiceLocked;
    final lockHint = _voiceLockArmed && !locked;
    final label = cancel
        ? 'Release to cancel'
        : locked
            ? 'Locked — tap stop when done'
            : lockHint
                ? 'Release to lock'
                : 'Slide left to cancel · up to lock';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _voicePulse,
            builder: (context, child) {
              final t = _voicePulse.value;
              return Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (cancel ? theme.colorScheme.error : Colors.red)
                      .withValues(alpha: 0.45 + 0.55 * t),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.red.withValues(alpha: 0.25 + 0.35 * t),
                      blurRadius: 6 + 8 * t,
                      spreadRadius: 1 + 2 * t,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          Text(
            _fmtVoiceElapsed(_voiceElapsedSec),
            style: theme.textTheme.labelLarge?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: cancel
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!locked && !cancel)
            Opacity(
              opacity: (_voiceDragDx / _voiceCancelThreshold).clamp(0.0, 1.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chevron_left,
                    size: 18,
                    color: theme.colorScheme.error,
                  ),
                  Text(
                    'Cancel',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
              ),
            ),
          if (lockHint || locked)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(
                Icons.lock,
                size: 16,
                color: theme.colorScheme.primary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSendOrMicButton({
    required ThemeData theme,
    required bool streaming,
  }) {
    final busy = _connecting || _sending || _compressing;
    final showSend = !_recordingVoice &&
        (_composerHasText || _pendingImages.isNotEmpty);

    if (showSend) {
      return IconButton.filled(
        tooltip: streaming ? 'Queue message' : 'Send',
        onPressed: busy || !_chat!.provider.isAvailable
            ? null
            : () => unawaited(_send()),
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(streaming ? Icons.playlist_add : Icons.send),
      );
    }

    // Locked hands-free recording — tap stop to finish (Telegram lock).
    if (_voiceLocked && _recordingVoice) {
      return IconButton.filled(
        tooltip: 'Stop & transcribe',
        onPressed: busy ? null : () => unawaited(_finishVoiceRecord()),
        style: IconButton.styleFrom(
          backgroundColor: theme.colorScheme.primary,
        ),
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.stop_rounded),
      );
    }

    // Telegram-style hold-to-record mic.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: busy || !_chat!.provider.isAvailable
          ? null
          : (_) => unawaited(_startVoiceHold()),
      onPointerMove:
          !_recordingVoice ? null : (e) => _onVoiceDragUpdate(e.delta),
      onPointerUp:
          !_recordingVoice ? null : (_) => unawaited(_onVoicePointerUp()),
      onPointerCancel:
          !_recordingVoice ? null : (_) => unawaited(_onVoicePointerUp()),
      child: AnimatedBuilder(
        animation: _voicePulse,
        builder: (context, _) {
          final pulse = _recordingVoice ? _voicePulse.value : 0.0;
          final cancel = _voiceCancelArmed;
          final bg = cancel
              ? theme.colorScheme.error
              : _recordingVoice
                  ? Color.lerp(
                      theme.colorScheme.error,
                      const Color(0xFFE53935),
                      pulse,
                    )!
                  : theme.colorScheme.primary;
          final scale = _recordingVoice ? 1.0 + 0.14 * pulse : 1.0;

          return Transform.translate(
            offset: _recordingVoice
                ? Offset(_voiceDragDx * 0.35, _voiceDragDy * 0.25)
                : Offset.zero,
            child: Transform.scale(
              scale: scale,
              child: SizedBox(
                width: 56,
                height: 56,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    if (_recordingVoice)
                      ...List.generate(2, (i) {
                        final t = (pulse + i * 0.45) % 1.0;
                        final ring = 34.0 + 24.0 * t;
                        return Container(
                          width: ring,
                          height: ring,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: (cancel
                                      ? theme.colorScheme.error
                                      : Colors.red)
                                  .withValues(alpha: (1 - t) * 0.55),
                              width: 2,
                            ),
                          ),
                        );
                      }),
                    Material(
                      color: bg,
                      shape: const CircleBorder(),
                      elevation: _recordingVoice ? 4 + 6 * pulse : 1,
                      shadowColor: Colors.red.withValues(alpha: 0.55),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(
                          cancel ? Icons.delete_outline : Icons.mic,
                          color: _recordingVoice || cancel
                              ? theme.colorScheme.onError
                              : theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                    if (_recordingVoice && !_voiceCancelArmed)
                      Positioned(
                        top: -30,
                        child: Opacity(
                          opacity: (-_voiceDragDy / 56).clamp(0.0, 1.0),
                          child: Icon(
                            Icons.lock_outline,
                            size: 18,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
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
    final guide = (_error ?? '').toUpperCase().contains('ADSM')
        ? kRemoteAdsmSetupGuide
        : _chat!.provider == AgentProvider.claude
            ? kRemoteClaudeSetupGuide
            : kRemoteCursorSetupGuide;

    final runtime = _runtime;
    final adsmSession = runtime?.session is AdsmSession
        ? runtime!.session as AdsmSession
        : null;
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
    // System thoughts are folded into assistant bubbles by [_blocksFor].
    final entries = _entriesByTime(filtered);
    final blocks = _blocksFor(entries);
    final thoughtBuffer = runtime?.thoughtBuffer ?? '';
    final assistantBuffer = runtime?.assistantBuffer ?? '';
    // Composer no longer locks for the whole turn — only the live buffer
    // counts as "working" for the agent bubble.
    final streaming = runtime?.isWorking ?? false;
    final liveError = runtime?.lastError;
    final deliveryError = runtime?.deliveryError;
    final displayError = _error ?? liveError ?? deliveryError;
    final connected = runtime != null && !runtime.closed;
    final reconnecting = runtime?.reconnecting ?? false;
    final remoteRunning = runtime?.remoteTurnActive == true;
    final sending = runtime?.sendingToHost == true;
    final activeToolEntries = runtime == null
        ? const <ToolCallState>[]
        : [
            for (final e in runtime.entries)
              if (e.tool?.isActive ?? false) e.tool!,
          ];
    final activeTools = activeToolEntries.length;
    final activityLabel = runtime?.activityLabel;
    final statusLabel = switch (true) {
      _ when reconnecting => ' · reconnecting…',
      _ when remoteRunning && !connected => ' · running on host',
      _ when sending =>
        ' · ${activityLabel?.isNotEmpty == true ? activityLabel! : 'Sending to host…'}',
      _ when streaming && activityLabel != null && activityLabel.isNotEmpty =>
        ' · $activityLabel',
      _ when streaming && activeTools == 1 =>
        ' · working · ${activeToolEntries.first.displayTitle}',
      _ when streaming && activeTools > 1 =>
        ' · working · $activeTools tools',
      _ when streaming => ' · Thinking',
      _ when connected && _resumedInPlace => ' · live · resumed',
      _ when connected => ' · live',
      _ => '',
    };

    final extra = <Widget>[];
    // Keep live text visible even if isWorking cleared a tick before flush —
    // that race used to make the answer vanish until reopen.
    if (thoughtBuffer.isNotEmpty || assistantBuffer.isNotEmpty) {
      if (thoughtBuffer.isNotEmpty) {
        extra.add(
          _ThinkingFold(
            text: thoughtBuffer,
            streaming: true,
            initiallyExpanded: true,
          ),
        );
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
        title: InkWell(
          onTap: _renameChat,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        _chat!.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.edit_outlined,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                Text(
                  '${_repo?.name ?? ''} · ${_chat!.provider.label}$statusLabel',
                  style: theme.textTheme.bodySmall,
                ),
                if (() {
                  final d = CodeChangeStats.mergeDisplay(
                    live: runtime?.codeDelta,
                    persistedAdded: _chat!.linesAdded,
                    persistedRemoved: _chat!.linesRemoved,
                    persistedFiles: _chat!.filesChanged,
                  );
                  return d.added > 0 || d.removed > 0 || d.files > 0;
                }())
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Builder(
                      builder: (context) {
                        final d = CodeChangeStats.mergeDisplay(
                          live: runtime?.codeDelta,
                          persistedAdded: _chat!.linesAdded,
                          persistedRemoved: _chat!.linesRemoved,
                          persistedFiles: _chat!.filesChanged,
                        );
                        return CodeDeltaLabel(
                          added: d.added,
                          removed: d.removed,
                          files: d.files,
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
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
              tooltip: adsmSession != null
                  ? 'ADSM host status'
                  : connected
                      ? 'Agent live — keeps running on the host if you disconnect'
                      : 'Reconnect ACP',
              onPressed: _connecting
                  ? null
                  : () {
                      if (adsmSession != null) {
                        unawaited(
                          AdsmHealthSheet.show(
                            context,
                            session: adsmSession,
                            bridgeOpen: connected,
                            onReconnect: connected ? null : _ensureAcp,
                          ),
                        );
                      } else {
                        unawaited(_ensureAcp());
                      }
                    },
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
                                  runtime?.deliveryError = null;
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
                          runtime?.deliveryError = null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                NotificationListener<UserScrollNotification>(
                  onNotification: (notification) {
                    if (_programmaticScroll || !_landedAtBottom) return false;
                    // reverse = toward older messages (top); stop auto-follow.
                    if (notification.direction == ScrollDirection.reverse) {
                      if (_followOutput) {
                        _followOutput = false;
                        if (!_showJumpToLatest && mounted) {
                          setState(() => _showJumpToLatest = true);
                        }
                      }
                    } else if (notification.direction ==
                            ScrollDirection.forward &&
                        _isNearBottom) {
                      if (!_followOutput) {
                        _followOutput = true;
                        if (_showJumpToLatest && mounted) {
                          setState(() => _showJumpToLatest = false);
                        }
                      }
                    }
                    return false;
                  },
                  child: ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  // Keep scroll physics interactive even while the agent streams.
                  physics: const AlwaysScrollableScrollPhysics(),
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
                    if (block.thinkingOnly != null) {
                      body = _ThinkingFold(text: block.thinkingOnly!);
                    } else if (tools != null) {
                      body = ToolCallGroupCard(
                        tools: [for (final e in tools) e.tool!],
                      );
                    } else if (block.entry!.tool != null) {
                      body = ToolCallCard(tool: block.entry!.tool!);
                    } else {
                      final m = block.entry!.message!;
                      final bubble = _Bubble(
                        role: m.role,
                        text: m.content,
                        at: m.createdAt,
                      );
                      final thinking = block.thinking;
                      if (thinking != null && thinking.isNotEmpty) {
                        body = Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _ThinkingFold(text: thinking),
                            bubble,
                          ],
                        );
                      } else {
                        body = bubble;
                      }
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
                if (_showJumpToLatest)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 12,
                    child: Center(
                      child: Material(
                        elevation: 3,
                        color: theme.colorScheme.primaryContainer,
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: 'Jump to latest',
                          onPressed: () => _scrollToEnd(force: true),
                          icon: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_shouldSuggestCompress)
            Material(
              color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.55),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.compress,
                      size: 18,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Chat is getting large ($_messageCount messages). '
                        'Start fresh to reset agent context.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => unawaited(_startFreshConversation()),
                      child: const Text('Fresh'),
                    ),
                    IconButton(
                      tooltip: 'Dismiss',
                      onPressed: () =>
                          setState(() => _dismissCompressHint = true),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Shimmer(
                        child: Builder(
                          builder: (context) {
                            final explore = runtime?.turnExploreStats;
                            final style =
                                theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            );
                            if (explore != null && explore.isNotEmpty) {
                              return ExploreStatsLabel(
                                files: explore.fileCount,
                                searches: explore.searchCount,
                                style: style,
                                showEllipsis: true,
                              );
                            }
                            final label = sending
                                ? (activityLabel?.isNotEmpty == true
                                    ? activityLabel!
                                    : 'Sending to host…')
                                : (activityLabel != null &&
                                        activityLabel.isNotEmpty)
                                    ? activityLabel
                                    : activeTools == 1
                                        ? activeToolEntries.first.displayTitle
                                        : activeTools > 1
                                            ? 'Working · $activeTools tools'
                                            : 'Thinking';
                            final text =
                                label.endsWith('…') || label.endsWith('...')
                                    ? label
                                    : '$label…';
                            return Text(text, style: style);
                          },
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final rt = _runtime ??
                            ref
                                .read(activeAcpSessionsProvider.notifier)
                                .get(widget.chatId);
                        if (rt == null) return;
                        try {
                          await rt.unstick();
                        } catch (e) {
                          SafeLog.d('stop turn failed', e);
                        }
                        if (mounted) setState(() {});
                      },
                      child: const Text('Stop'),
                    ),
                  ],
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_recordingVoice || _transcribingVoice)
                    _buildVoiceHintBar(theme),
                  if (_pendingImages.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SizedBox(
                        height: 72,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _pendingImages.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final img = _pendingImages[i];
                            final path = img.absolutePath;
                            return Stack(
                              clipBehavior: Clip.none,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: path == null
                                      ? Container(
                                          width: 72,
                                          height: 72,
                                          color: theme.colorScheme
                                              .surfaceContainerHighest,
                                          child: const Icon(Icons.image),
                                        )
                                      : Image.file(
                                          File(path),
                                          width: 72,
                                          height: 72,
                                          fit: BoxFit.cover,
                                        ),
                                ),
                                Positioned(
                                  top: -6,
                                  right: -6,
                                  child: IconButton.filledTonal(
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 28,
                                      minHeight: 28,
                                    ),
                                    onPressed: () => _removePendingImage(i),
                                    icon: const Icon(Icons.close, size: 14),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Attach image',
                        onPressed: _connecting ||
                                _pickingImages ||
                                !_chat!.provider.isAvailable
                            ? null
                            : () => unawaited(_pickImages()),
                        icon: _pickingImages
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.add_photo_alternate_outlined),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_showSlashMenu) _buildSlashMenu(theme),
                            TextField(
                              controller: _composer,
                              minLines: 1,
                              maxLines: 5,
                              enabled:
                                  _chat!.provider.isAvailable && !_connecting,
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
                                if (!_sending && !_compressing) {
                                  unawaited(_send());
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildSendOrMicButton(
                        theme: theme,
                        streaming: streaming,
                      ),
                    ],
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

/// One paint unit in the transcript list: a message, a lone tool, a
/// collapsed run of consecutive tools, or a standalone thinking fold.
class _ChatBlock {
  const _ChatBlock._({
    this.entry,
    this.tools,
    this.thinking,
    this.thinkingOnly,
  });

  factory _ChatBlock.single(TranscriptEntry entry, {String? thinking}) =>
      _ChatBlock._(entry: entry, thinking: thinking);

  factory _ChatBlock.tools(List<TranscriptEntry> tools) =>
      _ChatBlock._(tools: tools);

  factory _ChatBlock.thinking(String text) =>
      _ChatBlock._(thinkingOnly: text);

  final TranscriptEntry? entry;
  final List<TranscriptEntry>? tools;

  /// Reasoning attached above an assistant [entry].
  final String? thinking;

  /// Standalone thinking row (no assistant text yet / orphan).
  final String? thinkingOnly;

  DateTime? get createdAt =>
      tools?.first.createdAt ?? entry?.createdAt;
}

/// Collapsible agent reasoning — collapsed by default after the turn ends.
class _ThinkingFold extends StatefulWidget {
  const _ThinkingFold({
    required this.text,
    this.streaming = false,
    this.initiallyExpanded = false,
  });

  final String text;
  final bool streaming;
  final bool initiallyExpanded;

  @override
  State<_ThinkingFold> createState() => _ThinkingFoldState();
}

class _ThinkingFoldState extends State<_ThinkingFold> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant _ThinkingFold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.streaming && !oldWidget.streaming) {
      _expanded = true;
    }
    if (!widget.streaming && oldWidget.streaming) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelColor = theme.colorScheme.onSurface.withValues(alpha: 0.72);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.88,
          ),
          child: Material(
            color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.psychology_alt_outlined,
                          size: 16,
                          color: labelColor,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Shimmer(
                            enabled: widget.streaming,
                            child: Text(
                              widget.streaming ? 'Thinking…' : 'Thinking',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: labelColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        Icon(
                          _expanded
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                          color: labelColor,
                        ),
                      ],
                    ),
                    if (_expanded) ...[
                      const SizedBox(height: 8),
                      MessageBody(
                        text: widget.text,
                        dense: true,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
    final imageRefs =
        isUser ? ChatImageCodec.listRefs(text) : const <ChatImageRef>[];
    final stripped = ChatImageCodec.displayText(text);
    final autoNumber = isUser ? AutoRunTag.parseNumber(stripped) : null;
    final bodyText = isUser ? AutoRunTag.displayBody(stripped) : stripped;

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

    // Cursor-style: user = soft raised pill; agent = bare text on the canvas.
    final onText = isUser ? AppColors.onBubbleUser : AppColors.chatAgentText;
    final metaColor = AppColors.chatMeta;

    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: onText,
      height: 1.45,
      fontSize: 15,
    );

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isUser && streaming)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Shimmer(
              enabled: true,
              child: Text(
                'Thinking',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: metaColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        if (autoNumber != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: AutoNumberBadge(number: autoNumber, compact: false),
          ),
        if (queued)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.schedule, size: 14, color: metaColor),
                const SizedBox(width: 6),
                Text(
                  'Queued',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: metaColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        if (imageRefs.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(
              bottom: bodyText.trim().isEmpty ? 0 : 8,
            ),
            child: _BubbleImages(refs: imageRefs),
          ),
        if (streaming && bodyText.isEmpty && imageRefs.isEmpty)
          MessageBody(text: '…', style: bodyStyle)
        else if (bodyText.isNotEmpty || (streaming && bodyText.isEmpty))
          MessageBody(
            text: streaming && bodyText.isEmpty ? '…' : bodyText,
            style: bodyStyle,
          ),
        if (!streaming && (at != null || bodyText.trim().isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!queued && bodyText.trim().isNotEmpty) ...[
                  IconButton(
                    tooltip: 'Copy text for Teams',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () => copyMessageForTeams(context, bodyText),
                    icon: Icon(
                      Icons.copy_rounded,
                      size: 14,
                      color: metaColor.withValues(alpha: 0.85),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy HTML for Teams',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () =>
                        copyMessageHtmlForTeams(context, bodyText),
                    icon: Icon(
                      Icons.html,
                      size: 15,
                      color: metaColor.withValues(alpha: 0.85),
                    ),
                  ),
                ],
                if (at != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      _formatClock(at!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: metaColor,
                        fontWeight: FontWeight.w500,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );

    if (isUser) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 10, bottom: 6),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          decoration: BoxDecoration(
            color: AppColors.bubbleUser,
            borderRadius: BorderRadius.circular(14),
            border: queued
                ? Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.45),
                  )
                : null,
          ),
          child: column,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 10),
      child: column,
    );
  }
}

class _BubbleImages extends StatefulWidget {
  const _BubbleImages({required this.refs});

  final List<ChatImageRef> refs;

  @override
  State<_BubbleImages> createState() => _BubbleImagesState();
}

class _BubbleImagesState extends State<_BubbleImages> {
  List<String?> _paths = const [];

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _BubbleImages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.refs, widget.refs)) _resolve();
  }

  Future<void> _resolve() async {
    final docs = await getApplicationDocumentsDirectory();
    if (!mounted) return;
    setState(() {
      _paths = [
        for (final r in widget.refs)
          r.absolutePath ?? p.join(docs.path, r.relativePath),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.refs.isEmpty) return const SizedBox.shrink();
    final paths = _paths.length == widget.refs.length
        ? _paths
        : List<String?>.filled(widget.refs.length, null);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < widget.refs.length; i++)
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: paths[i] == null
                ? Container(
                    width: 120,
                    height: 120,
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    child: const Icon(Icons.image_outlined),
                  )
                : Image.file(
                    File(paths[i]!),
                    width: 140,
                    height: 140,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 120,
                      height: 120,
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHigh,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
          ),
      ],
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
