import 'dart:isolate';

import '../data/models/chat_message.dart';
import '../data/models/tool_call_state.dart';
import 'chat_session_runtime.dart';

/// A transcript row with its tool JSON already decoded and summarized.
///
/// Decoding a 1 MiB history chunk is ~20 ms of pure CPU (tool rows are
/// 100 KB+ JSON each), so it happens in a worker isolate and only the parsed
/// objects come back — via `Isolate.exit`, without a copy.
typedef ParsedTranscriptRow = ({
  ChatMessage message,
  ToolCallState? tool,
  ToolCallState? summary,
});

/// Decode tool rows; non-tool rows (and unparseable tool rows) pass through.
List<ParsedTranscriptRow> parseTranscriptRows(List<ChatMessage> messages) {
  final out = <ParsedTranscriptRow>[];
  for (final m in messages) {
    if (m.role == MessageRole.tool) {
      final tool = ToolCallState.tryParseContent(m.content);
      if (tool != null) {
        out.add((message: m, tool: tool, summary: tool.withoutPayloads()));
        continue;
      }
    }
    out.add((message: m, tool: null, summary: null));
  }
  return out;
}

/// Bytes of content below which parsing inline beats spawning an isolate.
const int kInlineParseBytes = 32 * 1024;

/// [parseTranscriptRows], off the UI isolate when the batch is large.
Future<List<ParsedTranscriptRow>> parseTranscriptRowsOffThread(
  List<ChatMessage> messages,
) {
  var bytes = 0;
  for (final m in messages) {
    bytes += m.content.length;
    if (bytes >= kInlineParseBytes) break;
  }
  if (bytes < kInlineParseBytes) {
    return Future.value(parseTranscriptRows(messages));
  }
  return Isolate.run(() => parseTranscriptRows(messages));
}

/// DB rows → list entries carrying tool *summaries* (no payload blobs), the
/// same shape the live runtime keeps, so block building stays cheap.
Future<List<TranscriptEntry>> entriesFromMessagesOffThread(
  List<ChatMessage> messages,
) async {
  final rows = await parseTranscriptRowsOffThread(messages);
  return [
    for (final r in rows)
      if (r.summary != null)
        TranscriptEntry.tool(
          r.summary!,
          messageId: r.message.id,
          createdAt: r.message.createdAt,
        )
      else
        TranscriptEntry.message(r.message),
  ];
}
