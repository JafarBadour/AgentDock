import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/local/app_database.dart';
import '../data/models/agent_mode.dart';
import '../data/models/agent_model.dart';
import '../data/models/chat.dart';
import '../data/models/chat_message.dart';
import '../data/models/code_change_stats.dart';
import '../data/models/explore_stats.dart';
import '../data/models/prompt_image.dart';
import '../data/models/thought_message.dart';
import '../data/models/tool_call_state.dart';
import '../data/secure/safe_log.dart';
import 'adsm_client.dart';
import 'agent_session.dart';
import 'cursor_acp_service.dart';
import 'ssh_service.dart';

/// One transcript row — message and/or live tool.
class TranscriptEntry {
  const TranscriptEntry._({
    this.message,
    this.tool,
    this.messageId,
    DateTime? createdAt,
  }) : _createdAt = createdAt;

  factory TranscriptEntry.message(ChatMessage message) => TranscriptEntry._(
        message: message,
        messageId: message.id,
        createdAt: message.createdAt,
      );

  factory TranscriptEntry.tool(
    ToolCallState tool, {
    String? messageId,
    DateTime? createdAt,
  }) =>
      TranscriptEntry._(
        tool: tool,
        messageId: messageId,
        createdAt: createdAt ?? DateTime.now(),
      );

  final ChatMessage? message;
  final ToolCallState? tool;
  final String? messageId;
  final DateTime? _createdAt;

  DateTime? get createdAt => _createdAt ?? message?.createdAt;
}

/// Long-lived ACP session + transcript for one chat.
///
/// Keeps listening and persisting even when [ChatScreen] is disposed, so
/// switching chats does not lose in-flight agent work.
class ChatSessionRuntime extends ChangeNotifier {
  ChatSessionRuntime({
    required this.chatId,
    required AgentSession session,
    required AppDatabase db,
    this.onLocalChange,
    this.onTransportReady,
    this.sessionFactory,
    this.onAssistantText,
  })  : _session = session,
        _db = db,
        preferredMode = session.mode,
        preferredPermissionPolicy = session.permissionPolicy;

  /// Maximum automatic attempts before we stop and wait for the user.
  static const maxReconnectAttempts = 10;
  static const _maxBackoff = Duration(seconds: 30);

  final String chatId;
  final AppDatabase _db;
  final void Function(String chatId)? onLocalChange;

  /// Fired after a successful [replaceSession] so owners can bump UI state.
  final void Function(String chatId)? onTransportReady;

  /// Local notify hook for assistant text deltas (not tools/thoughts).
  final void Function(String snippet)? onAssistantText;

  /// Opens a fresh transport for this chat. Set by the owner so the runtime can
  /// recover on its own after a drop, even with no chat screen mounted.
  Future<AgentSession> Function()? sessionFactory;

  AgentSession _session;
  StreamSubscription<AcpUpdate>? _sub;

  final List<TranscriptEntry> entries = [];
  final Map<String, String> _toolMessageIds = {};
  final _random = Random();

  String assistantBuffer = '';
  String thoughtBuffer = '';

  /// Row id for the agent turn currently streaming, so progressive writes
  /// update one message instead of appending fragments.
  String? _assistantMessageId;
  DateTime? _assistantStartedAt;
  Timer? _assistantPersistTimer;
  Timer? _codeDeltaPersistTimer;
  int _writesInFlight = 0;

  /// Id of the assistant row currently mirrored from [assistantBuffer], if any.
  String? get liveAssistantMessageId =>
      assistantBuffer.trim().isEmpty ? null : _assistantMessageId;

  /// True while decoded output exists that SQLite has not caught up with.
  ///
  /// The remote journal offset must not advance past this point: the next
  /// connection resumes from that offset, so committing it early means the
  /// tail of the turn is read, never stored, and never replayed.
  bool get hasUnpersistedOutput =>
      _assistantPersistTimer != null ||
      thoughtBuffer.isNotEmpty ||
      _writesInFlight > 0;
  String? lastError;
  bool closed = false;
  bool promptInFlight = false;

  /// Cursor-style activity label from ADSM (`Thinking`, tool name, …).
  String? activityLabel;

  /// Turn was handed to the durable host after the phone disconnected.
  bool remoteTurnActive = false;

  /// True while a local prompt is in flight, the host is still producing, or
  /// any tool call is still pending/running — so the UI stays on "working"
  /// through long tool chains, not only while text is streaming.
  bool get hasActiveTools =>
      entries.any((e) => e.tool?.isActive ?? false);

  bool get isWorking =>
      promptInFlight || remoteTurnActive || hasActiveTools;

  /// Live code churn from edit/write tools in this transcript.
  CodeChangeStats get codeDelta => CodeChangeStats.fromTools([
        for (final e in entries)
          if (e.tool != null) e.tool!,
      ]);

  /// Reads + searches since the last user message (current turn).
  ExploreStats get turnExploreStats =>
      ExploreStats.fromTools(_toolsSinceLastUserMessage());

  Iterable<ToolCallState> _toolsSinceLastUserMessage() sync* {
    var start = 0;
    for (var i = entries.length - 1; i >= 0; i--) {
      final m = entries[i].message;
      if (m != null && m.role == MessageRole.user) {
        start = i + 1;
        break;
      }
    }
    for (var i = start; i < entries.length; i++) {
      final tool = entries[i].tool;
      if (tool != null) yield tool;
    }
  }

  Chat? chatMeta;

  /// User messages waiting for the current turn to finish (or for Force run).
  ///
  /// Persisted to the DB and to [AppDatabase.setOutboundQueue]. Not in
  /// [entries] until promoted — the chat paints them after the live agent turn.
  final List<ChatMessage> outboundQueue = [];

  /// Serialises prompt turns so a force-run cannot interleave with an old one.
  Future<void> _promptTail = Future<void>.value();

  /// Bumped when a hung prompt chain is broken so a stale turn's `finally`
  /// cannot clear [promptInFlight] or drain the queue under a newer turn.
  int _promptEpoch = 0;

  /// When true, a cancelled turn's `finally` must not auto-start the next
  /// queued message — [forceRun] is about to pick one explicitly.
  bool _skipAutoDrain = false;

  /// True while we intentionally recycle the host for Ask ↔ Full access.
  bool _restartingForPolicy = false;

  /// True while a silent reconnect is pending or running.
  bool reconnecting = false;
  int reconnectAttempts = 0;
  Timer? _retryTimer;
  /// Clears stale "working" after reconnect when the host already went idle
  /// while we were away (we miss that `turnComplete` in the journal gap).
  Timer? _hostBusyWatchdog;
  DateTime? _lastHostActivityAt;
  bool _disposed = false;
  bool _suspended = false;

  AgentSession get session => _session;
  AgentSessionMode get mode => _session.mode;
  PermissionPolicy get permissionPolicy => preferredPermissionPolicy;
  List<AgentModel> get availableModels => _session.availableModels;
  String? get currentModelId => _session.currentModelId;

  /// Toolbar preference — also used by [sessionFactory] on reconnect so toggles
  /// are not frozen at the value captured when the factory was first built.
  AgentSessionMode preferredMode;
  PermissionPolicy preferredPermissionPolicy;

  /// Ask-mode tool approval waiting for the user on this device.
  PendingPermissionRequest? pendingPermission;

  void hydrateFromMessages(List<ChatMessage> messages) {
    entries.clear();
    _toolMessageIds.clear();
    final queuedIds = {for (final m in outboundQueue) m.id};
    for (final m in messages) {
      if (queuedIds.contains(m.id)) continue;
      if (m.role == MessageRole.tool) {
        final tool = ToolCallState.tryParseContent(m.content);
        if (tool != null) {
          entries.add(TranscriptEntry.tool(tool, messageId: m.id));
          _toolMessageIds[tool.toolCallId] = m.id;
          continue;
        }
      }
      entries.add(TranscriptEntry.message(m));
    }
    _scheduleCodeDeltaPersist();
    notifyListeners();
  }

  /// Merge remote/local DB rows into the live transcript without clearing
  /// in-flight assistant or thought buffers.
  void absorbMessages(List<ChatMessage> messages) {
    final queuedIds = {for (final m in outboundQueue) m.id};
    for (final m in messages) {
      if (queuedIds.contains(m.id)) continue;
      if (m.role == MessageRole.tool) {
        final tool = ToolCallState.tryParseContent(m.content);
        if (tool == null) continue;
        final index =
            entries.indexWhere((e) => e.tool?.toolCallId == tool.toolCallId);
        if (index >= 0) {
          final prev = entries[index].tool!;
          entries[index] = TranscriptEntry.tool(
            prev.merge(
              title: tool.title,
              kind: tool.kind,
              status: tool.status,
              locations: tool.locations.isEmpty ? null : tool.locations,
              rawInput: tool.rawInput,
              rawOutput: tool.rawOutput,
              content: tool.content,
            ),
            messageId: entries[index].messageId ?? m.id,
            createdAt: entries[index].createdAt ?? m.createdAt,
          );
        } else {
          entries.add(
            TranscriptEntry.tool(tool, messageId: m.id, createdAt: m.createdAt),
          );
          _toolMessageIds[tool.toolCallId] = m.id;
        }
        continue;
      }
      final index = entries.indexWhere((e) => e.messageId == m.id);
      if (index >= 0) {
        final prev = entries[index].message;
        if (prev != null && m.content.length > prev.content.length) {
          entries[index] = TranscriptEntry.message(m);
        }
      } else {
        entries.add(TranscriptEntry.message(m));
      }
    }
    notifyListeners();
  }

  /// Pull the on-disk transcript (and queue) into memory after a remote sync.
  Future<void> syncTranscriptFromDb() async {
    await restoreOutboundQueue();
    absorbMessages(await _db.listMessages(chatId));
  }

  /// Pull host-durable messages over ADSM and merge into SQLite + memory.
  Future<void> pullHostTranscriptAndSync() async {
    final session = _session;
    if (session is! AdsmSession) {
      await syncTranscriptFromDb();
      return;
    }
    try {
      final remote = await session.pullTranscript();
      if (remote.isNotEmpty) {
        await _db.mergeMessages(chatId, remote);
      }
    } catch (e) {
      SafeLog.d('pull host transcript failed', e);
    }
    await syncTranscriptFromDb();
  }

  /// Push local SQLite messages into the host ADSM store.
  Future<void> pushTranscriptToHost() async {
    final session = _session;
    if (session is! AdsmSession || closed) return;
    try {
      final local = await _db.listMessages(chatId);
      await session.syncTranscriptToHost(local);
    } catch (e) {
      SafeLog.d('push transcript to host failed', e);
    }
  }

  /// Reload the durable outbound queue and drop those rows from [entries].
  Future<void> restoreOutboundQueue() async {
    final queued = await _db.getOutboundQueue(chatId);
    outboundQueue
      ..clear()
      ..addAll(queued);
    if (queued.isEmpty) {
      notifyListeners();
      return;
    }
    final ids = {for (final m in queued) m.id};
    entries.removeWhere((e) => e.messageId != null && ids.contains(e.messageId));
    notifyListeners();
  }

  /// If the agent is idle and work is waiting, start the next queued prompt.
  void resumeOutboundQueue() {
    if (_disposed || closed || promptInFlight || outboundQueue.isEmpty) return;
    final next = outboundQueue.removeAt(0);
    unawaited(_persistOutboundQueue());
    notifyListeners();
    unawaited(() async {
      await _promoteQueuedMessage(next);
      await _runPrompt(
        next.content,
        userMessageId: next.id,
        userCreatedAt: next.createdAt,
      );
    }());
  }

  Future<void> _persistOutboundQueue() async {
    try {
      await _db.setOutboundQueue(chatId, List.unmodifiable(outboundQueue));
    } catch (e) {
      SafeLog.d('persist outbound queue failed', e);
    }
  }

  /// Drop a hung prompt chain so Force run / send can make progress again.
  void _breakPromptChain() {
    _promptEpoch++;
    promptInFlight = false;
    _promptTail = Future<void>.value();
  }

  void startListening() {
    _sub?.cancel();
    _sub = _session.updates.listen(_onUpdate, onError: (Object e) {
      if (isTransientBridgeError(e)) {
        // Same as a clean closed event — reconnect quietly.
        SafeLog.d('session stream dropped', e);
        lastError = null;
        if (!closed && sessionFactory != null && !_suspended) {
          closed = true;
          _scheduleReconnect(immediate: true);
        }
      } else {
        lastError = e.toString();
      }
      notifyListeners();
    });
  }

  void replaceSession(AgentSession session) {
    _sub?.cancel();
    _retryTimer?.cancel();
    _retryTimer = null;
    _session = session;
    session.mode = preferredMode;
    session.permissionPolicy = preferredPermissionPolicy;
    pendingPermission = null;
    closed = false;
    lastError = null;
    reconnecting = false;
    reconnectAttempts = 0;
    // A reconnect must not inherit a hung prompt chain from the dead socket.
    _breakPromptChain();
    // A turn handed off to the host may still be running — show working until
    // we see idle/turn-complete in the journal stream.
    if (remoteTurnActive) {
      promptInFlight = true;
      _armHostBusyWatchdog();
    }
    startListening();
    unawaited(rememberSessionId());
    notifyListeners();
    onTransportReady?.call(chatId);
    unawaited(pullHostTranscriptAndSync());
    // Pick up anything that was waiting while the socket was down.
    if (!remoteTurnActive) {
      resumeOutboundQueue();
    }
  }

  /// Store the live ACP session id so the next launch can resume this
  /// conversation instead of starting a fresh one.
  ///
  /// Reconnects can mint a new id (the agent process may have been restarted
  /// under it), and an id that only ever lived in memory is the difference
  /// between resuming with full context and the agent acting like it has never
  /// met you.
  Future<void> rememberSessionId() async {
    final id = _session.sessionId;
    if (id == null) return;
    final current = chatMeta ?? await _db.getChat(chatId);
    if (current == null || current.acpSessionId == id) return;
    chatMeta = current.copyWith(acpSessionId: id, updatedAt: DateTime.now());
    try {
      await _db.upsertChat(chatMeta!);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('persist acp session id failed', e);
    }
  }

  /// The app is going into the background — stop fighting for a socket the OS
  /// is about to kill. For durable sessions the host agent keeps the turn.
  void suspend() {
    _suspended = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    reconnecting = false;
    // The OS may never let us run again, so get the streaming turn on disk now
    // rather than waiting out the checkpoint debounce.
    _assistantPersistTimer?.cancel();
    _assistantPersistTimer = null;
    unawaited(_writeAssistantProgress());

    final durable = _session.transport == AcpTransport.durable;
    if (durable && (promptInFlight || _session.isPromptActive)) {
      // Hand the turn to the host: complete the local await so the UI unlocks,
      // then tear down only the SSH ADSM client channel. Daemon + tmux keep working.
      remoteTurnActive = true;
      _session.handOffPrompt();
      promptInFlight = false;
      closed = true;
      unawaited(_session.close());
    } else if (durable && !closed) {
      // Idle durable session — drop the bridge; reconnect on resume.
      closed = true;
      unawaited(_session.close());
    }
    notifyListeners();
  }

  /// Back in the foreground — recover immediately rather than on next tap.
  void resume() {
    _suspended = false;
    if (closed && sessionFactory != null) {
      reconnectAttempts = 0;
      // Drop the "tap Reconnect" notice; we are about to do it automatically.
      lastError = null;
      _scheduleReconnect(immediate: true);
    }
  }

  Duration _backoffFor(int attempt) {
    final seconds = min(1 << attempt, _maxBackoff.inSeconds);
    // Jitter keeps several chats on the same host from retrying in lockstep.
    final jitterMs = _random.nextInt(400);
    return Duration(milliseconds: seconds * 1000 + jitterMs);
  }

  void _scheduleReconnect({bool immediate = false}) {
    if (_disposed || _suspended) return;
    final factory = sessionFactory;
    if (factory == null) return;
    if (_retryTimer != null) return;

    if (reconnectAttempts >= maxReconnectAttempts) {
      reconnecting = false;
      lastError = 'Could not reconnect after $maxReconnectAttempts attempts. '
          'Tap Reconnect to try again — your chat history is kept.';
      notifyListeners();
      return;
    }

    final delay = immediate ? Duration.zero : _backoffFor(reconnectAttempts);
    reconnectAttempts++;
    reconnecting = true;
    // Drop sticky transport nags — reconnect is already underway.
    if (lastError != null && isTransientBridgeErrorText(lastError!)) {
      lastError = null;
    }
    notifyListeners();

    _retryTimer = Timer(delay, () async {
      _retryTimer = null;
      if (_disposed || _suspended) return;
      try {
        final session = await factory();
        replaceSession(session);
        SafeLog.d('reconnected chat $chatId');
      } catch (e) {
        SafeLog.d('reconnect attempt $reconnectAttempts failed', e);
        if (classifySshFailure(e).isFatal) {
          reconnecting = false;
          // Keep this short — MissingToolException used to dump the whole
          // install script into lastError and overflow the chat screen.
          lastError = e is MissingToolException
              ? 'Cannot reconnect: ${e.tool} is not installed on the remote.'
              : 'Cannot reconnect: $e';
          notifyListeners();
          return;
        }
        _scheduleReconnect();
      }
    });
  }

  void setPermissionPolicy(PermissionPolicy policy) {
    preferredPermissionPolicy = policy;
    _session.setPermissionPolicy(policy);
    if (policy.fullAccess) pendingPermission = null;
    notifyListeners();
  }

  /// Apply Ask ↔ Full access. Restarts the durable host process when the
  /// `--force` flag must change, so the toolbar choice matches the agent.
  Future<void> applyPermissionPolicy(PermissionPolicy policy) async {
    final needsHostRestart =
        preferredPermissionPolicy.fullAccess != policy.fullAccess;
    setPermissionPolicy(policy);
    if (!needsHostRestart) return;

    final factory = sessionFactory;
    if (factory == null) return;

    _restartingForPolicy = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    reconnecting = true;
    notifyListeners();
    try {
      await _session.close();
      closed = true;
      final session = await factory();
      replaceSession(session);
      // After a policy restart the process is fresh — re-apply session mode.
      if (preferredMode != AgentSessionMode.agent) {
        try {
          await session.setMode(preferredMode);
        } catch (e) {
          SafeLog.d('setMode after permission restart failed', e);
        }
      }
    } catch (e) {
      SafeLog.d('permission policy restart failed', e);
      lastError = 'Could not switch to ${policy.label}: $e';
      reconnecting = false;
      notifyListeners();
      rethrow;
    } finally {
      _restartingForPolicy = false;
    }
  }

  Future<void> setMode(AgentSessionMode mode) async {
    preferredMode = mode;
    await _session.setMode(mode);
    notifyListeners();
  }

  void resolvePermission(Object requestId, String optionId) {
    _session.resolvePermission(requestId, optionId);
    if (pendingPermission?.requestId == requestId) {
      pendingPermission = null;
      notifyListeners();
    }
  }

  /// Load the model catalogue when we resumed an agent that was already running.
  Future<void> ensureModelCatalog(List<Map<String, dynamic>> mcpServers) async {
    if (isWorking) return;
    await _session.ensureModelCatalog(mcpServers: mcpServers);
    notifyListeners();
  }

  /// Switch model and remember it, so reconnects and restarts keep the choice.
  Future<void> setModel(String modelId) async {
    await _session.setModel(modelId);
    final meta = chatMeta;
    if (meta != null) {
      chatMeta = meta.copyWith(modelId: modelId, updatedAt: DateTime.now());
      await _db.upsertChat(chatMeta!);
      onLocalChange?.call(chatId);
    } else {
      final stored = await _db.getChat(chatId);
      if (stored != null) {
        chatMeta = stored.copyWith(modelId: modelId, updatedAt: DateTime.now());
        await _db.upsertChat(chatMeta!);
        onLocalChange?.call(chatId);
      }
    }
    notifyListeners();
  }

  Future<void> prompt(String text, {List<ChatImageRef> images = const []}) =>
      enqueueOrPrompt(text, images: images);

  /// Append the user message, then either start a turn or queue it.
  ///
  /// While a turn is in flight the new message is persisted and kept in
  /// [outboundQueue] only — it is *not* spliced into [entries] mid-turn, so
  /// continuing agent output cannot bury it. The chat UI paints queued bubbles
  /// after the live agent bubble. When the turn finishes (or Force run fires)
  /// the message is promoted into [entries] and then sent.
  Future<void> enqueueOrPrompt(
    String text, {
    List<ChatImageRef> images = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && images.isEmpty) return;

    final content = ChatImageCodec.encodeMessage(
      text: trimmed,
      images: images,
    );

    final message = ChatMessage(
      id: const Uuid().v4(),
      chatId: chatId,
      role: MessageRole.user,
      content: content,
      createdAt: DateTime.now(),
    );

    if (promptInFlight || (closed && sessionFactory != null)) {
      outboundQueue.add(message);
      _writesInFlight++;
      try {
        await _db.insertMessage(message);
        await _persistOutboundQueue();
        onLocalChange?.call(chatId);
      } catch (e) {
        SafeLog.d('persist queued message failed', e);
      } finally {
        _writesInFlight--;
      }
      notifyListeners();
      // Bridge is down — wake it when we can so the queue drains.
      if (closed && !_suspended && sessionFactory != null) {
        _scheduleReconnect(immediate: true);
      }
      return;
    }

    // Stale "running on host" after reconnect — user is starting a new turn.
    if (remoteTurnActive) {
      remoteTurnActive = false;
      _clearHostBusyWatchdog();
    }

    // A previous Force run / cancel may have left the chain wedged. Never park
    // a fresh send behind a future that will never complete.
    await _promptTail.timeout(
      const Duration(seconds: 2),
      onTimeout: _breakPromptChain,
    );

    // Finish any leftover text from the previous turn before the new user
    // bubble, otherwise a late flush lands *under* the question with an older
    // clock and the thread looks scrambled.
    await flushAssistantBuffer();
    await commitThought();

    await appendUserMessage(message);
    // Do not await the turn — the composer must unlock as soon as the
    // message is accepted. The runtime keeps driving the prompt.
    unawaited(
      _runPrompt(
        content,
        userMessageId: message.id,
        userCreatedAt: message.createdAt,
      ),
    );
  }

  /// Interrupt the current turn and run the next queued message immediately.
  ///
  /// If [messageId] is set, that queued item is preferred; otherwise the head
  /// of the queue. The cancelled turn's partial answer is kept in the
  /// transcript.
  Future<void> forceRun({String? messageId}) async {
    ChatMessage? target;
    if (messageId != null) {
      final idx = outboundQueue.indexWhere((m) => m.id == messageId);
      if (idx >= 0) target = outboundQueue.removeAt(idx);
    } else if (outboundQueue.isNotEmpty) {
      target = outboundQueue.removeAt(0);
    }
    if (target == null) {
      notifyListeners();
      return;
    }

    // Promote first so the bubble never vanishes if cancel/prompt hangs.
    await _persistOutboundQueue();
    await _promoteQueuedMessage(target);
    notifyListeners();

    _skipAutoDrain = true;
    try {
      if (promptInFlight) {
        try {
          await _session.cancel().timeout(const Duration(seconds: 4));
        } catch (e) {
          SafeLog.d('cancel before force-run failed', e);
        }
        await flushAssistantBuffer();
        await commitThought();
        _breakPromptChain();
        notifyListeners();
      } else {
        await _promptTail.timeout(
          const Duration(seconds: 2),
          onTimeout: _breakPromptChain,
        );
      }
    } finally {
      _skipAutoDrain = false;
    }

    await _runPrompt(
      target.content,
      userMessageId: target.id,
      userCreatedAt: target.createdAt,
    );
  }

  Future<void> removeFromQueue(String messageId) async {
    final before = outboundQueue.length;
    outboundQueue.removeWhere((m) => m.id == messageId);
    if (outboundQueue.length == before) return;
    notifyListeners();
    try {
      await _persistOutboundQueue();
      await _db.deleteMessage(messageId);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('delete queued message failed', e);
    }
  }

  /// Move a queued message into the visible transcript, stamped *now* so it
  /// sorts after the turn that just finished.
  Future<void> _promoteQueuedMessage(ChatMessage message) async {
    if (entries.any((e) => e.messageId == message.id)) return;
    final stamped = ChatMessage(
      id: message.id,
      chatId: message.chatId,
      role: message.role,
      content: message.content,
      createdAt: DateTime.now(),
    );
    entries.add(TranscriptEntry.message(stamped));
    _writesInFlight++;
    try {
      await _db.upsertMessage(stamped);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('promote queued message failed', e);
    } finally {
      _writesInFlight--;
    }
    notifyListeners();
  }

  Future<void> _runPrompt(
    String text, {
    String? userMessageId,
    DateTime? userCreatedAt,
  }) {
    // Chain onto the previous turn so cancel+force-run cannot start a second
    // session/prompt while the first await is still unwinding.
    final epoch = _promptEpoch;
    final run = _promptTail.then((_) {
      if (epoch != _promptEpoch) return Future<void>.value();
      return _runPromptBody(
        text,
        userMessageId: userMessageId,
        userCreatedAt: userCreatedAt,
      );
    });
    _promptTail = run.catchError((Object _) {});
    return run;
  }

  Future<void> _runPromptBody(
    String content, {
    String? userMessageId,
    DateTime? userCreatedAt,
  }) async {
    if (_disposed || closed) return;
    final epoch = _promptEpoch;
    remoteTurnActive = false;
    _clearHostBusyWatchdog();
    promptInFlight = true;
    activityLabel = 'Thinking';
    _lastHostActivityAt = DateTime.now();
    _armHostBusyWatchdog();
    notifyListeners();
    var transportFailed = false;
    try {
      await flushAssistantBuffer();
      final payload = await ChatImageCodec.toPromptPayload(content);
      await _session.prompt(
        payload.text,
        images: payload.images,
        userMessageId: userMessageId,
        userCreatedAt: userCreatedAt,
      );
      // If the model only wrote to the thought channel, surface that as the
      // answer instead of leaving a blank agent turn with orphaned notes.
      if (assistantBuffer.trim().isEmpty && thoughtBuffer.trim().isNotEmpty) {
        assistantBuffer = thoughtBuffer;
        thoughtBuffer = '';
      }
      await flushAssistantBuffer();
      await commitThought();
    } catch (e) {
      SafeLog.d('prompt failed', e);
      // Late failure from a session that Force-run / reconnect already replaced.
      if (epoch != _promptEpoch) {
        transportFailed = true;
      } else if (isTransientBridgeError(e)) {
        // Quiet reconnect — do not leave "Bad state: ADSM channel closed" up.
        lastError = null;
        transportFailed = true;
        if (!closed && sessionFactory != null) {
          closed = true;
          _scheduleReconnect(immediate: true);
        }
      } else {
        lastError = e.toString();
        transportFailed = true;
        // Dead bridge / silence timeout — recover so the next send is not wedged.
        if (!closed && sessionFactory != null) {
          closed = true;
          _scheduleReconnect(immediate: true);
        }
      }
    } finally {
      // Superseded by Force run / reconnect — do not touch shared state.
      final superseded = epoch != _promptEpoch;
      if (!superseded) {
        if (closed && !transportFailed) {
          // Bridge dropped via background handoff. Durable host may still be
          // mid-turn — keep the working indicator until idle arrives.
          remoteTurnActive = true;
          promptInFlight = false;
          _armHostBusyWatchdog();
          notifyListeners();
        } else {
          promptInFlight = false;
          remoteTurnActive = false;
          _clearHostBusyWatchdog();
          notifyListeners();
          if (!closed) _drainOutboundQueue();
        }
      }
    }
  }

  /// Live journal output means the host is still on a turn — even when we did
  /// not send this prompt from the phone (reconnect mid-run, cold attach).
  void _noteHostActivity() {
    _lastHostActivityAt = DateTime.now();
    if (!promptInFlight) {
      promptInFlight = true;
      remoteTurnActive = true;
    }
    // Always re-arm — previously we skipped this while session/prompt was open,
    // so a tool left "in_progress" after the answer finished could choke forever.
    _armHostBusyWatchdog();
  }

  void _armHostBusyWatchdog() {
    _hostBusyWatchdog?.cancel();
    _hostBusyWatchdog = Timer(const Duration(seconds: 15), () {
      if (_disposed) return;
      if (!isWorking) return;

      final silentFor = _lastHostActivityAt == null
          ? const Duration(days: 1)
          : DateTime.now().difference(_lastHostActivityAt!);

      // Tool rows stuck pending/running with no new ACP events. Common after
      // ADSM clears the activity label ("") while session/prompt is still open.
      if (hasActiveTools && silentFor >= const Duration(seconds: 20)) {
        unawaited(_finalizeStaleTools(reason: 'watchdog-silent-tools'));
        return;
      }

      // Hung on "Thinking" with no tools and no host events — e.g. image
      // prompt stalled inside Cursor / ADSM. Cancel so the UI unlocks.
      if (_session.isPromptActive &&
          !hasActiveTools &&
          silentFor >= const Duration(seconds: 75)) {
        SafeLog.d(
          'watchdog: silent prompt ${silentFor.inSeconds}s chat=$chatId — unstick',
        );
        unawaited(_watchdogUnstickPrompt());
        return;
      }

      // Local prompt still awaiting a real ACP result — keep waiting.
      if (_session.isPromptActive && !hasActiveTools) {
        _armHostBusyWatchdog();
        return;
      }

      if (hasActiveTools) {
        unawaited(_finalizeStaleTools(reason: 'watchdog'));
        return;
      }

      // Silence after reconnect: host likely finished while we were away.
      remoteTurnActive = false;
      promptInFlight = false;
      notifyListeners();
      if (!closed) _drainOutboundQueue();
    });
  }

  Future<void> _watchdogUnstickPrompt() async {
    try {
      await _session.cancel().timeout(const Duration(seconds: 5));
    } catch (e) {
      SafeLog.d('watchdog prompt cancel failed', e);
    }
    await flushAssistantBuffer();
    await commitThought();
    _breakPromptChain();
    promptInFlight = false;
    remoteTurnActive = false;
    activityLabel = null;
    lastError =
        'Agent went quiet with no reply (often a large image or a stuck turn). '
        'Tap Stop if it hangs again, or resend with a smaller screenshot.';
    notifyListeners();
    if (!closed) _drainOutboundQueue();
  }

  /// Mark leftover pending/running tools finished so [isWorking] can clear.
  Future<void> _finalizeStaleTools({required String reason}) async {
    final active = [
      for (final e in entries)
        if (e.tool?.isActive ?? false) e.tool!,
    ];
    if (active.isEmpty) {
      remoteTurnActive = false;
      // Don't clear promptInFlight while session/prompt is genuinely open —
      // only release the UI busy flags that tools were holding.
      if (!_session.isPromptActive) promptInFlight = false;
      activityLabel = null;
      notifyListeners();
      if (!closed && !promptInFlight) _drainOutboundQueue();
      return;
    }
    SafeLog.d('finalizing ${active.length} stale tool(s) ($reason) chat=$chatId');
    for (final tool in active) {
      await _upsertTool(
        tool.merge(status: 'completed', rawOutput: tool.rawOutput ?? ''),
      );
    }
    remoteTurnActive = false;
    activityLabel = null;
    if (!_session.isPromptActive) {
      promptInFlight = false;
    } else {
      // Prompt RPC still open, but stop advertising a phantom tool. Show
      // Thinking until the real end_turn / prompt return arrives.
      activityLabel = 'Thinking';
    }
    notifyListeners();
    if (!closed && !promptInFlight) _drainOutboundQueue();
  }

  void _clearHostBusyWatchdog() {
    _hostBusyWatchdog?.cancel();
    _hostBusyWatchdog = null;
  }

  /// User-facing unblock when the UI is stuck on "Agent is working".
  Future<void> unstick() async {
    _clearHostBusyWatchdog();
    remoteTurnActive = false;
    try {
      if (_session.isPromptActive) {
        await _session.cancel().timeout(const Duration(seconds: 3));
      }
    } catch (e) {
      SafeLog.d('unstick cancel failed', e);
    }
    if (hasActiveTools) {
      await _finalizeStaleTools(reason: 'unstick');
    }
    await flushAssistantBuffer();
    await commitThought();
    _breakPromptChain();
    promptInFlight = false;
    lastError = null;
    notifyListeners();
    if (closed && sessionFactory != null && !_suspended) {
      _scheduleReconnect(immediate: true);
    } else {
      _drainOutboundQueue();
    }
  }

  void _onUpdate(AcpUpdate update) {
    switch (update.kind) {
      case AcpUpdateKind.ignored:
        break;
      case AcpUpdateKind.status:
        if (update.title != null &&
            update.title!.isNotEmpty &&
            chatMeta != null) {
          chatMeta = chatMeta!.copyWith(
            title: update.title,
            updatedAt: DateTime.now(),
          );
          unawaited(_db.upsertChat(chatMeta!));
          onLocalChange?.call(chatId);
        }
        notifyListeners();
      case AcpUpdateKind.activity:
        final label = update.text.trim();
        activityLabel = label.isEmpty ? null : label;
        if (activityLabel != null) {
          _noteHostActivity();
        } else if (hasActiveTools) {
          // ADSM clears the activity chip when writing stops, but tool rows
          // often stay "in_progress". Arm the silence watchdog so we unstick.
          _armHostBusyWatchdog();
        }
        notifyListeners();
      case AcpUpdateKind.mode:
        notifyListeners();
      case AcpUpdateKind.delta:
        _noteHostActivity();
        activityLabel ??= 'Writing';
        if (thoughtBuffer.isNotEmpty) {
          unawaited(commitThought());
        }
        assistantBuffer += update.text;
        if (update.text.trim().isNotEmpty) {
          onAssistantText?.call(update.text);
        }
        _scheduleAssistantPersist();
        notifyListeners();
      case AcpUpdateKind.thought:
        _noteHostActivity();
        activityLabel ??= 'Thinking';
        if (assistantBuffer.isNotEmpty) {
          unawaited(flushAssistantBuffer());
        }
        thoughtBuffer += update.text;
        notifyListeners();
      case AcpUpdateKind.tool:
        final tool = update.tool;
        if (tool == null) break;
        _noteHostActivity();
        if (tool.isActive) {
          activityLabel = tool.displayTitle;
        }
        if (assistantBuffer.isNotEmpty) {
          unawaited(flushAssistantBuffer());
        }
        if (thoughtBuffer.isNotEmpty) {
          unawaited(commitThought());
        }
        unawaited(_upsertTool(tool));
      case AcpUpdateKind.permission:
        pendingPermission = update.permissionRequest;
        activityLabel = 'Waiting for permission';
        notifyListeners();
      case AcpUpdateKind.error:
        lastError = update.text;
        notifyListeners();
      case AcpUpdateKind.closed:
        // Unlock the composer immediately — a hanging prompt would otherwise
        // keep the spinner up while reconnect runs underneath.
        if (promptInFlight && !remoteTurnActive) {
          promptInFlight = false;
        }
        activityLabel = null;
        unawaited(flushAssistantBuffer());
        unawaited(commitThought());
        closed = true;
        if (sessionFactory != null) {
          // Recover quietly. A suspended runtime reconnects from resume()
          // instead, so in neither case is there anything for the user to do.
          // Intentional Ask ↔ Full access recycle handles its own reconnect.
          if (!_suspended && !_restartingForPolicy) _scheduleReconnect();
        }
        // No "tap Reconnect" nag — auto-reconnect handles it when possible.
        notifyListeners();
      case AcpUpdateKind.turnComplete:
        // Flush is awaited in _runPromptBody after session/prompt returns.
        // Clearing promptInFlight here while a local await is open lets a new
        // send race ahead — only clear UI busy when nothing owns the prompt.
        _clearHostBusyWatchdog();
        remoteTurnActive = false;
        activityLabel = null;
        if (hasActiveTools) {
          // end_turn with rows still "in_progress" — agent will not send more
          // updates for them. Finalize so the UI does not choke forever.
          unawaited(_finalizeStaleTools(reason: 'turnComplete'));
        } else if (!_session.isPromptActive) {
          promptInFlight = false;
          notifyListeners();
          if (!closed) _drainOutboundQueue();
        } else {
          notifyListeners();
        }
        break;
    }
  }

  void _drainOutboundQueue() {
    if (_skipAutoDrain ||
        _disposed ||
        closed ||
        promptInFlight ||
        outboundQueue.isEmpty) {
      return;
    }
    final next = outboundQueue.removeAt(0);
    unawaited(_persistOutboundQueue());
    notifyListeners();
    unawaited(() async {
      await _promoteQueuedMessage(next);
      await _runPrompt(
        next.content,
        userMessageId: next.id,
        userCreatedAt: next.createdAt,
      );
    }());
  }

  Future<void> commitThought() async {
    final text = thoughtBuffer.trim();
    thoughtBuffer = '';
    if (text.isEmpty) {
      notifyListeners();
      return;
    }
    final message = ChatMessage(
      id: const Uuid().v4(),
      chatId: chatId,
      role: MessageRole.system,
      content: ThoughtMessage.encode(text),
      createdAt: DateTime.now(),
    );
    entries.add(TranscriptEntry.message(message));
    _writesInFlight++;
    try {
      await _db.insertMessage(message);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('persist thought failed', e);
    } finally {
      _writesInFlight--;
    }
    notifyListeners();
  }

  /// Checkpoint the streaming turn to disk shortly after output stops arriving.
  ///
  /// Without this the whole answer lives only in memory until the turn ends, so
  /// a crash, a prompt timeout, or the process being killed loses everything
  /// the user could already read on screen.
  void _scheduleAssistantPersist() {
    _assistantPersistTimer?.cancel();
    _assistantPersistTimer = Timer(const Duration(milliseconds: 700), () {
      _assistantPersistTimer = null;
      unawaited(_writeAssistantProgress());
    });
  }

  Future<void> flushAssistantBuffer() async {
    _assistantPersistTimer?.cancel();
    _assistantPersistTimer = null;
    final text = assistantBuffer.trim();
    assistantBuffer = '';
    if (text.isEmpty) {
      // A checkpointed row with no final text would be an empty bubble.
      _assistantMessageId = null;
      _assistantStartedAt = null;
      notifyListeners();
      return;
    }
    final message = _assistantSnapshot(text);
    _assistantMessageId = null;
    _assistantStartedAt = null;
    _upsertAssistantEntry(message);
    _writesInFlight++;
    try {
      await _db.upsertMessage(message);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('persist assistant failed', e);
    } finally {
      _writesInFlight--;
    }
    notifyListeners();
  }

  /// Keep the live answer in [entries] as it grows so the bubble does not
  /// vanish when [isWorking] clears a tick before [flushAssistantBuffer].
  void _upsertAssistantEntry(ChatMessage message) {
    final index = entries.indexWhere((e) => e.messageId == message.id);
    if (index >= 0) {
      entries[index] = TranscriptEntry.message(message);
    } else {
      entries.add(TranscriptEntry.message(message));
    }
  }

  /// The in-progress turn as a row. Id and timestamp are stable for the whole
  /// turn so repeated writes land on the same message.
  ChatMessage _assistantSnapshot(String text) {
    return ChatMessage(
      id: _assistantMessageId ??= const Uuid().v4(),
      chatId: chatId,
      role: MessageRole.assistant,
      content: text,
      createdAt: _assistantStartedAt ??= DateTime.now(),
    );
  }

  Future<void> _writeAssistantProgress() async {
    final text = assistantBuffer.trim();
    if (text.isEmpty) return;
    final message = _assistantSnapshot(text);
    _upsertAssistantEntry(message);
    notifyListeners();
    _writesInFlight++;
    try {
      await _db.upsertMessage(message);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('checkpoint assistant failed', e);
    } finally {
      _writesInFlight--;
    }
  }

  Future<void> _upsertTool(ToolCallState tool) async {
    final index = entries.indexWhere((e) => e.tool?.toolCallId == tool.toolCallId);
    if (index >= 0) {
      final prev = entries[index].tool!;
      final merged = prev.merge(
        title: tool.title,
        kind: tool.kind,
        status: tool.status,
        locations: tool.locations.isEmpty ? null : tool.locations,
        rawInput: tool.rawInput,
        rawOutput: tool.rawOutput,
        content: tool.content,
      );
      final msgId = entries[index].messageId ?? _toolMessageIds[tool.toolCallId];
      entries[index] = TranscriptEntry.tool(
        merged,
        messageId: msgId,
        createdAt: entries[index].createdAt,
      );
      if (msgId != null) {
        final message = ChatMessage(
          id: msgId,
          chatId: chatId,
          role: MessageRole.tool,
          content: jsonEncode(merged.toJson()),
          createdAt: DateTime.now(),
        );
        try {
          await _db.updateMessage(message);
          onLocalChange?.call(chatId);
        } catch (e) {
          SafeLog.d('update tool message failed', e);
        }
      }
    } else {
      final msgId = const Uuid().v4();
      _toolMessageIds[tool.toolCallId] = msgId;
      entries.add(TranscriptEntry.tool(tool, messageId: msgId));
      final message = ChatMessage(
        id: msgId,
        chatId: chatId,
        role: MessageRole.tool,
        content: jsonEncode(tool.toJson()),
        createdAt: DateTime.now(),
      );
      try {
        await _db.insertMessage(message);
        onLocalChange?.call(chatId);
      } catch (e) {
        SafeLog.d('insert tool message failed', e);
      }
    }
    _scheduleCodeDeltaPersist();
    notifyListeners();
  }

  void _scheduleCodeDeltaPersist() {
    _codeDeltaPersistTimer?.cancel();
    _codeDeltaPersistTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_persistCodeDelta());
    });
  }

  Future<void> _persistCodeDelta() async {
    if (_disposed) return;
    final stats = codeDelta;
    final meta = chatMeta;
    if (meta == null) return;
    // Never shrink: a partial hydrate (tools not yet restored) used to wipe
    // the Δ line by writing zeros over a good session total.
    final added = stats.added > meta.linesAdded ? stats.added : meta.linesAdded;
    final removed =
        stats.removed > meta.linesRemoved ? stats.removed : meta.linesRemoved;
    final files = stats.fileCount > meta.filesChanged
        ? stats.fileCount
        : meta.filesChanged;
    if (meta.linesAdded == added &&
        meta.linesRemoved == removed &&
        meta.filesChanged == files) {
      return;
    }
    final updated = meta.copyWith(
      linesAdded: added,
      linesRemoved: removed,
      filesChanged: files,
      updatedAt: DateTime.now(),
    );
    chatMeta = updated;
    try {
      await _db.upsertChat(updated);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('persist code delta failed', e);
    }
    notifyListeners();
  }

  Future<void> appendUserMessage(ChatMessage message) async {
    entries.add(TranscriptEntry.message(message));
    await _db.insertMessage(message);
    onLocalChange?.call(chatId);
    notifyListeners();
  }

  Future<void> disposeRuntime() async {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _clearHostBusyWatchdog();
    _assistantPersistTimer?.cancel();
    _assistantPersistTimer = null;
    _codeDeltaPersistTimer?.cancel();
    _codeDeltaPersistTimer = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await flushAssistantBuffer();
      await commitThought();
    } catch (_) {}
    await _session.close();
  }
}
