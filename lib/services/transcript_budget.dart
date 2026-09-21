import 'dart:convert';

import '../data/models/chat_message.dart';
import '../data/models/tool_call_state.dart';

/// Soft working-set for the live chat UI.
///
/// Host + SQLite keep the full archive; the phone only mounts ~[chunkBytes]
/// at a time (plus extra chunks the user explicitly loads).
const int kTranscriptChunkBytes = 1024 * 1024; // 1 MiB

/// Per-row overhead so tiny messages still count toward the budget.
const int kTranscriptRowOverheadBytes = 64;

int utf8ByteLength(String text) => utf8.encode(text).length;

int chatMessageBytes(ChatMessage message) =>
    utf8ByteLength(message.content) + kTranscriptRowOverheadBytes;

int toolCallBytes(ToolCallState tool) =>
    // Length is a good enough budget proxy — utf8.encode on every trim/upsert
    // was freezing the UI isolate during tool-heavy turns.
    tool.title.length +
    (tool.kind?.length ?? 0) +
    (tool.content?.length ?? 0) +
    (tool.rawInput?.length ?? 0) +
    (tool.rawOutput?.length ?? 0) +
    kTranscriptRowOverheadBytes;

/// Newest-first walk until [maxBytes], returned chronological (oldest→newest).
List<ChatMessage> takeRecentMessagesByBytes(
  List<ChatMessage> chronological, {
  required int maxBytes,
}) {
  if (chronological.isEmpty || maxBytes <= 0) return const [];
  final selected = <ChatMessage>[];
  var used = 0;
  for (var i = chronological.length - 1; i >= 0; i--) {
    final message = chronological[i];
    final bytes = chatMessageBytes(message);
    if (selected.isNotEmpty && used + bytes > maxBytes) break;
    selected.add(message);
    used += bytes;
  }
  return selected.reversed.toList(growable: false);
}

/// Messages strictly older than [beforeId] (by position in [chronological]),
/// then newest-first until [maxBytes].
List<ChatMessage> takeOlderMessagesByBytes(
  List<ChatMessage> chronological, {
  required String beforeId,
  required int maxBytes,
}) {
  if (chronological.isEmpty || maxBytes <= 0) return const [];
  final pivot = chronological.indexWhere((m) => m.id == beforeId);
  if (pivot <= 0) return const [];
  final older = chronological.sublist(0, pivot);
  return takeRecentMessagesByBytes(older, maxBytes: maxBytes);
}
