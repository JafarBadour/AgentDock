import '../../data/models/chat_message.dart';
import '../../data/models/code_change_stats.dart';
import '../../data/models/thought_message.dart';
import '../../data/models/tool_call_state.dart';
import '../../data/models/turn_stats_message.dart';
import '../../services/chat_session_runtime.dart';

/// One paint unit in the transcript list: a message, a lone tool, a
/// collapsed run of consecutive tools, or a standalone thinking fold.
class ChatBlock {
  const ChatBlock._({
    this.entry,
    this.tools,
    this.thinking,
    this.thinkingOnly,
    this.turnStats,
  });

  factory ChatBlock.single(TranscriptEntry entry, {String? thinking}) =>
      ChatBlock._(entry: entry, thinking: thinking);

  factory ChatBlock.tools(List<TranscriptEntry> tools) =>
      ChatBlock._(tools: tools);

  factory ChatBlock.thinking(String text) =>
      ChatBlock._(thinkingOnly: text);

  final TranscriptEntry? entry;
  final List<TranscriptEntry>? tools;

  /// Reasoning attached above an assistant [entry].
  final String? thinking;

  /// Standalone thinking row (no assistant text yet / orphan).
  final String? thinkingOnly;

  /// Per-command `+X -Y · Z φ · N τ` footer after this block.
  final TurnStats? turnStats;

  ChatBlock withTurnStats(TurnStats stats) => ChatBlock._(
        entry: entry,
        tools: tools,
        thinking: thinking,
        thinkingOnly: thinkingOnly,
        turnStats: stats,
      );

  DateTime? get createdAt => tools?.first.createdAt ?? entry?.createdAt;

  /// Stable identity across rebuilds so list elements (and their expanded /
  /// collapsed state) survive rows being inserted around them.
  String get key {
    final t = tools;
    if (t != null && t.isNotEmpty) {
      return 'tools:${t.first.tool?.toolCallId ?? t.first.messageId ?? ''}';
    }
    final e = entry;
    if (e != null) {
      final id = e.messageId ?? e.tool?.toolCallId;
      if (id != null && id.isNotEmpty) return 'entry:$id';
    }
    final think = thinkingOnly;
    if (think != null) return 'think:${think.hashCode}';
    return 'block:$hashCode';
  }
}

/// Stable chronological order for the transcript list.
List<TranscriptEntry> entriesByTime(List<TranscriptEntry> input) {
  if (input.length < 2) return input;
  // Entries are almost always append-ordered — skip the O(n log n) sort.
  var needsSort = false;
  for (var i = 1; i < input.length; i++) {
    final a = input[i - 1].createdAt;
    final b = input[i].createdAt;
    if (a != null && b != null && a.isAfter(b)) {
      needsSort = true;
      break;
    }
  }
  if (!needsSort) return input;
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

/// Cache key for [buildTranscriptBlocks] memoization.
String transcriptBlocksCacheKey(
  List<TranscriptEntry> entries, {
  required bool openTurnActive,
}) {
  final last = entries.isEmpty ? null : entries.last;
  final tool = last?.tool;
  // Bucket tool stdout so live output growth does not rebuild every block.
  final outBucket = tool == null ? 0 : (tool.rawOutput?.length ?? 0) >> 12;
  final contentBucket = tool == null ? 0 : (tool.content?.length ?? 0) >> 12;
  final msgLen = last?.message?.content.length ?? 0;
  return '${entries.length}|$openTurnActive|'
      '${last?.messageId ?? ''}|${tool?.toolCallId ?? ''}|'
      '${tool?.status ?? ''}|${msgLen >> 5}|$outBucket|$contentBucket';
}

/// Collapse tool spam between user messages into one expandable row.
///
/// System (thought) messages fold into the next assistant reply as a
/// collapsible "Thinking" section. Turn stats attach to the last block of
/// each finished assistant segment.
List<ChatBlock> buildTranscriptBlocks(
  List<TranscriptEntry> entries, {
  bool openTurnActive = false,
}) {
  final thinkingByAssistantId = <String, String>{};
  final pendingThoughts = <String>[];
  final compact = <TranscriptEntry>[];
  final orphanBeforeIndex = <int, String>{};
  final turnStatsAfterIndex = <int, TurnStats>{};
  String? trailingThinking;

  for (final e in entries) {
    final role = e.message?.role;
    if (role == MessageRole.system) {
      final content = e.message!.content;
      final stats = TurnStatsMessage.tryParse(content);
      if (stats != null) {
        if (compact.isNotEmpty) {
          turnStatsAfterIndex[compact.length - 1] = stats;
        }
        continue;
      }
      final body = ThoughtMessage.display(content);
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

  final blocks = <ChatBlock>[];
  var i = 0;
  while (i < compact.length) {
    final orphan = orphanBeforeIndex[i];
    if (orphan != null && orphan.isNotEmpty) {
      blocks.add(ChatBlock.thinking(orphan));
    }

    final entry = compact[i];
    if (entry.message?.role == MessageRole.user) {
      blocks.add(ChatBlock.single(entry));
      i++;
      continue;
    }

    final segmentStart = i;
    final segment = <TranscriptEntry>[];
    while (i < compact.length &&
        compact[i].message?.role != MessageRole.user) {
      if (i != segmentStart && orphanBeforeIndex.containsKey(i)) break;
      segment.add(compact[i]);
      i++;
    }

    TurnStats? persistedStats;
    for (var j = segmentStart; j < i; j++) {
      final s = turnStatsAfterIndex[j];
      if (s != null) persistedStats = s;
    }
    final toolsInSeg = [
      for (final e in segment)
        if (e.tool != null) e.tool!,
    ];
    // Persisted turn stats already have the code delta — don't re-walk
    // every tool's JSON/diff on each rebuild.
    final computed = (persistedStats != null && persistedStats.hasCodeDelta)
        ? const CodeChangeStats()
        : CodeChangeStats.fromTools(toolsInSeg);
    final turnStats =
        (persistedStats ?? const TurnStats()).mergeComputed(computed);

    final segmentBlocks = <ChatBlock>[];
    // Keep tools interleaved with assistant text. Collapse only consecutive
    // tool runs (not every tool in the whole turn into one end clump).
    final toolRun = <TranscriptEntry>[];

    void flushToolRun() {
      if (toolRun.isEmpty) return;
      // Always count-only groups — details load on expand, not in the list.
      // Sub-agents break the run: a delegated run is its own card, so it never
      // disappears into a "Read 3 files · 1 subagent" summary.
      final pending = <TranscriptEntry>[];
      void emitGroup() {
        if (pending.isEmpty) return;
        segmentBlocks.add(ChatBlock.tools(List.of(pending)));
        pending.clear();
      }

      for (final e in toolRun) {
        final summary = TranscriptEntry.tool(
          e.tool!.withoutPayloads(),
          messageId: e.messageId,
          createdAt: e.createdAt,
        );
        if (summary.tool!.isSubagent) {
          emitGroup();
          segmentBlocks.add(ChatBlock.tools([summary]));
          continue;
        }
        pending.add(summary);
      }
      emitGroup();
      toolRun.clear();
    }

    for (final e in segment) {
      if (e.tool != null) {
        toolRun.add(e);
        continue;
      }
      flushToolRun();
      final id = e.message?.id;
      segmentBlocks.add(
        ChatBlock.single(
          e,
          thinking: e.message?.role == MessageRole.assistant && id != null
              ? thinkingByAssistantId[id]
              : null,
        ),
      );
    }
    flushToolRun();
    final followedByUser = i < compact.length &&
        compact[i].message?.role == MessageRole.user;
    final isLastSegment = i >= compact.length;
    final showStats = turnStats.isNotEmpty &&
        (persistedStats != null ||
            followedByUser ||
            (isLastSegment && !openTurnActive));
    if (segmentBlocks.isNotEmpty && showStats) {
      final last = segmentBlocks.removeLast();
      segmentBlocks.add(last.withTurnStats(turnStats));
    }
    blocks.addAll(segmentBlocks);
  }

  if (trailingThinking != null && trailingThinking.isNotEmpty) {
    blocks.add(ChatBlock.thinking(trailingThinking));
  }
  return blocks;
}

/// Convert DB rows into transcript entries (tool JSON → [ToolCallState]).
List<TranscriptEntry> entriesFromMessages(List<ChatMessage> messages) {
  final out = <TranscriptEntry>[];
  for (final m in messages) {
    if (m.role == MessageRole.tool) {
      final tool = ToolCallState.tryParseContent(m.content);
      if (tool != null) {
        out.add(
          TranscriptEntry.tool(
            tool,
            messageId: m.id,
            createdAt: m.createdAt,
          ),
        );
        continue;
      }
    }
    out.add(TranscriptEntry.message(m));
  }
  return out;
}
