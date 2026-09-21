import '../../data/models/chat_message.dart';
import 'transcript_blocks.dart';

/// Immutable picture of everything the transcript list paints.
///
/// [ChatScreen] builds one per coalesced runtime flush and pushes it into a
/// `ValueNotifier`; [TranscriptView] is the only widget that rebuilds on it.
/// Committed [blocks] are chronological; the live tail (thinking, streaming
/// answer, queued prompts) is kept separately so the list can key it stably.
class TranscriptSnapshot {
  const TranscriptSnapshot({
    this.blocks = const [],
    this.liveThinking = '',
    this.liveAssistant = '',
    this.liveAssistantId,
    this.streaming = false,
    this.queued = const [],
    this.hasMoreOlder = false,
    this.loadingOlder = false,
  });

  static const empty = TranscriptSnapshot();

  final List<ChatBlock> blocks;

  /// Reasoning for the turn in progress (before the answer starts).
  final String liveThinking;

  /// Assistant text still being streamed.
  final String liveAssistant;

  /// Row id the live answer will be committed under, so the streaming bubble
  /// and its committed block share one list element (no re-parse on finish).
  final String? liveAssistantId;

  final bool streaming;

  /// Prompts waiting behind the current turn.
  final List<ChatMessage> queued;

  final bool hasMoreOlder;
  final bool loadingOlder;

  bool get hasLiveThinking => liveThinking.isNotEmpty;
  bool get hasLiveAssistant => liveAssistant.isNotEmpty;

  /// Rows after the committed blocks, in chronological order.
  int get tailCount =>
      (hasLiveThinking ? 1 : 0) + (hasLiveAssistant ? 1 : 0) + queued.length;

  bool get isEmpty => blocks.isEmpty && tailCount == 0;

  TranscriptSnapshot copyWith({
    List<ChatBlock>? blocks,
    String? liveThinking,
    String? liveAssistant,
    String? liveAssistantId,
    bool? streaming,
    List<ChatMessage>? queued,
    bool? hasMoreOlder,
    bool? loadingOlder,
  }) =>
      TranscriptSnapshot(
        blocks: blocks ?? this.blocks,
        liveThinking: liveThinking ?? this.liveThinking,
        liveAssistant: liveAssistant ?? this.liveAssistant,
        liveAssistantId: liveAssistantId ?? this.liveAssistantId,
        streaming: streaming ?? this.streaming,
        queued: queued ?? this.queued,
        hasMoreOlder: hasMoreOlder ?? this.hasMoreOlder,
        loadingOlder: loadingOlder ?? this.loadingOlder,
      );
}
