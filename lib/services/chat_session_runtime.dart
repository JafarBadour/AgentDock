import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/local/app_database.dart';
import '../data/models/agent_mode.dart';
import '../data/models/chat.dart';
import '../data/models/chat_message.dart';
import '../data/models/tool_call_state.dart';
import '../data/secure/safe_log.dart';
import 'cursor_acp_service.dart';

/// One transcript row — message and/or live tool.
class TranscriptEntry {
  const TranscriptEntry._({this.message, this.tool, this.messageId});

  factory TranscriptEntry.message(ChatMessage message) =>
      TranscriptEntry._(message: message, messageId: message.id);

  factory TranscriptEntry.tool(ToolCallState tool, {String? messageId}) =>
      TranscriptEntry._(tool: tool, messageId: messageId);

  final ChatMessage? message;
  final ToolCallState? tool;
  final String? messageId;
}

/// Long-lived ACP session + transcript for one chat.
///
/// Keeps listening and persisting even when [ChatScreen] is disposed, so
/// switching chats does not lose in-flight agent work.
class ChatSessionRuntime extends ChangeNotifier {
  ChatSessionRuntime({
    required this.chatId,
    required AcpSession session,
    required AppDatabase db,
    this.onLocalChange,
  })  : _session = session,
        _db = db;

  final String chatId;
  final AppDatabase _db;
  final void Function(String chatId)? onLocalChange;
  AcpSession _session;
  StreamSubscription<AcpUpdate>? _sub;

  final List<TranscriptEntry> entries = [];
  final Map<String, String> _toolMessageIds = {};

  String assistantBuffer = '';
  String thoughtBuffer = '';
  String? lastError;
  bool closed = false;
  bool promptInFlight = false;
  Chat? chatMeta;

  AcpSession get session => _session;
  AgentSessionMode get mode => _session.mode;
  PermissionPolicy get permissionPolicy => _session.permissionPolicy;

  void hydrateFromMessages(List<ChatMessage> messages) {
    entries.clear();
    _toolMessageIds.clear();
    for (final m in messages) {
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
    notifyListeners();
  }

  void startListening() {
    _sub?.cancel();
    _sub = _session.updates.listen(_onUpdate, onError: (Object e) {
      lastError = e.toString();
      notifyListeners();
    });
  }

  void replaceSession(AcpSession session) {
    _sub?.cancel();
    _session = session;
    closed = false;
    lastError = null;
    startListening();
    notifyListeners();
  }

  void setPermissionPolicy(PermissionPolicy policy) {
    _session.setPermissionPolicy(policy);
    notifyListeners();
  }

  Future<void> setMode(AgentSessionMode mode) async {
    await _session.setMode(mode);
    notifyListeners();
  }

  Future<void> prompt(String text) async {
    promptInFlight = true;
    notifyListeners();
    try {
      await flushAssistantBuffer();
      await _session.prompt(text);
      await flushAssistantBuffer();
      await commitThought();
    } finally {
      promptInFlight = false;
      notifyListeners();
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
      case AcpUpdateKind.mode:
        notifyListeners();
      case AcpUpdateKind.delta:
        if (thoughtBuffer.isNotEmpty) {
          unawaited(commitThought());
        }
        assistantBuffer += update.text;
        notifyListeners();
      case AcpUpdateKind.thought:
        if (assistantBuffer.isNotEmpty) {
          unawaited(flushAssistantBuffer());
        }
        thoughtBuffer += update.text;
        notifyListeners();
      case AcpUpdateKind.tool:
        final tool = update.tool;
        if (tool == null) break;
        if (assistantBuffer.isNotEmpty) {
          unawaited(flushAssistantBuffer());
        }
        if (thoughtBuffer.isNotEmpty) {
          unawaited(commitThought());
        }
        unawaited(_upsertTool(tool));
      case AcpUpdateKind.permission:
        break;
      case AcpUpdateKind.error:
        lastError = update.text;
        notifyListeners();
      case AcpUpdateKind.closed:
        unawaited(flushAssistantBuffer());
        unawaited(commitThought());
        closed = true;
        lastError = lastError ??
            'Agent connection dropped (app restart or SSH disconnect). '
            'Tap Reconnect — your chat history is kept.';
        notifyListeners();
    }
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
      content: text,
      createdAt: DateTime.now(),
    );
    entries.add(TranscriptEntry.message(message));
    try {
      await _db.insertMessage(message);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('persist thought failed', e);
    }
    notifyListeners();
  }

  Future<void> flushAssistantBuffer() async {
    final text = assistantBuffer.trim();
    assistantBuffer = '';
    if (text.isEmpty) {
      notifyListeners();
      return;
    }
    final message = ChatMessage(
      id: const Uuid().v4(),
      chatId: chatId,
      role: MessageRole.assistant,
      content: text,
      createdAt: DateTime.now(),
    );
    entries.add(TranscriptEntry.message(message));
    try {
      await _db.insertMessage(message);
      onLocalChange?.call(chatId);
    } catch (e) {
      SafeLog.d('persist assistant failed', e);
    }
    notifyListeners();
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
      );
      final msgId = entries[index].messageId ?? _toolMessageIds[tool.toolCallId];
      entries[index] = TranscriptEntry.tool(merged, messageId: msgId);
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
    notifyListeners();
  }

  Future<void> appendUserMessage(ChatMessage message) async {
    entries.add(TranscriptEntry.message(message));
    await _db.insertMessage(message);
    onLocalChange?.call(chatId);
    notifyListeners();
  }

  Future<void> disposeRuntime() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await flushAssistantBuffer();
      await commitThought();
    } catch (_) {}
    await _session.close();
  }
}
