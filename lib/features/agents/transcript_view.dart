import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../app/app_theme.dart';
import '../../app/platform_layout.dart';
import '../../data/models/chat_message.dart';
import '../../data/models/prompt_image.dart';
import '../../data/models/scheduled_job.dart';
import '../../data/models/tool_call_state.dart';
import 'agent_status_indicators.dart';
import 'message_body.dart';
import 'tool_call_card.dart';
import 'transcript_snapshot.dart';

typedef ToolDetailsResolver = Future<List<ToolCallState>> Function(
  List<ToolCallState> summaries,
  List<String?> messageIds,
);

/// Handle for [ChatScreen] to drive a [TranscriptView].
class TranscriptController {
  _TranscriptViewState? _state;

  /// True while the viewport is glued to the live end.
  final ValueNotifier<bool> following = ValueNotifier(true);

  /// Resume following and scroll to the newest row.
  void jumpToLatest() => _state?._jumpToLatest();

  void dispose() => following.dispose();
}

/// Measure every row's real height in idle time (3 ms/frame budget) so the
/// scrollbar and thumb-drag mapping are exact instead of re-estimated from
/// the average of built rows — with markdown rows varying 10×, that estimate
/// swung the total extent by ~10 % per scroll step.
class _PrecalculateAll extends ExtentPrecalculationPolicy {
  @override
  bool shouldPrecalculateExtents(ExtentPrecalculationContext context) =>
      context.numberOfItemsWithEstimatedExtent > 0;
}

/// The chat transcript: committed blocks plus the live tail.
///
/// The list is *reversed* — offset 0 is the live end — so following new
/// output costs nothing (the viewport is already anchored there), a chat
/// opens on its newest row with no scroll-to-end dance, and older history
/// prepended at the far end never moves what the user is looking at.
///
/// Scrolling up past [_unfollowPx] freezes the painted [TranscriptSnapshot]
/// like a document: the scrollbar and content stay put until the user comes
/// back to the bottom (or taps the jump button), at which point the live
/// snapshot is swapped in. That is the whole follow/freeze story.
class TranscriptView extends StatefulWidget {
  const TranscriptView({
    super.key,
    required this.snapshot,
    required this.controller,
    this.resolveToolDetails,
    this.onLoadOlder,
    this.onJumpToLatest,
    this.overlay,
  });

  final ValueListenable<TranscriptSnapshot> snapshot;
  final TranscriptController controller;
  final ToolDetailsResolver? resolveToolDetails;

  /// Explicit "load earlier messages" — pulls another chunk of history.
  final Future<void> Function()? onLoadOlder;

  /// Called before scrolling to the live end from the jump button.
  final VoidCallback? onJumpToLatest;

  /// Pinned over the bottom edge (activity strip); never resizes the viewport.
  final Widget? overlay;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final _scroll = ScrollController();

  /// Snapshot painted while the user reads history; null while following.
  TranscriptSnapshot? _frozen;

  /// Rows that arrived while frozen, for the jump-button badge.
  final ValueNotifier<int> _newWhileFrozen = ValueNotifier(0);

  /// Element keys → list index for the current snapshot, so Flutter reuses
  /// elements (expanded tool groups, parsed markdown) when rows shift.
  TranscriptSnapshot? _indexedFor;
  Map<Key, int> _indexByKey = const {};

  /// Distance-from-end thresholds with hysteresis so trackpad inertia near
  /// the bottom cannot flip follow on/off every frame.
  static const double _unfollowPx = 72;
  static const double _refollowPx = 28;

  bool get _following => widget.controller.following.value;

  final _precalculate = _PrecalculateAll();

  /// Rough height for a row that has not been laid out yet: header/meta
  /// chrome plus wrapped lines. Only used until precalculation reaches it.
  double _estimateExtent(TranscriptSnapshot snap, int index, double width) {
    final tail = snap.tailCount;
    String text;
    if (index < tail) {
      text = snap.liveAssistant;
    } else if (index - tail < snap.blocks.length) {
      final b = snap.blocks[snap.blocks.length - 1 - (index - tail)];
      if (b.tools != null || b.entry?.tool != null) return 32;
      text = b.entry?.message?.content ?? b.thinkingOnly ?? '';
    } else {
      return 40;
    }
    final charsPerLine = (width / 7.5).clamp(20, 200);
    var lines = 0;
    for (final l in text.split('\n')) {
      lines += 1 + l.length ~/ charsPerLine;
    }
    return 56 + lines * 22.0;
  }

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
    widget.snapshot.addListener(_onSnapshot);
  }

  @override
  void didUpdateWidget(covariant TranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot != widget.snapshot) {
      oldWidget.snapshot.removeListener(_onSnapshot);
      widget.snapshot.addListener(_onSnapshot);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller._state = null;
      widget.controller._state = this;
    }
  }

  @override
  void dispose() {
    widget.snapshot.removeListener(_onSnapshot);
    if (widget.controller._state == this) widget.controller._state = null;
    _newWhileFrozen.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onSnapshot() {
    if (!mounted) return;
    final frozen = _frozen;
    if (frozen == null) {
      setState(() {});
      return;
    }
    // Reading history: keep the document still. Only rows *prepended* by a
    // "load earlier" (which never move a reversed viewport) are merged in;
    // everything new at the live end waits behind the jump badge.
    final live = widget.snapshot.value;
    var next = frozen;
    if (frozen.blocks.isNotEmpty && live.blocks.isNotEmpty) {
      final firstKey = frozen.blocks.first.key;
      var k = -1;
      for (var i = 0; i < live.blocks.length; i++) {
        if (live.blocks[i].key == firstKey) {
          k = i;
          break;
        }
      }
      if (k > 0) {
        next = next.copyWith(
          blocks: [...live.blocks.sublist(0, k), ...frozen.blocks],
        );
      }
    }
    if (live.loadingOlder != next.loadingOlder ||
        live.hasMoreOlder != next.hasMoreOlder) {
      next = next.copyWith(
        loadingOlder: live.loadingOlder,
        hasMoreOlder: live.hasMoreOlder,
      );
    }
    final delta = (live.blocks.length + live.tailCount) -
        (next.blocks.length + next.tailCount);
    _newWhileFrozen.value = delta < 0 ? 0 : delta;
    if (!identical(next, frozen)) setState(() => _frozen = next);
  }

  void _setFollowing(bool follow) {
    if (follow == _following) return;
    widget.controller.following.value = follow;
    setState(() {
      // Freezing keeps the live rows' text fixed (no re-parse); shimmer and
      // auto-expand are driven by [_following] instead.
      _frozen = follow ? null : widget.snapshot.value;
      if (follow) _newWhileFrozen.value = 0;
    });
  }

  /// True while our own animateTo(0) runs — its intermediate offsets must not
  /// read as the user scrolling away.
  bool _animatingToLatest = false;

  void _jumpToLatest() {
    widget.onJumpToLatest?.call();
    _setFollowing(true);
    if (!_scroll.hasClients || _scroll.position.pixels <= 0) return;
    _animatingToLatest = true;
    _scroll
        .animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() => _animatingToLatest = false);
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is! ScrollUpdateNotification &&
        n is! ScrollEndNotification &&
        n is! UserScrollNotification) {
      return false;
    }
    if (_animatingToLatest) {
      // A user gesture interrupts the animation and ends it; let the next
      // notification be judged normally.
      if (n is UserScrollNotification || n is ScrollEndNotification) {
        _animatingToLatest = false;
      }
      return false;
    }
    final px = n.metrics.pixels;
    if (_following) {
      if (px > _unfollowPx) _setFollowing(false);
    } else if (px <= _refollowPx && n is! UserScrollNotification) {
      _setFollowing(true);
    }
    return false;
  }

  Map<Key, int> _indexFor(TranscriptSnapshot snap) {
    if (identical(_indexedFor, snap)) return _indexByKey;
    final map = <Key, int>{};
    final total = _itemCount(snap);
    for (var i = 0; i < total; i++) {
      map[_keyAt(snap, i)] = i;
    }
    _indexedFor = snap;
    _indexByKey = map;
    return map;
  }

  int _itemCount(TranscriptSnapshot snap) =>
      snap.tailCount + snap.blocks.length + (snap.hasMoreOlder ? 1 : 0);

  static const _loadEarlierKey = ValueKey('transcript-load-earlier');

  /// List index → stable key. Index 0 is the newest row.
  Key _keyAt(TranscriptSnapshot snap, int index) {
    final tail = snap.tailCount;
    if (index < tail) {
      // Tail in chronological order: thinking, live answer, queued prompts.
      final chrono = tail - 1 - index;
      var cursor = 0;
      if (snap.hasLiveThinking) {
        if (chrono == cursor) return const ValueKey('live-thinking');
        cursor++;
      }
      if (snap.hasLiveAssistant) {
        if (chrono == cursor) {
          return ValueKey('entry:${snap.liveAssistantId ?? 'live-assistant'}');
        }
        cursor++;
      }
      return ValueKey('queued:${snap.queued[chrono - cursor].id}');
    }
    final b = index - tail;
    if (b < snap.blocks.length) {
      return ValueKey(snap.blocks[snap.blocks.length - 1 - b].key);
    }
    return _loadEarlierKey;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snap = _frozen ?? widget.snapshot.value;
    final index = _indexFor(snap);
    final desktop = useDesktopShell(context);
    final sidePad = desktop ? 40.0 : 16.0;

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: GptMarkdownTheme(
            gptThemeData: chatGptMarkdownTheme(theme),
            child: SuperListView.custom(
              controller: _scroll,
              reverse: true,
              physics: const AlwaysScrollableScrollPhysics(),
              // Reversed: `bottom` is the edge nearest the composer.
              padding: EdgeInsets.fromLTRB(sidePad, 12, sidePad, 16),
              cacheExtent: 600,
              extentPrecalculationPolicy: _precalculate,
              extentEstimation: (index, crossAxisExtent) =>
                  _estimateExtent(snap, index ?? 0, crossAxisExtent),
              childrenDelegate: SliverChildBuilderDelegate(
                (context, i) => _buildRow(context, snap, i),
                childCount: _itemCount(snap),
                findChildIndexCallback: (key) => index[key],
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: false,
                addSemanticIndexes: false,
              ),
            ),
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: widget.controller.following,
          builder: (context, following, _) {
            if (following) return const SizedBox.shrink();
            return Positioned(
              left: 0,
              right: 0,
              bottom: 12,
              child: Center(
                child: _JumpToLatestButton(
                  newCount: _newWhileFrozen,
                  onTap: _jumpToLatest,
                ),
              ),
            );
          },
        ),
        if (widget.overlay != null)
          Positioned(left: 0, right: 0, bottom: 0, child: widget.overlay!),
      ],
    );
  }

  Widget _buildRow(BuildContext context, TranscriptSnapshot snap, int i) {
    final key = _keyAt(snap, i);
    final tail = snap.tailCount;
    final Widget body;
    if (i < tail) {
      body = _buildTailRow(snap, tail - 1 - i);
    } else if (i - tail < snap.blocks.length) {
      final c = snap.blocks.length - 1 - (i - tail);
      body = _buildBlockRow(snap, c);
    } else {
      body = _LoadEarlierRow(
        loading: snap.loadingOlder,
        onTap: widget.onLoadOlder,
      );
    }
    return KeyedSubtree(key: key, child: RepaintBoundary(child: body));
  }

  Widget _buildTailRow(TranscriptSnapshot snap, int chrono) {
    var cursor = 0;
    if (snap.hasLiveThinking) {
      if (chrono == cursor) {
        return ThinkingFold(
          text: snap.liveThinking,
          streaming: snap.streaming && !snap.hasLiveAssistant,
          animate: _following,
          initiallyExpanded: snap.streaming,
        );
      }
      cursor++;
    }
    if (snap.hasLiveAssistant) {
      if (chrono == cursor) {
        return ChatBubble(
          role: MessageRole.assistant,
          text: snap.liveAssistant,
          streaming: snap.streaming,
        );
      }
      cursor++;
    }
    final m = snap.queued[chrono - cursor];
    return ChatBubble(
      role: MessageRole.user,
      text: m.content,
      at: m.createdAt,
      queued: true,
    );
  }

  Widget _buildBlockRow(TranscriptSnapshot snap, int c) {
    final blocks = snap.blocks;
    final block = blocks[c];
    final prevAt = c > 0 ? blocks[c - 1].createdAt : null;
    final at = block.createdAt;
    final showDate = at != null &&
        (prevAt == null ||
            prevAt.year != at.year ||
            prevAt.month != at.month ||
            prevAt.day != at.day);

    final Widget body;
    final tools = block.tools;
    if (block.thinkingOnly != null) {
      body = ThinkingFold(text: block.thinkingOnly!);
    } else if (tools != null) {
      body = ToolCallGroupCard(
        tools: [for (final e in tools) e.tool!],
        messageIds: [for (final e in tools) e.messageId],
        resolveDetails: widget.resolveToolDetails,
        animate: _following,
      );
    } else if (block.entry!.tool != null) {
      final entry = block.entry!;
      body = ToolCallGroupCard(
        tools: [entry.tool!.withoutPayloads()],
        messageIds: [entry.messageId],
        resolveDetails: widget.resolveToolDetails,
        animate: _following,
      );
    } else {
      final m = block.entry!.message!;
      final bubble = ChatBubble(role: m.role, text: m.content, at: m.createdAt);
      final thinking = block.thinking;
      body = (thinking != null && thinking.isNotEmpty)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [ThinkingFold(text: thinking), bubble],
            )
          : bubble;
    }

    final stats = block.turnStats;
    final withStats = (stats != null && stats.isNotEmpty)
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              body,
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 2, bottom: 4),
                child: TurnMetricsLabel(
                  added: stats.added,
                  removed: stats.removed,
                  files: stats.files,
                ),
              ),
            ],
          )
        : body;
    if (!showDate) return withStats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [DateChip(at), withStats],
    );
  }
}

class _JumpToLatestButton extends StatelessWidget {
  const _JumpToLatestButton({required this.newCount, required this.onTap});

  final ValueListenable<int> newCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: newCount,
      builder: (context, n, _) {
        return Material(
          elevation: 3,
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(n > 0 ? 12 : 8, 6, n > 0 ? 8 : 8, 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (n > 0) ...[
                    Text(
                      n == 1 ? '1 new' : '$n new',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LoadEarlierRow extends StatelessWidget {
  const _LoadEarlierRow({required this.loading, this.onTap});

  final bool loading;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: TextButton.icon(
          onPressed: loading || onTap == null ? null : () => onTap!(),
          icon: loading
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              : const Icon(Icons.history_rounded, size: 14),
          label: Text(
            loading ? 'Loading earlier…' : 'Load earlier messages',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Collapsible "Thinking" section above an assistant reply.
class ThinkingFold extends StatefulWidget {
  const ThinkingFold({
    super.key,
    required this.text,
    this.streaming = false,
    this.animate = true,
    this.initiallyExpanded = false,
  });

  final String text;

  /// More reasoning may still arrive (renders live, auto-expands).
  final bool streaming;

  /// Run the shimmer ticker (off while the user reads history).
  final bool animate;

  final bool initiallyExpanded;

  @override
  State<ThinkingFold> createState() => _ThinkingFoldState();
}

class _ThinkingFoldState extends State<ThinkingFold> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  void didUpdateWidget(covariant ThinkingFold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.streaming && !oldWidget.streaming) _expanded = true;
    if (!widget.streaming && oldWidget.streaming) _expanded = false;
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
            color: theme.colorScheme.surfaceContainerHigh.withValues(
              alpha: 0.55,
            ),
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
                            enabled: widget.streaming && widget.animate,
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
                      live: widget.streaming,
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

/// One message. Cursor-style: user = soft raised pill; agent = bare text.
class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
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
            Icon(
              Icons.psychology_alt,
              size: 14,
              color: theme.colorScheme.outline,
            ),
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

    final desktop = useDesktopShell(context);
    final onText = isUser ? AppColors.onBubbleUser : AppColors.chatAgentText;
    final metaColor = AppColors.chatMeta;
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: onText,
      height: 1.45,
      fontSize: 15,
    );

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: desktop ? MainAxisSize.max : MainAxisSize.min,
      children: [
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
            padding: EdgeInsets.only(bottom: bodyText.trim().isEmpty ? 0 : 8),
            child: _BubbleImages(refs: imageRefs),
          ),
        if (bodyText.isNotEmpty || streaming)
          MessageBody(
            text: bodyText,
            style: bodyStyle,
            live: streaming,
          ),
        if (!streaming && (at != null || bodyText.trim().isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              // Desktop: meta hugs the trailing edge of a full-width pill.
              // Phone: keep meta with the text so it does not look
              // right-justified across the screen.
              mainAxisAlignment:
                  desktop ? MainAxisAlignment.end : MainAxisAlignment.start,
              mainAxisSize: desktop ? MainAxisSize.max : MainAxisSize.min,
              children: [
                if (!queued && bodyText.trim().isNotEmpty) ...[
                  _MetaIconButton(
                    tooltip: 'Copy text for Teams',
                    icon: Icons.copy_rounded,
                    size: 14,
                    color: metaColor,
                    onPressed: () => copyMessageForTeams(context, bodyText),
                  ),
                  _MetaIconButton(
                    tooltip: 'Copy HTML for Teams',
                    icon: Icons.html,
                    size: 15,
                    color: metaColor,
                    onPressed: () =>
                        copyMessageHtmlForTeams(context, bodyText),
                  ),
                ],
                if (at != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      formatClock(at!),
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
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth:
                MediaQuery.sizeOf(context).width * (desktop ? 0.92 : 0.88),
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

class _MetaIconButton extends StatelessWidget {
  const _MetaIconButton({
    required this.tooltip,
    required this.icon,
    required this.size,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      onPressed: onPressed,
      icon: Icon(icon, size: size, color: color.withValues(alpha: 0.85)),
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
                    errorBuilder: (_, _, _) => Container(
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

String formatClock(DateTime at) {
  final local = at.toLocal();
  final h = local.hour.toString().padLeft(2, '0');
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

class DateChip extends StatelessWidget {
  const DateChip(this.day, {super.key});

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
