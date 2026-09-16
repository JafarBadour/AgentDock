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
import '../../app/platform_layout.dart';
import '../../app/providers.dart';
import '../../data/models/agent_mode.dart';
import '../../data/models/agent_model.dart';
import '../../data/models/agent_provider.dart';
import '../../data/models/chat.dart';
import '../../data/models/chat_message.dart';
import '../../data/models/host.dart';
import '../../data/models/prompt_image.dart';
import '../../data/models/repo.dart';
import '../../data/models/scheduled_job.dart';
import '../../data/models/tool_call_state.dart';
import '../../data/secure/safe_log.dart';
import '../../services/adsm_client.dart';
import '../../services/agent_session.dart';
import '../../services/chat_session_runtime.dart';
import '../../services/claude_remote_auth.dart';
import '../../services/cursor_acp_service.dart';
import '../../services/gcp_speech_service.dart';
import '../../services/ssh_service.dart';
import 'agent_setup_guide.dart';
import 'agent_status_indicators.dart';
import '../connect/claude_login_sheet.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'message_body.dart';
import 'model_picker_sheet.dart';
import 'project_files_screen.dart';
import 'tool_call_card.dart';
import 'transcript_blocks.dart';
import 'transcript_window.dart';

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
  /// Avoid looping ClaudeLoginSheet when the same auth error stays sticky.
  bool _authReauthPrompted = false;
  bool _authReauthInFlight = false;

  /// True when the last connect attached to an agent that was still running,
  /// so the conversation carried over untouched.
  bool _resumedInPlace = false;

  AgentSessionMode _mode = AgentSessionMode.agent;
  PermissionPolicy _permission = PermissionPolicy.allowAll;

  ChatSessionRuntime? _runtime;
  VoidCallback? _runtimeListener;
  Future<void>? _ensureAcpInFlight;
  int _connectEpoch = 0;
  Timer? _markReadTimer;
  Timer? _runtimeUiCoalesce;
  bool _runtimeUiDirty = false;
  bool _wasWorking = false;
  int _lastOutboundQueueLen = 0;
  bool _landedAtBottom = false;
  /// Jump-to-latest FAB — ValueNotifier so toggling it never setStates the
  /// whole chat (that used to re-run build() on every scroll threshold cross).
  final ValueNotifier<bool> _showJumpToLatest = ValueNotifier(false);
  /// When true, keep the viewport pinned to new agent output.
  /// Cleared as soon as the user scrolls away from the bottom.
  bool _followOutput = true;
  bool _programmaticScroll = false;
  int _messageCount = 0;
  final List<ChatImageRef> _pendingImages = [];
  bool _pickingImages = false;
  bool _composerHasText = false;
  bool _recordingVoice = false;
  bool _transcribingVoice = false;
  /// Bumped when a new transcription starts or is abandoned so late results drop.
  int _transcribeEpoch = 0;
  bool _showSlashMenu = false;
  bool _compressing = false;
  /// Sliding window over the transcript: mount a page, grow upward, trim
  /// older pages when scrolling back to the live end.
  final TranscriptWindow _transcriptWindow = TranscriptWindow(
    pageSize: 300,
    softMax: 370,
  );
  List<ChatBlock>? _cachedBlocks;
  String? _blocksCacheKey;
  DateTime? _lastScrollToEndAt;
  double _lastScrollMaxExtent = 0;

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

  void _syncComposerDraft([String? text]) {
    ref
        .read(chatComposerDraftsProvider.notifier)
        .setDraft(widget.chatId, text ?? _composer.text);
  }

  @override
  void initState() {
    super.initState();
    _voicePulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _composer.addListener(_onComposerChanged);
    final saved = ref.read(chatComposerDraftsProvider)[widget.chatId];
    if (saved != null && saved.isNotEmpty) {
      _composer.text = saved;
      _composerHasText = saved.trim().isNotEmpty;
      _showSlashMenu = saved.startsWith('/') &&
          !saved.contains('\n') &&
          !saved.contains(' ');
    }
    // No ScrollController listener — it fired on every pixel and setState'd the
    // whole chat. Follow / jump-to-latest uses UserScrollNotification only.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(focusedChatIdProvider.notifier).state = widget.chatId;
    });
    _bootstrap();
  }

  void _onComposerChanged() {
    final raw = _composer.text;
    _syncComposerDraft(raw);
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

  void _setFollowOutput(bool follow) {
    _followOutput = follow;
    _transcriptWindow.pinnedToEnd = follow;
    final showJump = !follow;
    if (_showJumpToLatest.value != showJump) {
      _showJumpToLatest.value = showJump;
    }
  }

  bool get _shiftingWindow => _loadingOlderHistory;
  bool _loadingOlderHistory = false;
  int _blocksLength = 0;

  void _syncWindowToBlocks(int total) {
    _blocksLength = total;
    _transcriptWindow.sync(total, followOutput: _followOutput);
  }

  /// Grow the mounted transcript toward older history (top edge or tap).
  void _maybeLoadOlderHistory({bool fromUserTap = false}) {
    if (!mounted) return;
    if (_loadingOlderHistory || _programmaticScroll) return;

    final hasScroll = _scroll.hasClients;
    final before = hasScroll ? _scroll.position.pixels : 0.0;
    final beforeMax = hasScroll ? _scroll.position.maxScrollExtent : 0.0;

    final int added;
    if (fromUserTap) {
      added = _transcriptWindow.loadOlder(
        _blocksLength,
        now: DateTime.now(),
        force: true,
      );
    } else {
      if (!hasScroll) return;
      final startBefore = _transcriptWindow.start;
      final ok = _transcriptWindow.tryLoadOlderAtTop(
        total: _blocksLength,
        pixels: before,
        maxScrollExtent: beforeMax,
        now: DateTime.now(),
        busy: false,
      );
      if (!ok) return;
      added = startBefore - _transcriptWindow.start;
    }
    if (added <= 0) return;

    _loadingOlderHistory = true;
    _programmaticScroll = true;
    _setFollowOutput(false);
    setState(() {}); // mount the newly prepended history slice

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        if (_scroll.hasClients) {
          final target = _transcriptWindow.preserveScrollAfterPrepend(
            beforePixels: before,
            beforeMax: beforeMax,
            afterMax: _scroll.position.maxScrollExtent,
          );
          _scroll.jumpTo(target);
        }
        if (!mounted || !fromUserTap) return;
        final label = added == 1
            ? 'Loaded 1 earlier message'
            : 'Loaded $added earlier messages';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(label),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } finally {
        _programmaticScroll = false;
        _loadingOlderHistory = false;
      }
    });
  }

  /// Drop older pages when scrolling back to the live end (past [softMax]).
  void _maybeTrimOlderHistory() {
    if (!mounted) return;
    if (_loadingOlderHistory || _programmaticScroll) return;
    if (!_scroll.hasClients) return;

    final before = _scroll.position.pixels;
    final beforeMax = _scroll.position.maxScrollExtent;
    final startBefore = _transcriptWindow.start;
    final ok = _transcriptWindow.tryTrimOlderNearBottom(
      total: _blocksLength,
      pixels: before,
      maxScrollExtent: beforeMax,
      now: DateTime.now(),
      busy: false,
    );
    if (!ok) return;
    final dropped = _transcriptWindow.start - startBefore;
    if (dropped <= 0) return;

    _loadingOlderHistory = true;
    _programmaticScroll = true;
    setState(() {});

    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        if (_scroll.hasClients) {
          final target = _transcriptWindow.preserveScrollAfterTrim(
            beforePixels: before,
            beforeMax: beforeMax,
            afterMax: _scroll.position.maxScrollExtent,
          );
          _scroll.jumpTo(target);
        }
      } finally {
        _programmaticScroll = false;
        _loadingOlderHistory = false;
      }
    });
  }

  void _pinWindowToLatest() {
    _transcriptWindow.pinToLatest(_blocksLength);
    _setFollowOutput(true);
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
    } else if (chat.provider.isAvailable) {
      // Connect as soon as the chat is selected — fire-and-forget so the
      // transcript stays interactive while SSH/ADSM comes up.
      unawaited(() async {
        final host = _host;
        if (host == null) return;
        if (!await ref
            .read(secureStoreProvider)
            .canAuthenticateToHost(host.id)) {
          return;
        }
        if (!mounted) return;
        await _ensureAcp();
      }());
    }

    unawaited(_syncFromRemote());
  }

  Future<void> _syncFromRemote() async {
    final host = _host;
    if (host == null) return;
    try {
      if (!await ref.read(secureStoreProvider).canAuthenticateToHost(host.id)) {
        return;
      }
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

  List<TranscriptEntry> _entriesFromMessages(List<ChatMessage> messages) =>
      entriesFromMessages(messages);

  List<ChatBlock> _blocksForMemoized(
    List<TranscriptEntry> entries, {
    bool openTurnActive = false,
  }) {
    final key = transcriptBlocksCacheKey(
      entries,
      openTurnActive: openTurnActive,
    );
    if (_cachedBlocks != null && _blocksCacheKey == key) {
      return _cachedBlocks!;
    }
    final blocks = buildTranscriptBlocks(
      entries,
      openTurnActive: openTurnActive,
    );
    _cachedBlocks = blocks;
    _blocksCacheKey = key;
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
    _wasWorking = runtime.isWorking;
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
      // Live output means the turn recovered — drop sticky banners so they
      // don't sit empty/red over the transcript.
      if (runtime.isWorking &&
          (runtime.assistantBuffer.isNotEmpty ||
              runtime.thoughtBuffer.isNotEmpty ||
              runtime.hasActiveTools)) {
        _error = null;
        _showSdkInstallGuide = false;
        _authReauthPrompted = false;
      }
      final authProbe = runtime.lastError ?? _error;
      if (authProbe != null && isAgentAuthFailureText(authProbe)) {
        _scheduleAuthReauthPrompt(authProbe);
      } else if (authProbe == null || authProbe.trim().isEmpty) {
        _authReauthPrompted = false;
      }
      final n = runtime.entries.length;
      if (n != _messageCount) _messageCount = n;

      final working = runtime.isWorking;
      final turnEnded = _wasWorking && !working;
      _wasWorking = working;
      final queueLen = runtime.outboundQueue.length;
      final queueChanged = queueLen != _lastOutboundQueueLen;
      _lastOutboundQueueLen = queueLen;
      final needsImmediate = turnEnded ||
          queueChanged ||
          runtime.pendingPermission != null ||
          (runtime.lastError != null &&
              !isTransientBridgeErrorText(runtime.lastError!)) ||
          runtime.deliveryError != null;

      // User scrolled up to read history — don't rebuild/re-layout the whole
      // transcript (and GptMarkdown) on every Claude token; that is what makes
      // scrolling feel stuck. Keep a dirty flag and refresh when they jump back.
      if (!needsImmediate && !_followOutput && working) {
        _runtimeUiDirty = true;
        _setFollowOutput(false);
        _scheduleMarkRead();
        return;
      }

      _scheduleRuntimeUi(immediate: needsImmediate);
    };
    runtime.addListener(_runtimeListener!);
    _lastOutboundQueueLen = runtime.outboundQueue.length;
    setState(() {});
    _scrollToEnd();
    // Coming back to a chat whose turn already finished should drain the queue.
    runtime.resumeOutboundQueue();
    unawaited(runtime.recoverTrailingUserPromptIfStuck());
    unawaited(_prefetchModelCatalogIfNeeded(runtime));
    final stickyAuth = runtime.lastError ?? _error;
    if (stickyAuth != null && isAgentAuthFailureText(stickyAuth)) {
      _scheduleAuthReauthPrompt(stickyAuth);
    }
  }

  /// Coalesce ACP stream notifications — Claude can emit dozens per second.
  void _scheduleRuntimeUi({bool immediate = false}) {
    _runtimeUiDirty = true;
    if (immediate) {
      _runtimeUiCoalesce?.cancel();
      _runtimeUiCoalesce = null;
      _flushRuntimeUi();
      return;
    }
    if (_runtimeUiCoalesce?.isActive ?? false) return;
    _runtimeUiCoalesce = Timer(const Duration(milliseconds: 100), () {
      _runtimeUiCoalesce = null;
      _flushRuntimeUi();
    });
  }

  void _flushRuntimeUi() {
    if (!mounted || !_runtimeUiDirty) return;
    _runtimeUiDirty = false;
    setState(() {});
    _scrollToEnd();
    _scheduleMarkRead();
  }

  Future<void> _prefetchModelCatalogIfNeeded(
    ChatSessionRuntime runtime, {
    bool swallowErrors = true,
  }) async {
    if (runtime.closed ||
        runtime.availableModels.isNotEmpty ||
        runtime.promptInFlight ||
        runtime.sendingToHost) {
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
      if (!swallowErrors) rethrow;
    }
  }

  Future<void> _pickModel() async {
    String? connectError;
    // The model list only exists on a live session, so connect first rather
    // than showing an empty picker.
    if ((_runtime?.availableModels ?? const []).isEmpty && !_connecting) {
      try {
        await _ensureAcp();
      } catch (e) {
        connectError = e.toString();
        SafeLog.d('connect before model picker failed', e);
      }
    }
    if (!mounted) return;

    var runtime = _runtime ??
        ref.read(activeAcpSessionsProvider.notifier).get(widget.chatId);

    if (runtime != null && !runtime.closed) {
      try {
        await _prefetchModelCatalogIfNeeded(runtime, swallowErrors: false);
        // Session events can land a tick after Connect — retry once if empty.
        if (runtime.availableModels.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          if (!mounted) return;
          await _prefetchModelCatalogIfNeeded(runtime, swallowErrors: false);
        }
      } catch (e) {
        connectError ??= e.toString();
        SafeLog.d('model catalog refresh in picker failed', e);
      }
    }
    if (!mounted) return;

    runtime = _runtime ??
        ref.read(activeAcpSessionsProvider.notifier).get(widget.chatId);

    final models = runtime?.availableModels ?? const <AgentModel>[];
    if (models.isEmpty) {
      final connected = runtime != null && !runtime.closed;
      final detail = connectError ??
          _error ??
          runtime?.lastError ??
          runtime?.deliveryError;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            detail != null && detail.trim().isNotEmpty
                ? 'Cannot get the model list: $detail'
                : connected
                    ? 'No models from the agent yet. Wait for Connect to finish, then try again.'
                    : 'Connect to the agent first — models load from the live session.',
          ),
        ),
      );
    }

    final chosen = await ModelPickerSheet.show(
      context,
      models: models,
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
          final updated =
              chat.copyWith(modelId: chosen, updatedAt: DateTime.now());
          await ref.read(appDatabaseProvider).upsertChat(updated);
          ref.read(agentDockServiceProvider).schedulePushChat(updated.id);
        }
      }
      if (!mounted) return;
      final confirmed = runtime?.currentModelId ?? chosen;
      setState(() => _chat = _chat?.copyWith(modelId: confirmed));
    } catch (e) {
      SafeLog.d('setModel failed', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_friendlySetModelError(e))),
        );
      }
    }
  }

  /// Shorten nested JSON-RPC dumps for the switch-model snackbar.
  static String _friendlySetModelError(Object e) {
    final text = e.toString();
    if (e is AcpModelSwitchUnsupported ||
        text.contains('AcpModelSwitchUnsupported') ||
        (text.contains('set_config_option') &&
            text.contains('set_model') &&
            text.toLowerCase().contains('method not found'))) {
      return 'Could not switch model: this agent needs a restart to change '
          'models. Reconnect and try again, or update claude-agent-acp on the host.';
    }
    final compact = text
        .replaceFirst(RegExp(r'^Exception:\s*'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (compact.length > 160) {
      return 'Could not switch model: ${compact.substring(0, 157)}…';
    }
    return 'Could not switch model: $compact';
  }

  /// One-line connect failure for the compact banner (full text on tap).
  static String _compactConnectError(Object error, {required bool isClaude}) {
    var msg = error.toString().trim();
    const prefixes = [
      'TimeoutException: ',
      'Exception: ',
      'StateError: ',
    ];
    for (final p in prefixes) {
      if (msg.startsWith(p)) msg = msg.substring(p.length).trim();
    }
    // Unwrap "Could not start … ACP: …" if we re-enter.
    final acp = RegExp(
      r'^Could not start (?:Claude|Cursor)(?: ACP)?:\s*',
      caseSensitive: false,
    ).firstMatch(msg);
    if (acp != null) msg = msg.substring(acp.end).trim();
    for (final p in prefixes) {
      if (msg.startsWith(p)) msg = msg.substring(p.length).trim();
    }

    final lower = msg.toLowerCase();
    if (lower.contains('can\'t reach') ||
        lower.contains('timed out reaching') ||
        lower.contains('timed out opening ssh') ||
        lower.contains('socketexception') ||
        lower.contains('connection refused') ||
        lower.contains('network is unreachable') ||
        lower.contains('no route to host')) {
      return 'Can\'t reach host — check VPN/network';
    }
    if (lower.contains('timed out connecting to adsm')) {
      final host = RegExp(
        r'on ([^\s.]+)',
        caseSensitive: false,
      ).firstMatch(msg)?.group(1);
      return host != null ? 'ADSM timed out on $host' : 'ADSM connect timed out';
    }
    if (lower.contains('timed out installing/starting adsm')) {
      return 'ADSM install timed out';
    }
    if (lower.contains('timed out opening ssh')) {
      return 'SSH timed out';
    }
    if (lower.contains('connect timed out')) {
      return isClaude ? 'Claude connect timed out' : 'Cursor connect timed out';
    }
    if (msg.length > 72) return '${msg.substring(0, 69)}…';
    return msg;
  }

  Future<void> _showFullConnectError(String full) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connection error'),
        content: SingleChildScrollView(
          child: SelectableText(full),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _ensureAcp() {
    _ensureAcpInFlight ??= _ensureAcpBody().whenComplete(() {
      _ensureAcpInFlight = null;
    });
    return _ensureAcpInFlight!;
  }

  void _cancelConnect() {
    _connectEpoch++;
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _connectStatus = null;
    });
  }

  bool _connectStillCurrent(int epoch) =>
      mounted && epoch == _connectEpoch;

  Future<void> _showConnectionControls({
    required bool connecting,
    required bool connected,
  }) async {
    final host = _host;
    final chat = _chat;
    if (host == null || chat == null || !mounted) return;

    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final status = _connectStatus;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  connecting
                      ? (status ?? 'Connecting…')
                      : connected
                          ? 'Agent connected'
                          : 'Agent disconnected',
                ),
                subtitle: Text(host.displayLabel),
              ),
              if (connecting)
                ListTile(
                  leading: Icon(
                    Icons.stop_circle_outlined,
                    color: Theme.of(ctx).colorScheme.error,
                  ),
                  title: const Text('Cancel connecting'),
                  onTap: () => Navigator.pop(ctx, 'cancel'),
                ),
              if (!connected && !connecting)
                ListTile(
                  leading: const Icon(Icons.link),
                  title: const Text('Connect'),
                  onTap: () => Navigator.pop(ctx, 'connect'),
                ),
              if (connected)
                ListTile(
                  leading: const Icon(Icons.link_off),
                  title: const Text('Disconnect this chat'),
                  onTap: () => Navigator.pop(ctx, 'disconnect'),
                ),
              ListTile(
                leading: Icon(
                  Icons.power_settings_new,
                  color: Theme.of(ctx).colorScheme.error,
                ),
                title: const Text('Turn off ADSM'),
                subtitle: const Text('Stops the daemon on this host'),
                onTap: () => Navigator.pop(ctx, 'stop_adsm'),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'cancel':
        _cancelConnect();
      case 'connect':
        unawaited(_ensureAcp());
      case 'disconnect':
        _cancelConnect();
        await ref.read(activeAcpSessionsProvider.notifier).close(chat.id);
        if (mounted) {
          setState(() {
            _runtime = null;
            _error = null;
          });
        }
      case 'stop_adsm':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Turn off ADSM?'),
            content: Text(
              'Stops the ADSM daemon on ${host.displayLabel}. '
              'Open chats disconnect until you reconnect.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Turn off'),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;
        _cancelConnect();
        try {
          await ref.read(activeAcpSessionsProvider.notifier).close(chat.id);
          await ref.read(sshServiceProvider).stopAdsm(host);
          if (mounted) {
            setState(() {
              _runtime = null;
              _error = null;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('ADSM turned off')),
            );
          }
        } catch (e) {
          SafeLog.d('stop ADSM from connecting sheet failed', e);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not stop ADSM: $e')),
            );
          }
        }
    }
  }

  void _scheduleAuthReauthPrompt(String errorText) {
    if (_authReauthPrompted || _authReauthInFlight) return;
    if (!isAgentAuthFailureText(errorText)) return;
    _authReauthPrompted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_promptAuthReauth());
    });
  }

  Future<void> _promptAuthReauth({bool fromUser = false}) async {
    if (!mounted || _authReauthInFlight) return;
    final chat = _chat;
    final host = _host;
    if (chat == null || host == null) return;
    if (fromUser) _authReauthPrompted = true;

    _authReauthInFlight = true;
    try {
      if (chat.provider == AgentProvider.claude) {
        final ok = await ClaudeLoginSheet.show(context, host: host);
        if (!mounted) return;
        if (ok == true) {
          await _reconnectAfterReauth();
        }
        return;
      }

      final goConnect = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cursor authentication required'),
          content: const Text(
            'The agent reported an auth failure. Save a Cursor API key in '
            'Settings, or run `agent login` on this host from Hosts → Terminal.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Dismiss'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (goConnect == true) context.go('/settings');
    } finally {
      _authReauthInFlight = false;
    }
  }

  Future<void> _reconnectAfterReauth() async {
    final chat = _chat;
    if (chat == null) return;
    setState(() {
      _error = null;
      _showSdkInstallGuide = false;
      _authReauthPrompted = false;
    });
    _runtime?.lastError = null;
    _runtime?.deliveryError = null;
    await ref.read(activeAcpSessionsProvider.notifier).close(chat.id);
    if (!mounted) return;
    setState(() => _runtime = null);
    await _ensureAcp();
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
    final bridgePool = ref.read(adsmBridgePoolProvider);
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
            ? 'Checking Claude…'
            : 'Checking Cursor…',
      );

      final adsmReady = ssh.isAdsmReady(host.id);
      final cachedBinary = switch (provider) {
        AgentProvider.cursor => ssh.cachedCursorCli(host.id),
        AgentProvider.claude => ssh.cachedClaudeAcp(host.id),
      };

      // Skip tmux install probe when we already know the agent binary — cold
      // reconnects used to hang here forever on ProxyJump SSH.
      if (!adsmReady && cachedBinary == null) {
        await ssh.ensureTmux(host, onProgress: status).timeout(
          const Duration(seconds: 45),
          onTimeout: () => throw TimeoutException(
            'Timed out checking tmux on the remote.',
          ),
        );
      }

      final String binary;
      if (cachedBinary != null) {
        binary = cachedBinary;
        // Do not say "ready" here — ADSM attach can still hang, and that
        // label next to the header spinner made chats look connected while
        // the composer stayed locked on [_connecting].
        status(
          provider == AgentProvider.claude
              ? 'Claude ACP found…'
              : 'Cursor found…',
        );
      } else {
        binary = switch (provider) {
          AgentProvider.cursor => await ssh
              .ensureCursorCli(host, onProgress: status)
              .timeout(
                const Duration(minutes: 8),
                onTimeout: () => throw TimeoutException(
                  'Timed out installing/finding Cursor CLI on the remote.',
                ),
              ),
          AgentProvider.claude => await ssh
              .ensureClaudeAcpBinary(host, onProgress: status)
              .timeout(
                const Duration(seconds: 90),
                onTimeout: () => throw TimeoutException(
                  'Timed out finding Claude ACP on the remote. '
                  'Open Hosts → terminal and check `claude-code-acp`.',
                ),
              ),
        };
      }

      status(adsmReady ? 'Connecting to ADSM…' : 'Starting ADSM…');
      try {
        await ssh.ensureAdsm(
          host,
          onProgress: status,
          allowUpgrade: !adsmReady,
        ).timeout(
          adsmReady
              ? const Duration(seconds: 75)
              : const Duration(minutes: 3),
          onTimeout: () => throw TimeoutException(
            adsmReady
                ? 'Timed out connecting to ADSM on ${host.displayLabel}'
                : 'Timed out installing/starting ADSM',
          ),
        );
      } on TimeoutException {
        ssh.clearAdsmReady(host.id);
        rethrow;
      }

      final mcps = await db.listEnabledMcpsForHost(host.id);
      final latest = await db.getChat(chatId);

      status('Starting agent…');

      return AdsmSession.start(
        ssh: ssh,
        secureStore: secureStore,
        bridgePool: bridgePool,
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
              ? 'Claude connect timed out'
              : 'Cursor connect timed out',
        ),
      );
    };
  }

  Future<void> _ensureAcpBody() async {
    final repo = _repo;
    final host = _host;
    if (_chat == null || repo == null || host == null) return;
    var chat = _chat!;

    final canAuth =
        await ref.read(secureStoreProvider).canAuthenticateToHost(host.id);
    if (!canAuth) {
      if (mounted) {
        setState(() {
          _error =
              'No SSH credentials for this host. Add a password on the host, '
              'or an SSH key in Settings.';
          _showSdkInstallGuide = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Add a host password or an SSH key in Settings first.',
            ),
          ),
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
      // Never say "Preparing Claude" before we can reach the host — that
      // hid offline/VPN failures behind a misleading agent label.
      _connectStatus = 'Reaching ${host.displayLabel}…';
      _error = null;
      _showSdkInstallGuide = false;
    });
    final epoch = ++_connectEpoch;

    try {
      try {
        await ref.read(sshServiceProvider).connect(host).timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'Timed out reaching ${host.displayLabel}',
          ),
        );
      } catch (e) {
        if (!_connectStillCurrent(epoch)) return;
        SafeLog.d('host unreachable before ACP connect', e);
        setState(() {
          _connecting = false;
          _connectStatus = null;
          _error =
              'Can\'t reach ${host.displayLabel} — check VPN or network, then Retry.';
          _showSdkInstallGuide = false;
        });
        return;
      }
      if (!_connectStillCurrent(epoch)) return;

      // Pull the live session id Mac wrote before we attach — without it the
      // agent starts over and only sees messages sent on this device.
      try {
        if (mounted) {
          setState(() => _connectStatus = 'Syncing chat…');
        }
        final changed = await ref
            .read(agentDockServiceProvider)
            .syncChatRecord(
              host: host,
              chatId: chat.id,
            )
            .timeout(const Duration(seconds: 12));
        if (!_connectStillCurrent(epoch)) return;
        if (changed) {
          final refreshed =
              await ref.read(appDatabaseProvider).getChat(chat.id);
          if (!_connectStillCurrent(epoch)) return;
          if (refreshed != null) {
            chat = refreshed;
            if (mounted) setState(() => _chat = refreshed);
          }
        }
      } catch (e) {
        SafeLog.d('sync chat record before connect failed', e);
      }

      if (chat.provider == AgentProvider.claude) {
        final apiKey =
            await ref.read(secureStoreProvider).readAnthropicApiKey();
        if (!_connectStillCurrent(epoch)) return;
        if (apiKey == null || apiKey.isEmpty) {
          if (mounted) {
            setState(() => _connectStatus = 'Checking Claude login…');
          }
          final auth = ClaudeRemoteAuth(ref.read(sshServiceProvider));
          if (!await auth.isLoggedIn(host).timeout(
                const Duration(seconds: 25),
                onTimeout: () => false,
              )) {
            if (!_connectStillCurrent(epoch)) return;
            setState(() => _connectStatus = 'Sign in required…');
            final signedIn =
                await ClaudeLoginSheet.show(context, host: host);
            if (!_connectStillCurrent(epoch)) return;
            if (signedIn != true) {
              setState(() {
                _connecting = false;
                _connectStatus = null;
                _error = 'Claude sign-in required. Open Settings to continue.';
              });
              return;
            }
          }
        }
      }

      if (!_connectStillCurrent(epoch)) return;
      if (mounted) {
        setState(
          () => _connectStatus = chat.provider == AgentProvider.claude
              ? 'Starting Claude…'
              : 'Starting Cursor…',
        );
      }
      final factory = _buildSessionFactory(chatId: chat.id, cwd: repo.remotePath);

      final session = await factory();
      if (!_connectStillCurrent(epoch)) {
        try {
          await session.close();
        } catch (_) {}
        return;
      }

      final runtime = await ref.read(activeAcpSessionsProvider.notifier).attach(
            chatId: chat.id,
            session: session,
            sessionFactory: factory,
          );
      if (!_connectStillCurrent(epoch)) {
        await ref.read(activeAcpSessionsProvider.notifier).close(chat.id);
        return;
      }
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
      if (!_connectStillCurrent(epoch)) return;
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
      if (!_connectStillCurrent(epoch)) return;
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
              : _compactConnectError(e, isClaude: isClaude);
        });
      }
      final updated = chat.copyWith(status: ChatStatus.error, updatedAt: DateTime.now());
      await ref.read(appDatabaseProvider).upsertChat(updated);
      ref.read(agentDockServiceProvider).schedulePushChat(updated.id);
      if (mounted) setState(() => _chat = updated);
    } finally {
      if (_connectStillCurrent(epoch)) {
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
    _syncComposerDraft('');
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
          if (!isTransientBridgeError(e)) {
            _error = 'Send failed: $e';
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isTransientBridgeError(e)
                  ? 'Connection blip — reconnecting and will retry send…'
                  : 'Send failed: $e',
            ),
          ),
        );
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
        _setFollowOutput(true);
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
    if (force) {
      _pinWindowToLatest();
      _setFollowOutput(true);
    }
    if (!force && (!_landedAtBottom || !_followOutput)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      // Re-check: user may have scrolled away since this was scheduled.
      if (!force && !_followOutput) return;
      final max = _scroll.position.maxScrollExtent;
      final now = DateTime.now();
      final lastAt = _lastScrollToEndAt;
      final grew = max - _lastScrollMaxExtent;
      // Streaming markdown grows the extent constantly — jumping every flush
      // fights the trackpad. Only follow when we moved enough or enough time
      // passed (or the user forced jump-to-latest).
      if (!force &&
          grew < 28 &&
          lastAt != null &&
          now.difference(lastAt) < const Duration(milliseconds: 140) &&
          (_scroll.position.pixels - max).abs() < 48) {
        return;
      }
      if ((_scroll.position.pixels - max).abs() < 1) {
        _lastScrollMaxExtent = max;
        return;
      }
      _lastScrollToEndAt = now;
      _lastScrollMaxExtent = max;
      _programmaticScroll = true;
      // jumpTo (not animateTo): streaming fires many times per second and
      // stacked animations lock the user out of manual scrolling.
      _scroll.jumpTo(max);
      _setFollowOutput(true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _programmaticScroll = false;
      });
    });
  }

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
    final now = DateTime.now();
    final updated = chat.copyWith(
      title: next,
      titleUpdatedAt: now,
      updatedAt: now,
    );
    await ref.read(appDatabaseProvider).upsertChat(updated);
    ref.read(agentDockServiceProvider).pushChatNow(chat.id);
    final runtime =
        ref.read(activeAcpSessionsProvider.notifier).get(chat.id);
    if (runtime != null) runtime.chatMeta = updated;
    ref.read(chatActivityTickProvider.notifier).state++;
    if (mounted) setState(() => _chat = updated);
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
    _runtimeUiCoalesce?.cancel();
    _voiceTick?.cancel();
    _voicePulse.dispose();
    _showJumpToLatest.dispose();
    _composer.removeListener(_onComposerChanged);
    _syncComposerDraft();
    if (_recordingVoice) {
      unawaited(ref.read(gcpSpeechServiceProvider).cancel());
    }
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _startVoiceHold() async {
    if (_sending ||
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

  /// Desktop: Enter sends, Shift+Enter inserts a newline.
  KeyEventResult _composerDesktopEnterKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    // Let IME finish composition.
    if (_composer.value.isComposingRangeValid) {
      return KeyEventResult.ignored;
    }
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final shift = pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
    if (shift) return KeyEventResult.ignored;
    if (!_sending && !_compressing) {
      unawaited(_send());
    }
    return KeyEventResult.handled;
  }

  Widget _buildComposerField({
    required ThemeData theme,
    required bool streaming,
    required bool connected,
    int queuedCount = 0,
  }) {
    const fieldRadius = 26.0;
    final fill = theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55);
    final outline = theme.colorScheme.outlineVariant;

    final hint = () {
      if (_connecting) return 'Connecting agent…';
      if (queuedCount > 0) {
        return queuedCount == 1
            ? '1 follow-up waiting — Force run is above…'
            : '$queuedCount follow-ups waiting — Force run is above…';
      }
      if (streaming) {
        return 'Agent is busy — send to queue a follow-up…';
      }
      if (connected) return 'Message ${_chat!.provider.label} agent…';
      return 'Message agent…';
    }();

    // Row-inside-pill (not a Stack overlay) so mic/send stay inside the
    // rounded chrome on desktop density — the old bottomRight Stack let the
    // send circle hang past the curve.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(fieldRadius),
        border: Border.all(color: outline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: useDesktopShell()
                    ? _composerDesktopEnterKey
                    : null,
                child: TextField(
                  controller: _composer,
                  minLines: 1,
                  maxLines: 5,
                  textInputAction: useDesktopShell()
                      ? TextInputAction.newline
                      : TextInputAction.send,
                  enabled: _chat!.provider.isAvailable,
                  decoration: InputDecoration(
                    hintText: hint,
                    filled: false,
                    isDense: true,
                    contentPadding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                  ),
                  onSubmitted: useDesktopShell()
                      ? null
                      : (_) {
                          if (!_sending && !_compressing) {
                            unawaited(_send());
                          }
                        },
                ),
              ),
            ),
            _buildInlineMicButton(theme: theme),
            const SizedBox(width: 2),
            _buildInlinePrimaryButton(theme: theme, streaming: streaming),
          ],
        ),
      ),
    );
  }

  /// Filled circle inside the composer: Send, Queue, or Stop.
  Widget _buildInlinePrimaryButton({
    required ThemeData theme,
    required bool streaming,
  }) {
    // Only block on an in-flight send/compress. [_connecting] used to freeze
    // the button as a spinner for the whole SSH/ADSM bring-up (often stuck on
    // a misleading "Claude ACP ready"), so users could type but never send.
    // [_send] still awaits [_ensureAcp] before delivering.
    final busy = _sending || _compressing;
    final hasPayload = _composerHasText || _pendingImages.isNotEmpty;
    final isStop = streaming && !hasPayload;
    final isQueue = streaming && hasPayload;
    final enabled = !busy &&
        _chat!.provider.isAvailable &&
        (streaming || hasPayload);

    final tooltip = isStop
        ? 'Stop'
        : isQueue
            ? 'Queue message'
            : 'Send';

    return Tooltip(
      message: tooltip,
      child: Material(
        color: enabled
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurface.withValues(alpha: 0.35),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: !enabled
              ? null
              : () async {
                  if (isStop) {
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
                    return;
                  }
                  unawaited(_send());
                },
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: busy
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.surface,
                      ),
                    )
                  : Icon(
                      isStop
                          ? Icons.stop_rounded
                          : isQueue
                              ? Icons.playlist_add
                              : Icons.arrow_upward_rounded,
                      size: isStop ? 20 : 22,
                      color: theme.colorScheme.surface,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInlineMicButton({required ThemeData theme}) {
    final busy = _sending || _compressing;

    if (_voiceLocked && _recordingVoice) {
      return Tooltip(
        message: 'Stop & transcribe',
        child: Material(
          color: theme.colorScheme.primary,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: busy ? null : () => unawaited(_finishVoiceRecord()),
            child: SizedBox(
              width: 36,
              height: 36,
              child: Icon(
                Icons.stop_rounded,
                size: 20,
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
        ),
      );
    }

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
          final recording = _recordingVoice;

          return Transform.translate(
            offset: recording
                ? Offset(_voiceDragDx * 0.25, _voiceDragDy * 0.2)
                : Offset.zero,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  if (recording && !cancel)
                    Positioned(
                      top: -22,
                      child: Opacity(
                        opacity: (-_voiceDragDy / 56).clamp(0.0, 1.0),
                        child: Icon(
                          Icons.lock_outline,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  Material(
                    color: cancel
                        ? theme.colorScheme.error
                        : recording
                            ? Color.lerp(
                                theme.colorScheme.error,
                                const Color(0xFFE53935),
                                pulse,
                              )!
                            : Colors.transparent,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: Icon(
                        cancel
                            ? Icons.delete_outline
                            : Icons.mic_none_outlined,
                        size: 22,
                        color: cancel || recording
                            ? theme.colorScheme.onError
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Only rebuild this chat when *this* runtime attaches/detaches — not when
    // unrelated chats reconnect and the session map is rewritten.
    final live = ref.watch(
      activeAcpSessionsProvider.select((m) => m[widget.chatId]),
    );
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
    final liveAssistantText = (runtime?.assistantBuffer ?? '').trim();
    final filtered = [
      for (final e in rawEntries)
        if (e.messageId == null ||
            (!queuedIds.contains(e.messageId) &&
                e.messageId != liveAssistantId &&
                // Same text as the live bubble (id race / re-stream) — show once.
                !(liveAssistantText.isNotEmpty &&
                    e.message?.role == MessageRole.assistant &&
                    e.message!.content.trim() == liveAssistantText)))
          e,
    ];
    // System thoughts are folded into assistant bubbles by [buildTranscriptBlocks].
    final entries = entriesByTime(filtered);
    final thoughtBuffer = runtime?.thoughtBuffer ?? '';
    final assistantBuffer = runtime?.assistantBuffer ?? '';
    // Composer no longer locks for the whole turn — only the live buffer
    // counts as "working" for the agent bubble.
    final streaming = runtime?.isWorking ?? false;
    final blocks = _blocksForMemoized(entries, openTurnActive: streaming);
    _syncWindowToBlocks(blocks.length);
    final visibleBlocks = _transcriptWindow.visibleSlice(blocks);
    final hiddenOlder = _transcriptWindow.hiddenOlder();
    final liveError = runtime?.lastError;
    final deliveryError = runtime?.deliveryError;
    final rawError = _error ?? liveError ?? deliveryError;
    final trimmedError = rawError?.trim();
    // Blank / whitespace-only errors still opened the red banner (ListTile +
    // SingleChildScrollView collapsed the title to 0px — empty red strip).
    final displayError =
        (trimmedError == null || trimmedError.isEmpty) ? null : trimmedError;
    final guide = () {
      final err = (displayError ?? '').toLowerCase();
      if (err.contains('tmux')) return kRemoteTmuxSetupGuide;
      if (err.contains('adsm')) return kRemoteAdsmSetupGuide;
      return _chat!.provider == AgentProvider.claude
          ? kRemoteClaudeSetupGuide
          : kRemoteCursorSetupGuide;
    }();
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
    final pollingTools = [
      for (final t in activeToolEntries)
        if (t.isPollingWait) t,
    ];
    final isPolling = pollingTools.isNotEmpty;
    final activityLabel = runtime?.activityLabel;
    final statusLabel = switch (true) {
      _ when _connecting =>
        ' · ${_connectStatus ?? 'Connecting…'}',
      _ when reconnecting => ' · reconnecting…',
      _ when remoteRunning && !connected => ' · running on host',
      _ when sending =>
        ' · ${activityLabel?.isNotEmpty == true ? activityLabel! : 'Sending to host…'}',
      _ when streaming && isPolling =>
        ' · Polling · ${pollingTools.first.displayTitle}',
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
            streaming: streaming,
            initiallyExpanded: streaming,
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
        automaticallyImplyLeading: !useDesktopShell(context),
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
          if (_repo != null && _host != null)
            IconButton(
              tooltip: 'Terminal in project',
              onPressed: () {
                final loc = Uri(
                  path: '/hosts/terminal/${_host!.id}',
                  queryParameters: {'cwd': _repo!.remotePath},
                ).toString();
                if (useDesktopShell(context)) {
                  context.go(loc);
                } else {
                  context.push(loc);
                }
              },
              icon: const Icon(Icons.terminal),
            ),
          if (_connecting || reconnecting)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Tooltip(
                message: _connectStatus ??
                    'Reconnecting (${runtime?.reconnectAttempts ?? 0})…',
                child: const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            tooltip: _connecting
                ? (_connectStatus ?? 'Connecting — tap for controls')
                : reconnecting
                    ? 'Reconnecting — tap for controls'
                    : adsmSession != null
                        ? 'ADSM host status'
                        : connected
                            ? 'Agent live — keeps running on the host if you disconnect'
                            : 'Reconnect ACP',
            onPressed: () {
              if (adsmSession != null) {
                unawaited(
                  AdsmHealthSheet.show(
                    context,
                    session: adsmSession,
                    bridgeOpen: connected,
                    provider: _chat?.provider,
                    onReconnect: connected || _connecting ? null : _ensureAcp,
                    onReauthed: () {
                      unawaited(_reconnectAfterReauth());
                    },
                    onStopped: () {
                      unawaited(() async {
                        _cancelConnect();
                        final chat = _chat;
                        if (chat == null) return;
                        await ref
                            .read(activeAcpSessionsProvider.notifier)
                            .close(chat.id);
                        if (mounted) {
                          setState(() {
                            _runtime = null;
                            _error = null;
                          });
                        }
                      }());
                    },
                  ),
                );
                return;
              }
              unawaited(_showConnectionControls(
                connecting: _connecting || reconnecting,
                connected: connected,
              ));
            },
            icon: Icon(
              _connecting || reconnecting
                  ? Icons.power_settings_new
                  : connected
                      ? Icons.sensors
                      : Icons.link,
            ),
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
                    detail: () {
                      final usage = TurnMetricsLabel.formatContextUsage(
                        runtime?.usageTokensUsed,
                        runtime?.usageContextSize,
                      );
                      if (usage != null) return usage;
                      final badges = _selectedModel?.badges.join(' · ');
                      return (badges != null && badges.isNotEmpty)
                          ? badges
                          : null;
                    }(),
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
          if (_connecting || reconnecting)
            Material(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _connectStatus ??
                            (reconnecting
                                ? 'Reconnecting (${runtime?.reconnectAttempts ?? 0})…'
                                : 'Connecting…'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: () {
                        _cancelConnect();
                        if (reconnecting && runtime != null) {
                          unawaited(
                            ref
                                .read(activeAcpSessionsProvider.notifier)
                                .close(widget.chatId),
                          );
                          setState(() {
                            _runtime = null;
                            _error = null;
                          });
                        }
                      },
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ),
          if (displayError != null &&
              (_showSdkInstallGuide ||
                  displayError.toLowerCase().contains('tmux') ||
                  displayError.toLowerCase().contains('not installed')))
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
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.9),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 0, 2),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkWell(
                        onTap: () => unawaited(
                          _showFullConnectError(displayError),
                        ),
                        child: Text(
                          _compactConnectError(
                            displayError,
                            isClaude: _chat?.provider == AgentProvider.claude,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onErrorContainer,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    if (!connected)
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
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
                        child: const Text('Retry'),
                      ),
                    IconButton(
                      tooltip: 'Connection controls',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.power_settings_new,
                        size: 20,
                        color: theme.colorScheme.onErrorContainer,
                      ),
                      onPressed: () {
                        if (adsmSession != null) {
                          unawaited(
                            AdsmHealthSheet.show(
                              context,
                              session: adsmSession,
                              bridgeOpen: connected,
                              provider: _chat?.provider,
                              onReconnect:
                                  connected || _connecting ? null : _ensureAcp,
                              onReauthed: () {
                                unawaited(_reconnectAfterReauth());
                              },
                              onStopped: () {
                                unawaited(() async {
                                  _cancelConnect();
                                  final chat = _chat;
                                  if (chat == null) return;
                                  await ref
                                      .read(activeAcpSessionsProvider.notifier)
                                      .close(chat.id);
                                  if (mounted) {
                                    setState(() {
                                      _runtime = null;
                                      _error = null;
                                    });
                                  }
                                }());
                              },
                            ),
                          );
                        } else {
                          unawaited(
                            _showConnectionControls(
                              connecting: _connecting || reconnecting,
                              connected: connected,
                            ),
                          );
                        }
                      },
                    ),
                    if (isAgentAuthFailureText(displayError))
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: (_connecting || _authReauthInFlight)
                            ? null
                            : () => unawaited(
                                  _promptAuthReauth(fromUser: true),
                                ),
                        child: const Text('Reauth'),
                      ),
                    IconButton(
                      tooltip: 'Dismiss',
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.close,
                        size: 18,
                        color: theme.colorScheme.onErrorContainer,
                      ),
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
          Expanded(
            child: Stack(
              children: [
                NotificationListener<UserScrollNotification>(
                  onNotification: (notification) {
                    if (_programmaticScroll ||
                        _shiftingWindow ||
                        !_landedAtBottom) {
                      return false;
                    }
                    // reverse = toward older messages (top); stop auto-follow.
                    if (notification.direction == ScrollDirection.reverse) {
                      if (_followOutput) _setFollowOutput(false);
                      _maybeLoadOlderHistory();
                    } else if (notification.direction ==
                        ScrollDirection.forward) {
                      if (_isNearBottom && !_followOutput) {
                        _setFollowOutput(true);
                      }
                      // Past softMax (~370): ditch oldest page when heading down.
                      _maybeTrimOlderHistory();
                    }
                    return false;
                  },
                  child: GptMarkdownTheme(
                      gptThemeData: chatGptMarkdownTheme(theme),
                      child: ListView.builder(
                  controller: _scroll,
                  // Desktop: Cursor-like side margins. Phone: tighter inset so
                  // bubbles aren't pushed inward like a desktop column.
                  padding: EdgeInsets.fromLTRB(
                    useDesktopShell(context) ? 40 : 16,
                    12,
                    useDesktopShell(context) ? 40 : 16,
                    16,
                  ),
                  // Keep scroll physics interactive even while the agent streams.
                  physics: const AlwaysScrollableScrollPhysics(),
                  cacheExtent: 280,
                  itemCount: (hiddenOlder > 0 ? 1 : 0) +
                      visibleBlocks.length +
                      extra.length,
                  itemBuilder: (context, index) {
                    var cursor = index;
                    if (hiddenOlder > 0) {
                      if (cursor == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Center(
                            child: TextButton(
                              onPressed: _loadingOlderHistory
                                  ? null
                                  : () => _maybeLoadOlderHistory(
                                        fromUserTap: true,
                                      ),
                              child: Text(
                                _loadingOlderHistory
                                    ? 'Loading earlier…'
                                    : '↑ $hiddenOlder earlier · tap to load',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        );
                      }
                      cursor--;
                    }
                    if (cursor < visibleBlocks.length) {
                      final historyIndex = cursor;
                      final absoluteIndex =
                          _transcriptWindow.start + historyIndex;
                      final block = visibleBlocks[historyIndex];
                      final prevAt = historyIndex > 0
                          ? visibleBlocks[historyIndex - 1].createdAt
                          : null;
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
                      final stats = block.turnStats;
                      final withStats = stats != null && stats.isNotEmpty
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                body,
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 6,
                                    top: 2,
                                    bottom: 4,
                                  ),
                                  child: TurnMetricsLabel(
                                    added: stats.added,
                                    removed: stats.removed,
                                    files: stats.files,
                                  ),
                                ),
                              ],
                            )
                          : body;
                      final keyed = KeyedSubtree(
                        key: ValueKey(
                          block.thinkingOnly != null
                              ? 'think-$absoluteIndex-${block.thinkingOnly.hashCode}'
                              : tools != null
                                  ? 'tools-$absoluteIndex-${tools.length}-'
                                      '${tools.first.messageId ?? tools.first.createdAt}'
                                  : block.entry!.messageId ??
                                      block.entry!.tool?.toolCallId ??
                                      'e-$absoluteIndex',
                        ),
                        child: RepaintBoundary(child: withStats),
                      );
                      if (!showDate) return keyed;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _DateChip(at),
                          keyed,
                        ],
                      );
                    }
                    cursor -= visibleBlocks.length;
                    return extra[cursor];
                  },
                ),
                  ),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: _showJumpToLatest,
                  builder: (context, showJump, _) {
                    if (!showJump) return const SizedBox.shrink();
                    return Positioned(
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
                            onPressed: () {
                              _pinWindowToLatest();
                              _flushRuntimeUi();
                              _scrollToEnd(force: true);
                            },
                            icon: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
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
                            // Polling waits are the thing users confuse with
                            // "stuck" — surface that above explore totals.
                            if (isPolling) {
                              final label =
                                  '${pollingTools.first.displayTitle} · Polling';
                              final text = label.endsWith('…') ||
                                      label.endsWith('...')
                                  ? label
                                  : '$label…';
                              return Text(text, style: style);
                            }
                            if (explore != null && explore.isNotEmpty) {
                              return ExploreStatsLabel(
                                files: explore.fileCount,
                                searches: explore.searchCount,
                                style: style,
                                showEllipsis: true,
                              );
                            }
                            final String label;
                            if (sending) {
                              label = activityLabel?.isNotEmpty == true
                                  ? activityLabel!
                                  : 'Sending to host…';
                            } else if (activityLabel != null &&
                                activityLabel.isNotEmpty) {
                              label = activityLabel;
                            } else if (activeTools == 1) {
                              label = activeToolEntries.first.displayTitle;
                            } else if (activeTools > 1) {
                              label = 'Working · $activeTools tools';
                            } else {
                              label = 'Thinking';
                            }
                            final text =
                                label.endsWith('…') || label.endsWith('...')
                                    ? label
                                    : '$label…';
                            return Text(text, style: style);
                          },
                        ),
                      ),
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
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Attach image',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 40,
                              minHeight: 36,
                            ),
                            onPressed: _pickingImages ||
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
                                : const Icon(
                                    Icons.add_photo_alternate_outlined,
                                  ),
                          ),
                          _buildComposerModelHint(theme),
                        ],
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_showSlashMenu) _buildSlashMenu(theme),
                            _buildComposerField(
                              theme: theme,
                              streaming: streaming,
                              connected: connected,
                              queuedCount: queue.length,
                            ),
                          ],
                        ),
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

  /// Model chip under the attach button, beside the composer.
  Widget _buildComposerModelHint(ThemeData theme) {
    final model = _selectedModel;
    final label = model?.summary ??
        (_chat?.modelId != null && _chat!.modelId!.isNotEmpty
            ? AgentModel.parse(_chat!.modelId!).summary
            : null);
    if (label == null || label.isEmpty) {
      return const SizedBox.shrink();
    }
    final usage = TurnMetricsLabel.formatContextUsage(
      _runtime?.usageTokensUsed,
      _runtime?.usageContextSize,
    );
    final line = usage == null ? label : '$label\n$usage';
    return Tooltip(
      message: usage == null
          ? 'Model: $label'
          : 'Model: $label\nContext: $usage',
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _pickModel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 72),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 4),
            child: Text(
              line,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary.withValues(alpha: 0.9),
                fontWeight: FontWeight.w500,
                height: 1.15,
              ),
            ),
          ),
        ),
      ),
    );
  }
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Row(
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
      mainAxisSize: useDesktopShell(context) ? MainAxisSize.max : MainAxisSize.min,
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
          MessageBody(text: '…', style: bodyStyle, live: true)
        else if (bodyText.isNotEmpty || (streaming && bodyText.isEmpty))
          MessageBody(
            text: streaming && bodyText.isEmpty ? '…' : bodyText,
            style: bodyStyle,
            live: streaming,
          ),
        if (!streaming && (at != null || bodyText.trim().isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              // Desktop Cursor-style: meta hugs the trailing edge of a
              // full-width pill. Phone: keep meta with the text (start) so
              // it does not look right-justified across the screen.
              mainAxisAlignment: useDesktopShell(context)
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              mainAxisSize: useDesktopShell(context)
                  ? MainAxisSize.max
                  : MainAxisSize.min,
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
      final desktop = useDesktopShell(context);
      return Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * (desktop ? 0.92 : 0.88),
          ),
          child: Container(
            // Full-width pill on desktop; shrink-wrap on phone so short
            // messages don't stretch timestamps to the screen's right edge.
            width: desktop ? double.infinity : null,
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
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
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 10, left: 4, right: 4),
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

/// Ask-mode approval strip — compact card above the composer.
class _PermissionPromptBar extends StatelessWidget {
  const _PermissionPromptBar({
    required this.request,
    required this.onSelect,
  });

  final PendingPermissionRequest request;
  final void Function(String optionId) onSelect;

  static String _shortLabel(PermissionOption o) {
    if (o.isAllowAlways) return 'Always';
    if (o.isReject) return 'Deny';
    if (o.isAllowOnce) return 'Allow';
    final n = o.name.trim();
    final lower = n.toLowerCase();
    if (lower.startsWith('allow once')) return 'Allow';
    if (lower.startsWith('allow always')) return 'Always';
    if (lower.startsWith('reject') || lower.startsWith('deny')) return 'Deny';
    return n.length > 14 ? '${n.substring(0, 13)}…' : n;
  }

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

    // Prefer Allow → Always → Deny so the primary action sits first.
    final sorted = [...options]..sort((a, b) {
        int rank(PermissionOption o) {
          if (o.isAllowOnce) return 0;
          if (o.isAllowAlways) return 1;
          if (o.isReject) return 2;
          return 3;
        }

        return rank(a).compareTo(rank(b));
      });

    final title = request.title.trim();
    final desc = request.description?.trim();
    final hasDesc = desc != null && desc.isNotEmpty;

    final allowStyle = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      minimumSize: const Size(0, 28),
      backgroundColor: AppColors.accent,
      foregroundColor: AppColors.deep,
      textStyle: theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );
    final alwaysStyle = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      minimumSize: const Size(0, 28),
      backgroundColor: AppColors.accent.withValues(alpha: 0.2),
      foregroundColor: AppColors.accent,
      textStyle: theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );
    final denyStyle = TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      minimumSize: const Size(0, 28),
      foregroundColor: scheme.onSurfaceVariant,
      textStyle: theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    );

    return Material(
      color: scheme.surfaceContainerHigh,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: AppColors.accent.withValues(alpha: 0.35)),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.shield_outlined,
                size: 14,
                color: AppColors.accent.withValues(alpha: 0.95),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title.isEmpty ? 'Allow this action?' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w600,
                        height: 1.15,
                      ),
                    ),
                    if (hasDesc)
                      Text(
                        desc,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.15,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              for (var i = 0; i < sorted.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                Builder(
                  builder: (context) {
                    final o = sorted[i];
                    final label = _shortLabel(o);
                    if (o.isAllowOnce) {
                      return FilledButton(
                        style: allowStyle,
                        onPressed: () => onSelect(o.optionId),
                        child: Text(label),
                      );
                    }
                    if (o.isAllowAlways) {
                      return FilledButton(
                        style: alwaysStyle,
                        onPressed: () => onSelect(o.optionId),
                        child: Text(label),
                      );
                    }
                    return TextButton(
                      style: denyStyle,
                      onPressed: () => onSelect(o.optionId),
                      child: Text(label),
                    );
                  },
                ),
              ],
            ],
          ),
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
                constraints: const BoxConstraints(maxWidth: 220),
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
