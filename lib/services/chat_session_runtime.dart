import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import '../data/models/turn_stats_message.dart';
import '../data/secure/safe_log.dart';
import 'adsm_client.dart';
import 'agent_session.dart';
import 'cursor_acp_service.dart';
import 'ssh_service.dart';
import 'transcript_budget.dart';

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
  }) => TranscriptEntry._(
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
    this.shouldAutoReconnect,
  }) : _session = session,
       _db = db,
       preferredMode = session.mode,
       preferredPermissionPolicy = session.permissionPolicy;

  /// Maximum automatic attempts before we stop and wait for the user.
  static const maxReconnectAttempts = 10;
  static const _maxBackoff = Duration(seconds: 30);

  /// Runtime/UI memory is a live tail, not the transcript archive. SQLite and
  /// the host remain authoritative for older history.
  ///
  /// Soft cap is ~1 MiB of content; users can expand with explicit "load more".
  static const residentTranscriptLimit = 900;
  static const residentTranscriptBytes = kTranscriptChunkBytes;
  static const transcriptPushTail = 64;

  final String chatId;
  final AppDatabase _db;
  final void Function(String chatId)? onLocalChange;

  /// Fired after a successful [replaceSession] so owners can bump UI state.
  final void Function(String chatId)? onTransportReady;

  /// Local notify hook for assistant text deltas (not tools/thoughts).
  final void Function(String snippet)? onAssistantText;

  /// Background chats are host-durable and do not need to fight for a new SSH
  /// transport. The owner allows retries only while this chat is focused.
  final bool Function()? shouldAutoReconnect;

  /// Opens a fresh transport for this chat. Set by the owner so the runtime can
  /// recover on its own after a drop, even with no chat screen mounted.
  Future<AgentSession> Function()? sessionFactory;

  AgentSession _session;
  StreamSubscription<AcpUpdate>? _sub;

  final List<TranscriptEntry> entries = [];
  final Map<String, String> _toolMessageIds = {};
  final Map<String, int> _toolEntryIndexes = {};
  final Set<String> _activeToolIds = {};
  final _random = Random();

  /// How many bytes of archive the UI is allowed to keep mounted.
  /// Starts at one chunk; each "load earlier" adds another chunk.
  int displayBudgetBytes = kTranscriptChunkBytes;

  /// Host/SQLite still has messages older than the current [entries] head.
  bool hasMoreOlder = false;

  /// Serializes tool upserts so parallel tool_call / tool_call_update events
  /// cannot insert two SQLite rows for the same toolCallId.
  Future<void> _toolUpsertTail = Future<void>.value();
  final Map<String, ToolCallState> _pendingToolUpdates = {};
  Timer? _toolFlushTimer;

  StringBuffer _assistantText = StringBuffer();
  String? _assistantTextCache = '';
  StringBuffer _thoughtText = StringBuffer();
  String? _thoughtTextCache = '';

  String get assistantBuffer =>
      _assistantTextCache ??= _assistantText.toString();

  set assistantBuffer(String value) {
    _assistantText = StringBuffer(value);
    _assistantTextCache = value;
  }

  String get thoughtBuffer => _thoughtTextCache ??= _thoughtText.toString();

  set thoughtBuffer(String value) {
    _thoughtText = StringBuffer(value);
    _thoughtTextCache = value;
  }

  void _appendAssistantText(String value) {
    _assistantText.write(value);
    _assistantTextCache = null;
  }

  void _appendThoughtText(String value) {
    _thoughtText.write(value);
    _thoughtTextCache = null;
  }

  /// Row id for the agent turn currently streaming, so progressive writes
  /// update one message instead of appending fragments.
  String? _assistantMessageId;
  DateTime? _assistantStartedAt;
  Timer? _assistantPersistTimer;
  Timer? _codeDeltaPersistTimer;
  int _writesInFlight = 0;

  /// Id of the assistant row currently mirrored from [assistantBuffer], if any.
  String? get liveAssistantMessageId =>
      assistantBuffer.isEmpty ? null : _assistantMessageId;

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

  /// User message is on its way to ADSM (before host ack).
  bool sendingToHost = false;

  /// Last delivery failure for the UI snackbar / banner.
  String? deliveryError;

  /// True while a local prompt is in flight, the host is still producing, or
  /// any tool call is still pending/running — so the UI stays on "working"
  /// through long tool chains, not only while text is streaming.
  bool get hasActiveTools => _activeToolIds.isNotEmpty;

  /// Active tool summaries for chrome labels (no full-list scan).
  List<ToolCallState> get activeToolSummaries {
    if (_activeToolIds.isEmpty) return const [];
    final out = <ToolCallState>[];
    for (final e in entries) {
      final tool = e.tool;
      if (tool == null) continue;
      if (_activeToolIds.contains(tool.toolCallId)) out.add(tool);
    }
    return out;
  }

  bool get isWorking =>
      !reconnecting &&
      (sendingToHost || promptInFlight || remoteTurnActive || hasActiveTools);

  /// Live code churn from edit/write tools since local midnight.
  CodeChangeStats get codeDelta =>
      CodeChangeStats.fromTools(_toolsSinceStartOfLocalDay());

  /// Code churn for the open turn (since last user message).
  CodeChangeStats get turnCodeDelta =>
      CodeChangeStats.fromTools(_toolsSinceLastUserMessage());

  /// Latest ACP context-window reading (`usage_update`).
  int? usageTokensUsed;
  int? usageContextSize;

  /// Cheap explore chip — summaries only (no raw I/O re-scan).
  ExploreStats get turnExploreStats =>
      ExploreStats.fromTools(_toolSummariesSinceLastUserMessage());

  Iterable<ToolCallState> _toolsSinceStartOfLocalDay() sync* {
    final start = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    for (final e in entries) {
      final tool = e.tool;
      if (tool == null) continue;
      final at = e.createdAt;
      if (at != null && at.isBefore(start)) continue;
      yield _payloadOrSummary(tool)!;
    }
  }

  /// Reads + searches since the last user message (current turn).
  /// Uses UI summaries — enough for explore chips without decoding payloads.
  Iterable<ToolCallState> _toolSummariesSinceLastUserMessage() sync* {
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
      if (tool != null) yield _payloadOrSummary(tool)!;
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

  /// User message was accepted locally but not confirmed delivered to the host.
  /// Kept sticky across reconnect so we retry instead of silently dropping it.
  bool _needsRedelivery = false;

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

  /// Coalesce high-frequency ACP updates so agents sidebar / chat listeners
  /// are not rebuilt on every token.
  Timer? _uiNotifyCoalesce;
  bool _uiNotifyDirty = false;

  /// Push UI listeners. High-rate stream events use a short coalesce window;
  /// structural / error / permission changes flush immediately.
  void _notifyUi({bool immediate = false}) {
    if (_disposed) return;
    if (immediate) {
      _uiNotifyCoalesce?.cancel();
      _uiNotifyCoalesce = null;
      _uiNotifyDirty = false;
      notifyListeners();
      return;
    }
    _uiNotifyDirty = true;
    if (_uiNotifyCoalesce?.isActive ?? false) return;
    _uiNotifyCoalesce = Timer(const Duration(milliseconds: 150), () {
      _uiNotifyCoalesce = null;
      if (_disposed || !_uiNotifyDirty) return;
      _uiNotifyDirty = false;
      notifyListeners();
    });
  }

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

  /// Full tool payloads kept off the UI transcript — used for code/explore
  /// stats only. Expand loads details from ADSM / SQLite instead.
  final Map<String, ToolCallState> _toolPayloads = {};

  void _rememberToolPayload(ToolCallState tool) {
    if (!tool.hasPayloads) return;
    _toolPayloads[tool.toolCallId] = tool;
    // Cap payload cache — tool-spam turns used to pin tens of MB on the UI
    // isolate and stall GC on Mac.
    const maxCached = 40;
    if (_toolPayloads.length <= maxCached) return;
    final keep = <String>{
      ..._activeToolIds,
      for (final e in entries.reversed)
        if (e.tool != null) e.tool!.toolCallId,
    };
    final drop = <String>[];
    for (final id in _toolPayloads.keys) {
      if (!keep.contains(id)) drop.add(id);
      if (_toolPayloads.length - drop.length <= maxCached) break;
    }
    for (final id in drop) {
      _toolPayloads.remove(id);
    }
    while (_toolPayloads.length > maxCached) {
      _toolPayloads.remove(_toolPayloads.keys.first);
    }
  }

  void _trackToolActivity(ToolCallState tool) {
    if (tool.isActive) {
      _activeToolIds.add(tool.toolCallId);
    } else {
      _activeToolIds.remove(tool.toolCallId);
    }
  }

  /// Persist-ready full tool; UI-resident copy has no raw I/O blobs.
  ToolCallState _uiToolSummary(ToolCallState tool) {
    _rememberToolPayload(tool);
    _trackToolActivity(tool);
    return tool.withoutPayloads();
  }

  ToolCallState? _payloadOrSummary(ToolCallState? tool) {
    if (tool == null) return null;
    return _toolPayloads[tool.toolCallId] ?? tool;
  }

  void hydrateFromMessages(List<ChatMessage> messages) {
    entries.clear();
    _toolMessageIds.clear();
    _toolEntryIndexes.clear();
    _toolPayloads.clear();
    _activeToolIds.clear();
    final queuedIds = {for (final m in outboundQueue) m.id};
    final seenToolIds = <String>{};
    for (final m in messages) {
      if (queuedIds.contains(m.id)) continue;
      if (m.role == MessageRole.tool) {
        final tool = ToolCallState.tryParseContent(m.content);
        if (tool != null) {
          final tid = tool.toolCallId;
          if (seenToolIds.contains(tid)) {
            // Prefer the later row (usually a richer status/output update).
            final index = _toolEntryIndexes[tid] ?? -1;
            if (index >= 0) {
              final prev = entries[index].tool!;
              final orphanId = entries[index].messageId;
              final merged = prev.merge(
                title: tool.title,
                kind: tool.kind,
                status: tool.status,
                locations: tool.locations.isEmpty ? null : tool.locations,
                rawInput: tool.rawInput,
                rawOutput: tool.rawOutput,
                content: tool.content,
              );
              entries[index] = TranscriptEntry.tool(
                _uiToolSummary(merged),
                messageId: m.id,
                createdAt: entries[index].createdAt ?? m.createdAt,
              );
              _toolMessageIds[tid] = m.id;
              if (orphanId != null && orphanId != m.id) {
                unawaited(() async {
                  try {
                    await _db.deleteMessage(orphanId);
                  } catch (e) {
                    SafeLog.d('delete dup tool on load failed', e);
                  }
                }());
              }
            }
            continue;
          }
          seenToolIds.add(tid);
          entries.add(
            TranscriptEntry.tool(
              _uiToolSummary(tool),
              messageId: m.id,
              createdAt: m.createdAt,
            ),
          );
          _toolEntryIndexes[tid] = entries.length - 1;
          _toolMessageIds[tid] = m.id;
          continue;
        }
      }
      entries.add(TranscriptEntry.message(m));
    }
    _trimResidentTranscript();
    _scheduleCodeDeltaPersist();
    _notifyUi(immediate: true);
  }

  /// Merge remote/local DB rows into the live transcript without clearing
  /// in-flight assistant or thought buffers.
  void absorbMessages(List<ChatMessage> messages) {
    final queuedIds = {for (final m in outboundQueue) m.id};
    final messageIndex = <String, int>{};
    final toolIndex = <String, int>{};
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final messageId = entry.messageId;
      if (messageId != null) messageIndex[messageId] = i;
      final toolId = entry.tool?.toolCallId;
      if (toolId != null) toolIndex[toolId] = i;
    }

    for (final m in messages) {
      if (queuedIds.contains(m.id)) continue;
      if (m.role == MessageRole.tool) {
        final tool = ToolCallState.tryParseContent(m.content);
        if (tool == null) continue;
        final index = toolIndex[tool.toolCallId] ?? -1;
        if (index >= 0) {
          final prevFull =
              _payloadOrSummary(entries[index].tool!) ?? entries[index].tool!;
          final merged = prevFull.merge(
            title: tool.title,
            kind: tool.kind,
            status: tool.status,
            locations: tool.locations.isEmpty ? null : tool.locations,
            rawInput: tool.rawInput,
            rawOutput: tool.rawOutput,
            content: tool.content,
          );
          entries[index] = TranscriptEntry.tool(
            _uiToolSummary(merged),
            messageId: entries[index].messageId ?? m.id,
            createdAt: entries[index].createdAt ?? m.createdAt,
          );
        } else {
          entries.add(
            TranscriptEntry.tool(
              _uiToolSummary(tool),
              messageId: m.id,
              createdAt: m.createdAt,
            ),
          );
          toolIndex[tool.toolCallId] = entries.length - 1;
          _toolEntryIndexes[tool.toolCallId] = entries.length - 1;
          messageIndex[m.id] = entries.length - 1;
          _toolMessageIds[tool.toolCallId] = m.id;
        }
        continue;
      }
      final index = messageIndex[m.id] ?? -1;
      if (index >= 0) {
        final prev = entries[index].message;
        if (prev != null && m.content.length > prev.content.length) {
          entries[index] = TranscriptEntry.message(m);
        }
      } else {
        entries.add(TranscriptEntry.message(m));
        messageIndex[m.id] = entries.length - 1;
      }
    }
    _trimResidentTranscript();
    _notifyUi(immediate: true);
  }

  void _trimResidentTranscript() {
    final originalOrder = <TranscriptEntry, int>{
      for (var i = 0; i < entries.length; i++) entries[i]: i,
    };
    entries.sort((a, b) {
      final at = a.createdAt;
      final bt = b.createdAt;
      if (at == null && bt == null) {
        return originalOrder[a]!.compareTo(originalOrder[b]!);
      }
      if (at == null) return 1;
      if (bt == null) return -1;
      final byTime = at.compareTo(bt);
      if (byTime != 0) return byTime;
      return originalOrder[a]!.compareTo(originalOrder[b]!);
    });

    var used = 0;
    for (final entry in entries) {
      used += _entryBytes(entry);
    }
    final budget = displayBudgetBytes > 0
        ? displayBudgetBytes
        : residentTranscriptBytes;
    var removed = 0;
    while (entries.length > 1 && used > budget) {
      used -= _entryBytes(entries.first);
      entries.removeAt(0);
      removed++;
      hasMoreOlder = true;
    }
    // Hard safety net against pathological tiny-message floods.
    if (entries.length > residentTranscriptLimit) {
      removed += entries.length - residentTranscriptLimit;
      entries.removeRange(0, entries.length - residentTranscriptLimit);
      hasMoreOlder = true;
    }
    if (removed == 0) {
      _rebuildToolEntryIndexes();
      return;
    }
    final retainedTools = <String, String>{};
    _toolEntryIndexes.clear();
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final toolId = entry.tool?.toolCallId;
      final messageId = entry.messageId;
      if (toolId != null && messageId != null) {
        retainedTools[toolId] = messageId;
        _toolEntryIndexes[toolId] = i;
      }
    }
    _toolMessageIds
      ..clear()
      ..addAll(retainedTools);
    _toolPayloads.removeWhere((id, _) => !retainedTools.containsKey(id));
    _activeToolIds.removeWhere((id) => !retainedTools.containsKey(id));
  }

  bool _residentNeedsTrim() {
    if (entries.length > residentTranscriptLimit) return true;
    // Avoid utf8 + sort on every tool tick; only remeasure when crowded.
    if (entries.length < 120) return false;
    var used = 0;
    for (final entry in entries) {
      used += _entryBytes(entry);
      final budget = displayBudgetBytes > 0
          ? displayBudgetBytes
          : residentTranscriptBytes;
      if (used > budget) return true;
    }
    return false;
  }

  void _maybeTrimResident() {
    if (_residentNeedsTrim()) _trimResidentTranscript();
  }

  int _entryBytes(TranscriptEntry entry) {
    final message = entry.message;
    if (message != null) return chatMessageBytes(message);
    final tool = entry.tool;
    if (tool != null) return toolCallBytes(tool);
    return kTranscriptRowOverheadBytes;
  }

  /// Reset to a single live chunk (e.g. jump-to-latest) and drop older rows.
  void pinDisplayToLiveChunk() {
    displayBudgetBytes = kTranscriptChunkBytes;
    _trimResidentTranscript();
    _notifyUi(immediate: true);
  }

  /// Pull another ~1 MiB of older messages from SQLite / host and prepend.
  ///
  /// Returns how many messages were added.
  Future<int> loadOlderTranscriptChunk() async {
    if (closed) return 0;
    String? beforeId;
    for (final entry in entries) {
      final id = entry.messageId;
      if (id != null && id.isNotEmpty) {
        beforeId = id;
        break;
      }
    }
    if (beforeId == null) {
      hasMoreOlder = false;
      _notifyUi(immediate: true);
      return 0;
    }

    final local = await _db.listOlderMessagesByBytes(
      chatId,
      beforeId: beforeId,
      maxBytes: kTranscriptChunkBytes,
    );
    var older = List<ChatMessage>.from(local.messages);
    var hasMore = local.hasMore;

    final session = _session;
    if (session is AdsmSession) {
      try {
        final remote = await session.pullTranscriptPage(
          maxBytes: kTranscriptChunkBytes,
          beforeId: beforeId,
        );
        if (remote.messages.isNotEmpty) {
          await _db.mergeMessages(chatId, remote.messages);
          // Prefer the merged chronological view from DB for this window.
          final refreshed = await _db.listOlderMessagesByBytes(
            chatId,
            beforeId: beforeId,
            maxBytes: kTranscriptChunkBytes,
          );
          older = List<ChatMessage>.from(refreshed.messages);
          hasMore = refreshed.hasMore || remote.hasMore;
        } else {
          hasMore = hasMore || remote.hasMore;
        }
      } catch (e) {
        SafeLog.d('load older transcript from host failed', e);
      }
    }

    if (older.isEmpty) {
      hasMoreOlder = hasMore;
      _notifyUi(immediate: true);
      return 0;
    }

    displayBudgetBytes += kTranscriptChunkBytes;
    absorbMessages(older);
    hasMoreOlder = hasMore;
    _notifyUi(immediate: true);
    return older.length;
  }

  void _rebuildToolEntryIndexes() {
    _toolEntryIndexes.clear();
    _activeToolIds.clear();
    for (var i = 0; i < entries.length; i++) {
      final tool = entries[i].tool;
      if (tool == null) continue;
      _toolEntryIndexes[tool.toolCallId] = i;
      if (tool.isActive) _activeToolIds.add(tool.toolCallId);
    }
  }

  /// Pull the recent on-disk tail (and queue) into memory after remote sync.
  Future<void> syncTranscriptFromDb() async {
    await restoreOutboundQueue();
    final page = await _db.listRecentMessagesByBytes(
      chatId,
      maxBytes: displayBudgetBytes,
    );
    absorbMessages(page.messages);
    hasMoreOlder = page.hasMore || hasMoreOlder;
  }

  /// Push local SQLite messages into the host ADSM store.
  Future<void> pushTranscriptToHost() async {
    final session = _session;
    if (session is! AdsmSession || closed) return;
    try {
      // ADSM merges by id, so only the mutable live tail needs periodic sync.
      // AgentDockService separately persists the durable archive.
      final local = await _db.listRecentMessages(
        chatId,
        limit: transcriptPushTail,
      );
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
      _notifyUi(immediate: true);
      return;
    }
    final ids = {for (final m in queued) m.id};
    entries.removeWhere(
      (e) => e.messageId != null && ids.contains(e.messageId),
    );
    _rebuildToolEntryIndexes();
    _notifyUi(immediate: true);
  }

  /// If the agent is idle and work is waiting, start the next queued prompt.
  void resumeOutboundQueue() {
    if (_disposed || closed || promptInFlight || outboundQueue.isEmpty) return;
    final next = outboundQueue.removeAt(0);
    unawaited(_persistOutboundQueue());
    _notifyUi(immediate: true);
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
    _sub = _session.updates.listen(
      _onUpdate,
      onError: (Object e) {
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
      },
    );
  }

  void replaceSession(AgentSession session) {
    _sub?.cancel();
    _retryTimer?.cancel();
    _retryTimer = null;
    _clearHostBusyWatchdog();
    final old = _session;
    _session = session;
    if (old != session) {
      unawaited(old.close());
    }
    session.mode = preferredMode;
    session.permissionPolicy = preferredPermissionPolicy;
    pendingPermission = null;
    // An explicit Connect/Send after app suspension owns this new transport.
    // Leaving the runtime marked suspended disabled later recovery even though
    // the replacement session was live.
    _suspended = false;
    closed = false;
    lastError = null;
    reconnecting = false;
    reconnectAttempts = 0;
    // A reconnect must not inherit a hung prompt chain from the dead socket.
    _breakPromptChain();
    // Drop sticky "working / Exploring" from the dead bridge immediately.
    // Host status below can re-assert running if the turn is truly still live.
    remoteTurnActive = false;
    promptInFlight = false;
    sendingToHost = false;
    activityLabel = null;
    if (hasActiveTools) {
      unawaited(_finalizeStaleTools(reason: 'reconnect'));
    }
    // Prefer host snapshot (async refresh) so a live turn re-lights busy chrome.
    if (session is AdsmSession) {
      unawaited(
        session.refreshDaemonStatus(forceEmit: true).then((hostStatus) {
          if (_disposed) return;
          final st = (hostStatus ?? '').toLowerCase();
          if (st == 'idle' || st == 'dead' || st == 'error' || st.isEmpty) {
            remoteTurnActive = false;
            promptInFlight = false;
            sendingToHost = false;
            activityLabel = null;
            if (!_needsRedelivery && outboundQueue.isEmpty) {
              deliveryError = null;
            }
            if (hasActiveTools) {
              unawaited(_finalizeStaleTools(reason: 'reconnect-daemon-$st'));
            }
            notifyListeners();
            if (!closed) resumeOutboundQueue();
          } else if (st == 'running' ||
              st == 'waiting_permission' ||
              st == 'starting') {
            remoteTurnActive = true;
            promptInFlight = true;
            activityLabel = st == 'waiting_permission'
                ? 'Waiting for permission'
                : 'Working on host…';
            _armHostBusyWatchdog();
            notifyListeners();
          }
        }),
      );
    }
    startListening();
    unawaited(rememberSessionId());
    notifyListeners();
    onTransportReady?.call(chatId);
    // Pick up anything that was waiting while the socket was down.
    if (!remoteTurnActive && !promptInFlight) {
      resumeOutboundQueue();
      unawaited(recoverTrailingUserPromptIfStuck());
    }
  }

  /// Force-clear sticky busy chrome, then re-check ADSM if available.
  ///
  /// Used when the user taps Retry / reconnect while the UI still says
  /// "working" after a dead turn.
  Future<void> resyncBusyFromHost() async {
    if (_disposed) return;
    remoteTurnActive = false;
    promptInFlight = false;
    sendingToHost = false;
    activityLabel = null;
    if (hasActiveTools) {
      await _finalizeStaleTools(reason: 'user-resync');
    } else {
      notifyListeners();
    }
    if (_session is! AdsmSession || closed) return;
    final st =
        ((await (_session as AdsmSession).refreshDaemonStatus(
                  forceEmit: true,
                )) ??
                '')
            .toLowerCase();
    if (_disposed) return;
    if (st == 'running' || st == 'waiting_permission' || st == 'starting') {
      remoteTurnActive = true;
      promptInFlight = true;
      activityLabel = st == 'waiting_permission'
          ? 'Waiting for permission'
          : 'Working on host…';
      _armHostBusyWatchdog();
      notifyListeners();
    }
  }

  /// If the transcript ends on a user bubble, the host is idle, and nothing is
  /// queued — the last send likely failed after the bubble was painted. Re-queue
  /// it once so reconnect actually delivers instead of "error then silence".
  Future<void> recoverTrailingUserPromptIfStuck() async {
    if (_disposed ||
        closed ||
        promptInFlight ||
        remoteTurnActive ||
        outboundQueue.isNotEmpty ||
        _session.isPromptActive) {
      return;
    }
    ChatMessage? lastUser;
    for (var i = entries.length - 1; i >= 0; i--) {
      final e = entries[i];
      if (e.tool != null) return;
      final m = e.message;
      if (m == null) continue;
      if (m.role == MessageRole.system) continue;
      if (m.role == MessageRole.assistant) return;
      if (m.role == MessageRole.user) {
        lastUser = m;
        break;
      }
    }
    if (lastUser == null) return;
    // Avoid racing a send that just landed.
    if (DateTime.now().difference(lastUser.createdAt) <
        const Duration(seconds: 12)) {
      return;
    }
    SafeLog.d(
      'recovering undelivered trailing user message '
      '${lastUser.id} chat=$chatId',
    );
    _needsRedelivery = true;
    deliveryError = 'Last message may not have reached the host. Retrying…';
    await _requeueUndeliveredUser(lastUser.id);
    notifyListeners();
    resumeOutboundQueue();
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

  /// Drop a dead ACP resume id and reopen the transport without it.
  Future<void> _recoverFromGoneAcpSession() async {
    try {
      final current = chatMeta ?? await _db.getChat(chatId);
      if (current != null && current.acpSessionId != null) {
        chatMeta = current.copyWith(
          clearAcpSessionId: true,
          updatedAt: DateTime.now(),
        );
        await _db.upsertChat(chatMeta!);
        onLocalChange?.call(chatId);
      }
    } catch (e) {
      SafeLog.d('clear acp session id failed', e);
    }
    if (_session is AdsmSession) {
      (_session as AdsmSession).sessionId = null;
    }
    promptInFlight = false;
    remoteTurnActive = false;
    sendingToHost = false;
    activityLabel = null;
    notifyListeners();
    if (!_suspended && sessionFactory != null && !closed) {
      closed = true;
      _scheduleReconnect(immediate: true);
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

    // If we were mid-delivery, park the user bubble so resume can re-send.
    if (sendingToHost && !_needsRedelivery) {
      ChatMessage? lastUser;
      for (var i = entries.length - 1; i >= 0; i--) {
        final m = entries[i].message;
        if (m == null) continue;
        if (m.role == MessageRole.user) {
          lastUser = m;
          break;
        }
        if (m.role == MessageRole.assistant) break;
      }
      if (lastUser != null) {
        _needsRedelivery = true;
        unawaited(_requeueUndeliveredUser(lastUser.id));
      }
    }

    final durable = _session.transport == AcpTransport.durable;
    if (durable &&
        (promptInFlight || _session.isPromptActive || sendingToHost)) {
      // Hand the turn to the host: complete the local await so the UI unlocks,
      // then tear down only the SSH ADSM client channel. Daemon + tmux keep working.
      remoteTurnActive = true;
      _session.handOffPrompt();
      promptInFlight = false;
      sendingToHost = false;
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
    } else if (!closed) {
      // Bridge survived background — still flush anything parked while paused.
      resumeOutboundQueue();
      unawaited(recoverTrailingUserPromptIfStuck());
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
    if (!(shouldAutoReconnect?.call() ?? true)) {
      reconnecting = false;
      return;
    }
    final factory = sessionFactory;
    if (factory == null) return;
    if (_retryTimer != null) return;

    if (reconnectAttempts >= maxReconnectAttempts) {
      reconnecting = false;
      lastError =
          'Could not reconnect after $maxReconnectAttempts attempts. '
          'Tap Reconnect to try again — your chat history is kept.';
      notifyListeners();
      return;
    }

    final delay = immediate ? Duration.zero : _backoffFor(reconnectAttempts);
    reconnectAttempts++;
    reconnecting = true;
    // Don't keep advertising Exploring/tools while the bridge is being rebuilt.
    remoteTurnActive = false;
    promptInFlight = false;
    sendingToHost = false;
    activityLabel = null;
    if (hasActiveTools) {
      unawaited(_finalizeStaleTools(reason: 'reconnect-start'));
    }
    // Drop sticky transport nags — reconnect is already underway.
    if (lastError != null && isTransientBridgeErrorText(lastError!)) {
      lastError = null;
    }
    notifyListeners();

    _retryTimer = Timer(delay, () async {
      _retryTimer = null;
      if (_disposed || _suspended) return;
      if (!(shouldAutoReconnect?.call() ?? true)) {
        reconnecting = false;
        _notifyUi(immediate: true);
        return;
      }
      try {
        final session = await factory();
        replaceSession(session);
        SafeLog.d('reconnected chat $chatId');
      } catch (e) {
        SafeLog.d('reconnect attempt $reconnectAttempts failed', e);
        if (classifySshFailure(e).isFatal) {
          reconnecting = false;
          if (e is MissingToolException) {
            lastError =
                'Cannot reconnect: ${e.tool} is not installed on the remote.\n\n'
                '${e.installHint}';
          } else {
            lastError = 'Cannot reconnect: $e';
          }
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
    // Only skip during an active prompt send — sticky remoteTurnActive / tools
    // used to block the catalogue forever ("cannot get the model list").
    if (promptInFlight || sendingToHost) return;
    if (availableModels.isEmpty) {
      await _restoreCachedModelCatalog();
    }
    await _session.ensureModelCatalog(mcpServers: mcpServers);
    await _persistCachedModelCatalog();
    notifyListeners();
  }

  static String _modelCatalogPrefsKey(String chatId) => 'model_catalog_$chatId';

  Future<void> _persistCachedModelCatalog() async {
    final models = availableModels;
    if (models.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode([
        for (final m in models) {'modelId': m.modelId, 'name': m.name},
      ]);
      await prefs.setString(_modelCatalogPrefsKey(chatId), encoded);
    } catch (e) {
      SafeLog.d('persist model catalog cache failed', e);
    }
  }

  Future<void> _restoreCachedModelCatalog() async {
    if (availableModels.isNotEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_modelCatalogPrefsKey(chatId));
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final models = <AgentModel>[
        for (final item in decoded)
          if (item is Map) AgentModel.fromJson(Map<String, dynamic>.from(item)),
      ];
      if (models.isEmpty) return;
      _session.seedModelCatalog(models);
    } catch (e) {
      SafeLog.d('restore model catalog cache failed', e);
    }
  }

  /// Switch model and remember it, so reconnects and restarts keep the choice.
  Future<void> setModel(String modelId) async {
    try {
      await _session.setModel(modelId);
    } on AcpModelSwitchUnsupported {
      SafeLog.d(
        'agent lacks in-session model RPCs; restarting with model=$modelId',
      );
      await _persistModelPreference(modelId);
      await _restartSessionForModel(modelId);
      return;
    } catch (e) {
      // Host idle-stop / recycled FIFO — revive the worker then apply the model.
      if (isTransientBridgeError(e) && sessionFactory != null) {
        SafeLog.d(
          'setModel hit dead FIFO/bridge; reconnecting with model=$modelId',
          e,
        );
        await _persistModelPreference(modelId);
        await _restartSessionForModel(modelId);
        return;
      }
      rethrow;
    }
    await _persistModelPreference(modelId);
    notifyListeners();
  }

  Future<void> _persistModelPreference(String modelId) async {
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
    await _persistCachedModelCatalog();
  }

  /// Relaunch the durable agent so startup `--model` / `CLAUDE_ACP_MODEL` apply.
  Future<void> _restartSessionForModel(String modelId) async {
    final factory = sessionFactory;
    if (factory == null) {
      throw StateError(
        'Cannot switch model: agent does not support in-session model '
        'changes and no reconnect factory is available.',
      );
    }

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
      // Prefer startup --model / preferredModelId; force RPC if still wrong.
      if (session.currentModelId != modelId) {
        try {
          await session.setModel(modelId);
        } on AcpModelSwitchUnsupported {
          // Startup flags/env already applied the model.
        } catch (e) {
          SafeLog.d('post-restart setModel skipped', e);
        }
      }
    } catch (e) {
      SafeLog.d('model switch restart failed', e);
      lastError = 'Could not switch model: $e';
      reconnecting = false;
      notifyListeners();
      rethrow;
    } finally {
      _restartingForPolicy = false;
      reconnecting = false;
      notifyListeners();
    }
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

    final content = ChatImageCodec.encodeMessage(text: trimmed, images: images);

    final message = ChatMessage(
      id: const Uuid().v4(),
      chatId: chatId,
      role: MessageRole.user,
      content: content,
      createdAt: DateTime.now(),
    );

    // Queue while the host turn is live — barging in used to clear busy chrome
    // and hit "already running", leaving the bubble in the transcript unsent.
    if (promptInFlight ||
        remoteTurnActive ||
        sendingToHost ||
        (closed && sessionFactory != null)) {
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
    // Claim the turn *before* the async gap so an Android lifecycle pause
    // cannot idle-close the bridge and orphan the bubble (phone "unresponsive").
    promptInFlight = true;
    sendingToHost = true;
    activityLabel = 'Sending to host…';
    notifyListeners();
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
      _ignoreHostRunningUntil = DateTime.now().add(const Duration(seconds: 20));
      try {
        await _session.cancel().timeout(const Duration(seconds: 8));
      } catch (e) {
        SafeLog.d('cancel before force-run failed', e);
      }
      await flushAssistantBuffer();
      await commitThought();
      _breakPromptChain();
      promptInFlight = false;
      remoteTurnActive = false;
      sendingToHost = false;
      activityLabel = null;
      notifyListeners();
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
    _trimResidentTranscript();
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
    if (_disposed) return;
    if (closed) {
      // Bubble may already be in the transcript — park it for reconnect instead
      // of silently returning (common when Android pauses mid-send).
      if (userMessageId != null) {
        _needsRedelivery = true;
        await _requeueUndeliveredUser(userMessageId);
      }
      promptInFlight = false;
      sendingToHost = false;
      activityLabel = null;
      notifyListeners();
      if (!_suspended && sessionFactory != null) {
        _scheduleReconnect(immediate: true);
      }
      return;
    }
    final epoch = _promptEpoch;
    remoteTurnActive = false;
    _clearHostBusyWatchdog();
    _ignoreHostRunningUntil = null;
    promptInFlight = true;
    sendingToHost = true;
    deliveryError = null;
    activityLabel = 'Sending to host…';
    _lastHostActivityAt = DateTime.now();
    _armHostBusyWatchdog();
    notifyListeners();
    var transportFailed = false;
    try {
      await flushAssistantBuffer();
      final payload = await ChatImageCodec.toPromptPayload(content);

      Object? lastError;
      for (var attempt = 1; attempt <= 3; attempt++) {
        if (_disposed || closed || epoch != _promptEpoch) return;
        try {
          if (attempt > 1) {
            sendingToHost = true;
            activityLabel = 'Retrying delivery ($attempt/3)…';
            notifyListeners();
            await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
          }
          await _session.prompt(
            payload.text,
            images: payload.images,
            userMessageId: userMessageId,
            userCreatedAt: userCreatedAt,
          );
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          SafeLog.d('prompt delivery attempt $attempt failed', e);
          final msg = e.toString().toLowerCase();
          final retryable =
              msg.contains('channel closed') ||
              msg.contains('timed out') ||
              msg.contains('timeout') ||
              msg.contains('adsm write') ||
              msg.contains('connection') ||
              msg.contains('socket') ||
              msg.contains('broken pipe');
          if (msg.contains('unknown chatid') || msg.contains('agents.ensure')) {
            // Daemon lost this worker — reconnect runs agents.ensure again.
            if (!closed && sessionFactory != null) {
              closed = true;
              _scheduleReconnect(immediate: true);
            }
            rethrow;
          }
          if (!retryable || attempt == 3) rethrow;
        }
      }
      if (lastError != null) throw lastError;

      // Delivered — leave Thinking until turn_complete / idle clears busy.
      sendingToHost = false;
      deliveryError = null;
      _needsRedelivery = false;
      activityLabel = 'Thinking';
      promptInFlight = true;
      remoteTurnActive = true;
      _noteHostActivity();
      notifyListeners();

      // Legacy ADSM (<0.4.3): prompt() blocked until the full turn finished.
      if (!_session.isPromptActive) {
        if (assistantBuffer.trim().isEmpty && thoughtBuffer.trim().isNotEmpty) {
          assistantBuffer = thoughtBuffer;
          thoughtBuffer = '';
        }
        await flushAssistantBuffer();
        await commitThought();
      }
    } catch (e) {
      SafeLog.d('prompt failed', e);
      // Late failure from a session that Force-run / reconnect already replaced.
      if (epoch != _promptEpoch) {
        transportFailed = true;
      } else if (e.toString().toLowerCase().contains('already running')) {
        // Host still on the previous turn — park the bubble and wait.
        SafeLog.d('prompt deferred: host still running chat=$chatId');
        remoteTurnActive = true;
        promptInFlight = true;
        sendingToHost = false;
        activityLabel = 'Working on host…';
        _needsRedelivery = true;
        if (userMessageId != null) {
          await _requeueUndeliveredUser(userMessageId);
        }
        _armHostBusyWatchdog();
        _notifyUi();
        return;
      } else if (isTransientBridgeError(e)) {
        // Quiet reconnect — do not leave "Bad state: ADSM channel closed" up.
        lastError = null;
        deliveryError =
            'Trying to reach the host… message may not have been delivered.';
        transportFailed = true;
        if (!closed && sessionFactory != null) {
          closed = true;
          _scheduleReconnect(immediate: true);
        }
      } else {
        lastError = e.toString();
        deliveryError =
            'Message may not have reached the host. Tap Stop and send again.';
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
        sendingToHost = false;
        if (transportFailed) {
          promptInFlight = false;
          remoteTurnActive = false;
          _clearHostBusyWatchdog();
          _needsRedelivery = true;
          if (userMessageId != null) {
            await _requeueUndeliveredUser(userMessageId);
          }
          notifyListeners();
          if (!closed) _drainOutboundQueue();
        } else if (closed && !transportFailed) {
          // Bridge dropped via background handoff. Durable host may still be
          // mid-turn — keep the working indicator until idle arrives.
          remoteTurnActive = true;
          promptInFlight = false;
          _armHostBusyWatchdog();
          notifyListeners();
        } else if (!_session.isPromptActive && !remoteTurnActive) {
          // Legacy turn finished inline, or nothing started.
          promptInFlight = false;
          _clearHostBusyWatchdog();
          notifyListeners();
          if (!closed) _drainOutboundQueue();
        } else {
          // Delivered; turn still running on host — keep busy chrome.
          notifyListeners();
        }
      }
    }
  }

  /// Move a failed prompt back onto the outbound queue so reconnect / Force
  /// run can deliver it. Keeps the DB row; only the in-memory transcript moves.
  Future<void> _requeueUndeliveredUser(String messageId) async {
    ChatMessage? msg;
    for (final e in entries) {
      if (e.messageId == messageId && e.message != null) {
        msg = e.message;
        break;
      }
    }
    if (msg == null) return;
    entries.removeWhere((e) => e.messageId == messageId);
    _rebuildToolEntryIndexes();
    if (!outboundQueue.any((m) => m.id == messageId)) {
      outboundQueue.insert(0, msg);
    }
    try {
      await _persistOutboundQueue();
    } catch (e) {
      SafeLog.d('persist requeue after failed delivery failed', e);
    }
  }

  Future<void> _flushTurnBuffers() async {
    if (assistantBuffer.trim().isEmpty && thoughtBuffer.trim().isNotEmpty) {
      assistantBuffer = thoughtBuffer;
      thoughtBuffer = '';
    }
    await flushAssistantBuffer();
    await commitThought();
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
    // Tick often enough to notice stalls, but thresholds below decide action.
    _hostBusyWatchdog = Timer(const Duration(seconds: 20), () {
      if (_disposed) return;
      if (!isWorking) return;
      unawaited(_hostBusyWatchdogTick());
    });
  }

  Future<void> _hostBusyWatchdogTick() async {
    if (_disposed || !isWorking) return;

    final silentFor = _lastHostActivityAt == null
        ? const Duration(days: 1)
        : DateTime.now().difference(_lastHostActivityAt!);

    final durable = _session.transport == AcpTransport.durable;
    // Mid-turn assistant text ("let me check…") is normal before more tools.
    // Only treat leftover in_progress rows as stale quickly on non-durable
    // bridges; on ADSM, ask the host before clearing busy chrome.
    final answered = _turnHasAssistantReply;
    final toolStaleAfter = durable
        ? (answered ? const Duration(minutes: 2) : const Duration(minutes: 3))
        : (answered
              ? const Duration(seconds: 25)
              : const Duration(seconds: 45));
    final promptStaleAfter = durable
        ? (answered ? const Duration(minutes: 3) : const Duration(minutes: 4))
        : (answered
              ? const Duration(seconds: 40)
              : const Duration(seconds: 90));

    // Durable: host status is authoritative when we can reach ADSM. A failed
    // poll must not keep recycling a stale "running" forever (VPN off, etc.).
    if (durable && _session is AdsmSession) {
      final adsm = _session as AdsmSession;
      if (!adsm.bridgeClient.isOpen) {
        if (silentFor >= const Duration(seconds: 35)) {
          SafeLog.d(
            'watchdog: ADSM bridge closed after ${silentFor.inSeconds}s '
            'silence — clear sticky busy chat=$chatId',
          );
          await _clearStickyBusyAfterLostHost(
            reason: 'bridge-closed',
            notifyLost: true,
          );
          return;
        }
        _armHostBusyWatchdog();
        return;
      }

      final st = await adsm.refreshDaemonStatus(forceEmit: true);
      if (_disposed) return;
      final host = (st ?? '').toLowerCase();
      if (_suppressHostRunning &&
          (host == 'running' ||
              host == 'waiting_permission' ||
              host == 'starting')) {
        // User pressed Stop — do not resurrect busy chrome from a lagging poll.
        remoteTurnActive = false;
        promptInFlight = false;
        sendingToHost = false;
        activityLabel = null;
        if (hasActiveTools) {
          await _finalizeStaleTools(reason: 'watchdog-after-stop');
        }
        notifyListeners();
        if (!closed) _drainOutboundQueue();
        return;
      }
      if (host == 'running' ||
          host == 'waiting_permission' ||
          host == 'starting') {
        activityLabel = host == 'waiting_permission'
            ? 'Waiting for permission'
            : (activityLabel?.isNotEmpty == true
                  ? activityLabel
                  : 'Working on host…');
        remoteTurnActive = true;
        promptInFlight = true;
        notifyListeners();
        _armHostBusyWatchdog();
        return;
      }
      if (host == 'idle' || host == 'dead' || host == 'error') {
        // daemonStatus handler usually clears tools; if rows are still sticky,
        // finish them here so "working · N tools" cannot linger.
        if (hasActiveTools) {
          await _finalizeStaleTools(reason: 'watchdog-daemon-$host');
        } else if (isWorking) {
          remoteTurnActive = false;
          promptInFlight = false;
          sendingToHost = false;
          activityLabel = null;
          notifyListeners();
          if (!closed) _drainOutboundQueue();
        }
        return;
      }

      // Poll failed / unknown (null). After silence, unlock — do not keep
      // advertising Exploring/tools while we cannot reach the host.
      final lostAfter = answered
          ? const Duration(seconds: 45)
          : const Duration(seconds: 75);
      if (silentFor >= lostAfter) {
        SafeLog.d(
          'watchdog: lost ADSM contact after ${silentFor.inSeconds}s '
          'silence chat=$chatId',
        );
        await _clearStickyBusyAfterLostHost(
          reason: 'poll-failed',
          notifyLost: true,
        );
        return;
      }
      if (sendingToHost && silentFor >= const Duration(seconds: 45)) {
        SafeLog.d(
          'watchdog: delivery stall ${silentFor.inSeconds}s '
          '(host status unknown) chat=$chatId',
        );
        await _watchdogUnstickPrompt();
        return;
      }
      activityLabel = activityLabel?.isNotEmpty == true
          ? activityLabel
          : 'Checking host…';
      notifyListeners();
      _armHostBusyWatchdog();
      return;
    }

    if (hasActiveTools) {
      if (silentFor >= toolStaleAfter) {
        await _finalizeStaleTools(reason: 'watchdog-silent-tools');
      } else {
        _armHostBusyWatchdog();
      }
      return;
    }

    // Stuck in delivery (SSH/ADSM never acked) — fail fast vs long Thinking.
    if (sendingToHost && silentFor >= const Duration(seconds: 25)) {
      SafeLog.d(
        'watchdog: delivery stall ${silentFor.inSeconds}s chat=$chatId',
      );
      await _watchdogUnstickPrompt();
      return;
    }

    // Hung on "Thinking" with no tools and no host events.
    if (_session.isPromptActive && silentFor >= promptStaleAfter) {
      SafeLog.d(
        'watchdog: silent prompt ${silentFor.inSeconds}s chat=$chatId — unstick',
      );
      await _watchdogUnstickPrompt();
      return;
    }

    // Sticky remoteTurnActive with silence: host likely finished while we
    // missed turn_complete. Clear after a short grace period (non-durable).
    if (remoteTurnActive &&
        !_session.isPromptActive &&
        silentFor >= const Duration(seconds: 25)) {
      SafeLog.d(
        'watchdog: clear sticky remoteTurnActive after '
        '${silentFor.inSeconds}s silence chat=$chatId',
      );
      remoteTurnActive = false;
      promptInFlight = false;
      sendingToHost = false;
      activityLabel = null;
      notifyListeners();
      if (!closed) _drainOutboundQueue();
      return;
    }

    // Still awaiting a live local prompt — keep polling.
    if (_session.isPromptActive) {
      _armHostBusyWatchdog();
      return;
    }

    // Silence after reconnect: host likely finished while we were away.
    remoteTurnActive = false;
    promptInFlight = false;
    sendingToHost = false;
    activityLabel = null;
    _notifyUi(immediate: true);
    if (!closed) _drainOutboundQueue();
  }

  /// True when this turn already produced visible progress (answer / tools).
  bool get _turnHasProgress {
    for (var i = entries.length - 1; i >= 0; i--) {
      final m = entries[i].message;
      if (m != null && m.role == MessageRole.user) break;
      if (m != null &&
          m.role == MessageRole.assistant &&
          m.content.trim().isNotEmpty) {
        return true;
      }
      if (entries[i].tool != null) return true;
    }
    if (assistantBuffer.trim().isNotEmpty) return true;
    if (thoughtBuffer.trim().isNotEmpty) return true;
    return false;
  }

  /// True when the agent already posted a visible answer this turn.
  bool get _turnHasAssistantReply {
    if (assistantBuffer.trim().isNotEmpty) return true;
    for (var i = entries.length - 1; i >= 0; i--) {
      final m = entries[i].message;
      if (m != null && m.role == MessageRole.user) break;
      if (m != null &&
          m.role == MessageRole.assistant &&
          m.content.trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  Future<void> _clearStickyBusyAfterLostHost({
    required String reason,
    required bool notifyLost,
  }) async {
    _clearHostBusyWatchdog();
    if (hasActiveTools) {
      await _finalizeStaleTools(reason: reason);
    }
    promptInFlight = false;
    remoteTurnActive = false;
    sendingToHost = false;
    activityLabel = null;
    if (notifyLost) {
      deliveryError =
          'Lost contact with the host — status may be stale. Tap Retry or check VPN.';
    }
    _notifyUi(immediate: true);
    if (!closed) _drainOutboundQueue();
  }

  Future<void> _watchdogUnstickPrompt() async {
    final hadProgress = _turnHasProgress;
    final wasSending = sendingToHost;

    // Always cancel — leaving a durable turn "unlocked" in the UI while the
    // host kept running made follow-ups look sent and then hang forever.
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
    sendingToHost = false;
    activityLabel = null;
    if (wasSending && !hadProgress) {
      deliveryError =
          'Could not reach the host. Check the connection and send again.';
      lastError = deliveryError;
    } else if (!hadProgress) {
      lastError =
          'Agent went quiet with no reply (often a large image or a stuck turn). '
          'Tap Stop if it hangs again, or resend with a smaller screenshot.';
    } else {
      lastError = null;
      deliveryError = null;
    }
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
    SafeLog.d(
      'finalizing ${active.length} stale tool(s) ($reason) chat=$chatId',
    );
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

  /// When set, ignore host `running` status until this time (user pressed Stop).
  DateTime? _ignoreHostRunningUntil;

  bool get _suppressHostRunning {
    final until = _ignoreHostRunningUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// User-facing unblock when the UI is stuck on "Agent is working".
  Future<void> unstick() async {
    _clearHostBusyWatchdog();
    // Always cancel — after ADSM prompt-accept, [isPromptActive] is false while
    // the durable turn (and long shell polls) keep running on the host. Skipping
    // cancel left Stop as a no-op and "Thinking…" stuck forever.
    _ignoreHostRunningUntil = DateTime.now().add(const Duration(seconds: 20));
    try {
      await _session.cancel().timeout(const Duration(seconds: 8));
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
    remoteTurnActive = false;
    sendingToHost = false;
    activityLabel = null;
    lastError = null;
    deliveryError = null;
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
        // Only accept ACP-suggested titles while the row is still a placeholder
        // ("New agent"). User renames must stick across devices.
        if (update.title != null &&
            update.title!.isNotEmpty &&
            chatMeta != null &&
            chatMeta!.isPlaceholderTitle) {
          final now = DateTime.now();
          chatMeta = chatMeta!.copyWith(
            title: update.title,
            titleUpdatedAt: now,
            updatedAt: now,
          );
          unawaited(_db.upsertChat(chatMeta!));
          onLocalChange?.call(chatId);
        }
        notifyListeners();
      case AcpUpdateKind.activity:
        final label = update.text.trim();
        activityLabel = label.isEmpty ? null : label;
        if (activityLabel != null) {
          if (sendingToHost && activityLabel != 'Sending to host…') {
            sendingToHost = false;
          }
          _noteHostActivity();
        } else {
          // ADSM clears the chip between phases — keep the watchdog armed, but
          // do not treat the clear as fresh host work (that froze "Exploring…"
          // forever after the answer already landed).
          _armHostBusyWatchdog();
        }
        _notifyUi();
      case AcpUpdateKind.promptAccepted:
        sendingToHost = false;
        deliveryError = null;
        activityLabel = 'Thinking';
        _noteHostActivity();
        _notifyUi(immediate: true);
      case AcpUpdateKind.daemonStatus:
        final st = update.text.trim().toLowerCase();
        if (st == 'idle' || st == 'dead' || st == 'error') {
          // Host is done — even if some tool rows never got a terminal status.
          _clearHostBusyWatchdog();
          sendingToHost = false;
          remoteTurnActive = false;
          activityLabel = null;
          _completePendingToolUpdates();
          if (_session.isPromptActive && _session is AdsmSession) {
            (_session as AdsmSession).handOffPrompt();
          }
          // Idle can arrive without turn_complete (missed journal) — flush so
          // we do not leave a shimmering Thinking fold while status says live.
          unawaited(_flushTurnBuffers());
          if (hasActiveTools) {
            unawaited(_finalizeStaleTools(reason: 'daemon-$st'));
          } else {
            promptInFlight = false;
            _notifyUi(immediate: true);
            if (!closed) _drainOutboundQueue();
          }
        } else if (st == 'waiting_permission') {
          if (_suppressHostRunning) break;
          sendingToHost = false;
          remoteTurnActive = true;
          promptInFlight = true;
          activityLabel = 'Waiting for permission';
          _noteHostActivity();
          _notifyUi(immediate: true);
        } else if (st == 'running' || st == 'starting') {
          if (_suppressHostRunning) break;
          // Host still on a turn — keep busy chrome even when journal events
          // went quiet (HPC polls, long shell). Re-attach after a false idle.
          sendingToHost = false;
          remoteTurnActive = true;
          promptInFlight = true;
          activityLabel = activityLabel?.isNotEmpty == true
              ? activityLabel
              : 'Working on host…';
          _noteHostActivity();
          _notifyUi();
        }
      case AcpUpdateKind.mode:
        _notifyUi(immediate: true);
      case AcpUpdateKind.delta:
        _noteHostActivity();
        if (lastError != null || deliveryError != null) {
          lastError = null;
          deliveryError = null;
        }
        activityLabel ??= 'Writing';
        if (thoughtBuffer.isNotEmpty) {
          unawaited(commitThought());
        }
        _appendAssistantText(update.text);
        // Assign id immediately so the live bubble and the checkpointed row
        // share one identity (avoids double-painting when id was still null).
        _assistantMessageId ??= const Uuid().v4();
        _assistantStartedAt ??= DateTime.now();
        if (update.text.trim().isNotEmpty) {
          onAssistantText?.call(update.text);
        }
        _scheduleAssistantPersist();
        _notifyUi();
      case AcpUpdateKind.thought:
        _noteHostActivity();
        if (lastError != null || deliveryError != null) {
          lastError = null;
          deliveryError = null;
        }
        activityLabel ??= 'Thinking';
        if (assistantBuffer.isNotEmpty) {
          unawaited(flushAssistantBuffer());
        }
        _appendThoughtText(update.text);
        _notifyUi();
      case AcpUpdateKind.tool:
        final tool = update.tool;
        if (tool == null) break;
        _noteHostActivity();
        if (lastError != null || deliveryError != null) {
          lastError = null;
          deliveryError = null;
        }
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
        _notifyUi(immediate: true);
      case AcpUpdateKind.error:
        final msg = update.text.trim();
        if (msg.isEmpty) break;
        if (isAcpSessionGoneText(msg)) {
          // Stale Claude session after Stop/cancel — clear resume id and
          // soft-reconnect so the next message gets session/new.
          lastError =
              'Agent session expired after stop — reconnecting with a fresh session…';
          unawaited(_recoverFromGoneAcpSession());
          _notifyUi(immediate: true);
          break;
        }
        if (isTransientBridgeErrorText(msg)) {
          // e.g. "FIFO not attached" after host idle-stop — quiet reconnect.
          lastError = null;
          deliveryError = 'Host agent paused — reconnecting…';
          if (!closed && sessionFactory != null && !_suspended) {
            closed = true;
            _scheduleReconnect(immediate: true);
          }
          _notifyUi(immediate: true);
          break;
        }
        lastError = msg;
        _notifyUi(immediate: true);
      case AcpUpdateKind.closed:
        // Unlock the composer immediately — a hanging prompt would otherwise
        // keep the spinner up while reconnect runs underneath.
        if (promptInFlight && !remoteTurnActive) {
          promptInFlight = false;
        }
        activityLabel = null;
        _completePendingToolUpdates();
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
        _notifyUi(immediate: true);
      case AcpUpdateKind.usage:
        if (update.tokensUsed != null) {
          usageTokensUsed = update.tokensUsed;
        }
        if (update.contextSize != null) {
          usageContextSize = update.contextSize;
        }
        _notifyUi();
      case AcpUpdateKind.turnComplete:
        // Flush streaming buffers once the host turn ends, then record
        // per-command code delta + token footer.
        unawaited(() async {
          await _flushTurnBuffers();
          await _persistTurnStats();
        }());
        // Clearing promptInFlight here while a local await is open lets a new
        // send race ahead — only clear UI busy when nothing owns the prompt.
        _clearHostBusyWatchdog();
        sendingToHost = false;
        remoteTurnActive = false;
        activityLabel = null;
        _completePendingToolUpdates();
        if (hasActiveTools) {
          // end_turn with rows still "in_progress" — agent will not send more
          // updates for them. Finalize so the UI does not choke forever.
          unawaited(_finalizeStaleTools(reason: 'turnComplete'));
        } else if (!_session.isPromptActive) {
          promptInFlight = false;
          _notifyUi(immediate: true);
          if (!closed) _drainOutboundQueue();
        } else {
          _notifyUi(immediate: true);
        }
        break;
    }
  }

  /// Persist `+X -Y · Z φ · N τ` for the turn that just finished.
  Future<void> _persistTurnStats() async {
    if (_disposed) return;
    final code = turnCodeDelta;
    final tokens = usageTokensUsed;
    final size = usageContextSize;
    if (code.isEmpty && tokens == null) return;

    // Avoid stacking duplicates when turn_complete fires more than once.
    for (var i = entries.length - 1; i >= 0; i--) {
      final m = entries[i].message;
      if (m == null) continue;
      if (m.role == MessageRole.user) break;
      if (m.role == MessageRole.system &&
          TurnStatsMessage.isTurnStats(m.content)) {
        return;
      }
    }

    final message = ChatMessage(
      id: const Uuid().v4(),
      chatId: chatId,
      role: MessageRole.system,
      content: TurnStatsMessage.encode(
        added: code.added,
        removed: code.removed,
        files: code.fileCount,
        tokensUsed: tokens,
        contextSize: size,
      ),
      createdAt: DateTime.now(),
    );
    entries.add(TranscriptEntry.message(message));
    _trimResidentTranscript();
    _writesInFlight++;
    try {
      await _db.insertMessage(message);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('persist turn stats failed', e);
    } finally {
      _writesInFlight--;
    }
    notifyListeners();
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
      _notifyUi();
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
    _trimResidentTranscript();
    _writesInFlight++;
    try {
      await _db.insertMessage(message);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('persist thought failed', e);
    } finally {
      _writesInFlight--;
    }
    _notifyUi(immediate: true);
  }

  /// Checkpoint the streaming turn to disk shortly after output stops arriving.
  ///
  /// Without this the whole answer lives only in memory until the turn ends, so
  /// a crash, a prompt timeout, or the process being killed loses everything
  /// the user could already read on screen.
  void _scheduleAssistantPersist() {
    _assistantPersistTimer?.cancel();
    _assistantPersistTimer = Timer(const Duration(seconds: 2), () {
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
      _notifyUi();
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
    _notifyUi(immediate: true);
  }

  /// Keep the live answer in [entries] as it grows so the bubble does not
  /// vanish when [isWorking] clears a tick before [flushAssistantBuffer].
  void _upsertAssistantEntry(ChatMessage message) {
    final index = entries.indexWhere((e) => e.messageId == message.id);
    if (index >= 0) {
      entries[index] = TranscriptEntry.message(message);
    } else {
      entries.add(TranscriptEntry.message(message));
      _trimResidentTranscript();
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
    // Disk checkpoint only — do not mutate [entries] while the live buffer is
    // painting. Updating entries on every checkpoint invalidated the transcript block
    // cache and re-parsed every visible GptMarkdown bubble.
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

  Future<void> _upsertTool(ToolCallState tool) {
    if (tool.isActive) {
      // Tool stdout/progress can arrive dozens of times a second. Keep only
      // the newest state for each tool and persist a short batch.
      _pendingToolUpdates[tool.toolCallId] = tool;
      _toolFlushTimer ??= Timer(const Duration(milliseconds: 400), () {
        _toolFlushTimer = null;
        unawaited(_flushPendingToolUpdates());
      });
      return Future<void>.value();
    }

    // A terminal update must win over any queued active snapshot.
    _pendingToolUpdates.remove(tool.toolCallId);
    return _serializeToolUpsert(tool);
  }

  Future<void> _flushPendingToolUpdates() async {
    if (_pendingToolUpdates.isEmpty) return;
    final batch = _pendingToolUpdates.values.toList(growable: false);
    _pendingToolUpdates.clear();
    for (final tool in batch) {
      await _serializeToolUpsert(tool);
    }
  }

  void _completePendingToolUpdates() {
    if (_pendingToolUpdates.isEmpty) return;
    _toolFlushTimer?.cancel();
    _toolFlushTimer = null;
    final pending = _pendingToolUpdates.values.toList(growable: false);
    _pendingToolUpdates.clear();
    for (final tool in pending) {
      unawaited(
        _serializeToolUpsert(
          tool.merge(status: 'completed', rawOutput: tool.rawOutput ?? ''),
        ),
      );
    }
  }

  Future<void> _serializeToolUpsert(ToolCallState tool) {
    final run = _toolUpsertTail.then((_) => _upsertToolUnlocked(tool));
    _toolUpsertTail = run.catchError((Object e) {
      SafeLog.d('tool upsert failed', e);
    });
    return run;
  }

  Future<void> _upsertToolUnlocked(ToolCallState tool) async {
    // The index makes repeated output updates O(1). Only scan when importing a
    // legacy runtime that has not populated the index yet.
    final knownIndex = _toolEntryIndexes[tool.toolCallId];
    final dupIndexes = knownIndex == null
        ? <int>[
            for (var i = 0; i < entries.length; i++)
              if (entries[i].tool?.toolCallId == tool.toolCallId) i,
          ]
        : <int>[knownIndex];
    if (dupIndexes.length > 1) {
      final keep = dupIndexes.first;
      var mergedTool =
          _payloadOrSummary(entries[keep].tool!) ?? entries[keep].tool!;
      final orphanIds = <String>[];
      for (var d = 1; d < dupIndexes.length; d++) {
        final idx = dupIndexes[d];
        final other =
            _payloadOrSummary(entries[idx].tool!) ?? entries[idx].tool!;
        mergedTool = mergedTool.merge(
          title: other.title,
          kind: other.kind,
          status: other.status,
          locations: other.locations.isEmpty ? null : other.locations,
          rawInput: other.rawInput,
          rawOutput: other.rawOutput,
          content: other.content,
        );
        final oid = entries[idx].messageId;
        if (oid != null) orphanIds.add(oid);
      }
      for (var d = dupIndexes.length - 1; d >= 1; d--) {
        entries.removeAt(dupIndexes[d]);
      }
      for (final oid in orphanIds) {
        try {
          await _db.deleteMessage(oid);
        } catch (e) {
          SafeLog.d('delete dup tool row failed', e);
        }
      }
      final keepId =
          entries[keep].messageId ?? _toolMessageIds[tool.toolCallId];
      final full = mergedTool.merge(
        title: tool.title,
        kind: tool.kind,
        status: tool.status,
        locations: tool.locations.isEmpty ? null : tool.locations,
        rawInput: tool.rawInput,
        rawOutput: tool.rawOutput,
        content: tool.content,
      );
      entries[keep] = TranscriptEntry.tool(
        _uiToolSummary(full),
        messageId: keepId,
        createdAt: entries[keep].createdAt,
      );
      if (keepId != null) {
        _toolMessageIds[tool.toolCallId] = keepId;
        try {
          await _db.updateMessage(
            ChatMessage(
              id: keepId,
              chatId: chatId,
              role: MessageRole.tool,
              content: jsonEncode(full.toJson()),
              createdAt: DateTime.now(),
            ),
          );
        } catch (e) {
          SafeLog.d('update merged tool failed', e);
        }
      }
      _rebuildToolEntryIndexes();
      _scheduleCodeDeltaPersist();
      _notifyUi();
      return;
    }

    final index = knownIndex ?? (dupIndexes.isEmpty ? -1 : dupIndexes.first);
    if (index >= 0) {
      final prev =
          _payloadOrSummary(entries[index].tool!) ?? entries[index].tool!;
      final merged = prev.merge(
        title: tool.title,
        kind: tool.kind,
        status: tool.status,
        locations: tool.locations.isEmpty ? null : tool.locations,
        rawInput: tool.rawInput,
        rawOutput: tool.rawOutput,
        content: tool.content,
      );
      final msgId =
          entries[index].messageId ?? _toolMessageIds[tool.toolCallId];
      entries[index] = TranscriptEntry.tool(
        _uiToolSummary(merged),
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
      final existingId = _toolMessageIds[tool.toolCallId];
      final msgId = existingId ?? const Uuid().v4();
      _toolMessageIds[tool.toolCallId] = msgId;
      entries.add(
        TranscriptEntry.tool(_uiToolSummary(tool), messageId: msgId),
      );
      _toolEntryIndexes[tool.toolCallId] = entries.length - 1;
      final message = ChatMessage(
        id: msgId,
        chatId: chatId,
        role: MessageRole.tool,
        content: jsonEncode(tool.toJson()),
        createdAt: DateTime.now(),
      );
      try {
        if (existingId != null) {
          await _db.updateMessage(message);
        } else {
          await _db.insertMessage(message);
        }
        onLocalChange?.call(chatId);
      } catch (e) {
        SafeLog.d('insert tool message failed', e);
      }
    }
    _maybeTrimResident();
    _scheduleCodeDeltaPersist();
    _notifyUi();
  }

  void _scheduleCodeDeltaPersist() {
    _codeDeltaPersistTimer?.cancel();
    _codeDeltaPersistTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_persistCodeDelta());
    });
  }

  Future<void> _persistCodeDelta() async {
    if (_disposed) return;
    final stats = codeDelta;
    final meta = chatMeta;
    if (meta == null) return;
    final today = codeDeltaLocalDayKey();
    final sameDay = meta.codeDeltaDay == null || meta.codeDeltaDay == today;
    // New local day — do not carry yesterday's persisted totals forward.
    final added = sameDay
        ? (stats.added > meta.linesAdded ? stats.added : meta.linesAdded)
        : stats.added;
    final removed = sameDay
        ? (stats.removed > meta.linesRemoved
              ? stats.removed
              : meta.linesRemoved)
        : stats.removed;
    final files = sameDay
        ? (stats.fileCount > meta.filesChanged
              ? stats.fileCount
              : meta.filesChanged)
        : stats.fileCount;
    if (sameDay &&
        meta.linesAdded == added &&
        meta.linesRemoved == removed &&
        meta.filesChanged == files) {
      return;
    }
    final updated = meta.copyWith(
      linesAdded: added,
      linesRemoved: removed,
      filesChanged: files,
      codeDeltaDay: today,
      updatedAt: DateTime.now(),
    );
    chatMeta = updated;
    try {
      await _db.upsertChat(updated);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('persist code delta failed', e);
    }
    _notifyUi();
  }

  Future<void> appendUserMessage(ChatMessage message) async {
    entries.add(TranscriptEntry.message(message));
    _trimResidentTranscript();
    await _db.insertMessage(message);
    onLocalChange?.call(chatId);
    _notifyUi(immediate: true);
  }

  /// Load full tool payloads for an expanded group (ephemeral UI only).
  ///
  /// Prefer targeted SQLite rows (cheap). Only fall back to ADSM for ids still
  /// missing — never re-scan the whole in-memory payload map on the UI isolate.
  Future<List<ToolCallState>> resolveToolDetails({
    required List<String> toolCallIds,
    List<String?> messageIds = const [],
  }) async {
    if (toolCallIds.isEmpty) return const [];
    final wanted = toolCallIds.toSet();
    final byId = <String, ToolCallState>{};

    final missingIds = [
      for (final id in messageIds)
        if (id != null && id.isNotEmpty) id,
    ];
    if (missingIds.isNotEmpty) {
      try {
        final rows = await _db.getMessagesByIds(missingIds);
        for (final row in rows) {
          if (row.role != MessageRole.tool) continue;
          final tool = ToolCallState.tryParseContent(row.content);
          if (tool == null || !wanted.contains(tool.toolCallId)) continue;
          byId[tool.toolCallId] = tool;
        }
      } catch (e) {
        SafeLog.d('resolveToolDetails local load failed', e);
      }
    }

    final stillMissing = [
      for (final id in toolCallIds)
        if (!(byId[id]?.hasPayloads ?? false)) id,
    ];
    if (stillMissing.isNotEmpty && session is AdsmSession) {
      try {
        final adsm = session as AdsmSession;
        final remote = await adsm
            .pullTranscript(limit: 400, maxBytes: 512 * 1024)
            .timeout(const Duration(seconds: 8));
        for (final row in remote) {
          if (row.role != MessageRole.tool) continue;
          final tool = ToolCallState.tryParseContent(row.content);
          if (tool == null || !wanted.contains(tool.toolCallId)) continue;
          byId[tool.toolCallId] = tool;
        }
      } catch (e) {
        SafeLog.d('resolveToolDetails ADSM pull failed', e);
      }
    }

    // Summaries only if nothing richer is available.
    for (final id in toolCallIds) {
      if (byId.containsKey(id)) continue;
      for (final entry in entries) {
        final tool = entry.tool;
        if (tool?.toolCallId == id) {
          byId[id] = tool!;
          break;
        }
      }
    }

    return [
      for (final id in toolCallIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Future<void> disposeRuntime() async {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    _uiNotifyCoalesce?.cancel();
    _uiNotifyCoalesce = null;
    _clearHostBusyWatchdog();
    _assistantPersistTimer?.cancel();
    _assistantPersistTimer = null;
    _codeDeltaPersistTimer?.cancel();
    _codeDeltaPersistTimer = null;
    _toolFlushTimer?.cancel();
    _toolFlushTimer = null;
    await _flushPendingToolUpdates();
    try {
      await _toolUpsertTail;
    } catch (_) {}
    await _sub?.cancel();
    _sub = null;
    try {
      await flushAssistantBuffer();
      await commitThought();
    } catch (_) {}
    await _session.close();
  }
}
