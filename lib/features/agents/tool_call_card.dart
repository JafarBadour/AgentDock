import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/tool_call_state.dart';
import 'agent_status_indicators.dart';
import 'subagent_card.dart';

/// One row for a run of consecutive tool calls, labelled by what the run did
/// ("Read 3 files · Ran 2 commands"; a single tool shows its own preview).
///
/// Details stay out of the transcript until the user expands — then they are
/// fetched (local DB / live runtime / ADSM) and dropped again on collapse so
/// the widget tree does not keep huge tool payloads mounted.
class ToolCallGroupCard extends StatefulWidget {
  const ToolCallGroupCard({
    super.key,
    required this.tools,
    this.messageIds = const [],
    this.resolveDetails,
    this.animate = true,
  });

  /// Lightweight summaries (no raw input/output) used for the header row.
  final List<ToolCallState> tools;

  /// Parallel SQLite message ids for [tools], when known.
  final List<String?> messageIds;

  /// Loads full tool payloads when the group is expanded.
  final Future<List<ToolCallState>> Function(
    List<ToolCallState> summaries,
    List<String?> messageIds,
  )? resolveDetails;

  /// When false (user scrolled up), skip shimmer tickers so scroll stays smooth.
  final bool animate;

  @override
  State<ToolCallGroupCard> createState() => _ToolCallGroupCardState();
}

class _ToolCallGroupCardState extends State<ToolCallGroupCard> {
  bool _expanded = false;
  bool _loading = false;
  String? _loadError;
  List<ToolCallState>? _details;

  bool get _anyActive => widget.tools.any((t) => t.isActive);
  bool get _hardFails => widget.tools.where((t) => t.isHardFail).isNotEmpty;
  int get _hardFailCount => widget.tools.where((t) => t.isHardFail).length;
  int get _softFailCount => widget.tools.where((t) => t.isSoftFail).length;

  /// Collapsed header: what the run did, not just how many calls it made.
  InlineSpan _groupLabel(ThemeData theme, Color color) {
    final tools = widget.tools;
    final base = theme.textTheme.bodySmall?.copyWith(
      color: color,
      fontWeight: FontWeight.w500,
      height: 1.3,
    );
    final mono = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
      fontFamily: 'monospace',
      fontSize: 11,
      height: 1.3,
    );
    if (tools.length == 1) {
      final t = tools.first;
      final preview = t.preview;
      return TextSpan(
        style: base,
        children: [
          TextSpan(text: t.displayTitle),
          if (preview != null && preview != t.displayTitle)
            TextSpan(text: '  $preview', style: mono),
        ],
      );
    }
    final summary = ToolCallState.summarizeActions(tools);
    final running = _anyActive ? ' · running' : '';
    return TextSpan(style: base, text: '$summary$running');
  }

  Future<void> _toggle() async {
    if (_expanded) {
      // Drop payloads from the tree as soon as the user collapses.
      setState(() {
        _expanded = false;
        _loading = false;
        _loadError = null;
        _details = null;
      });
      return;
    }

    setState(() {
      _expanded = true;
      _loading = true;
      _loadError = null;
      _details = null;
    });
    // Let the pending spinner paint before we hit ADSM / SQLite.
    await Future<void>.delayed(Duration.zero);
    if (!mounted || !_expanded) return;

    try {
      final loader = widget.resolveDetails;
      final loaded = loader == null
          ? widget.tools
          : await loader(widget.tools, widget.messageIds);
      if (!mounted || !_expanded) return;
      setState(() {
        _details = loaded.isEmpty ? widget.tools : loaded;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || !_expanded) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
        _details = widget.tools;
      });
    }
  }

  @override
  void didUpdateWidget(covariant ToolCallGroupCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_expanded) return;
    if (oldWidget.tools.first.toolCallId != widget.tools.first.toolCallId) {
      // Different group under the same element — drop stale details.
      _details = null;
      _expanded = false;
      _loading = false;
      _loadError = null;
    } else if (oldWidget.tools.length != widget.tools.length && !_loading) {
      // A running group grew while open: stay open, show the summaries (they
      // carry previews) until the user re-expands for full payloads.
      _details = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // A lone sub-agent is a delegated run, not a tool line — give it its card.
    if (widget.tools.length == 1 && widget.tools.first.isSubagent) {
      return SubagentCard(
        tool: widget.tools.first,
        messageId: widget.messageIds.isEmpty ? null : widget.messageIds.first,
        resolveDetails: widget.resolveDetails,
        animate: widget.animate,
      );
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hard = _hardFails;
    final softOnly = !hard && _softFailCount > 0;
    final labelColor = hard
        ? scheme.error
        : scheme.onSurfaceVariant.withValues(alpha: 0.85);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _loading ? null : () => _toggle(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                child: Row(
                  children: [
                    if (_loading)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: scheme.primary,
                        ),
                      )
                    else
                      Icon(
                        hard
                            ? Icons.error_outline
                            : widget.tools.length == 1
                                ? toolKindIcon(widget.tools.first)
                                : Icons.layers_outlined,
                        size: 14,
                        color: hard
                            ? scheme.error
                            : _anyActive
                                ? scheme.primary
                                : scheme.outline,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Shimmer(
                        enabled:
                            widget.animate && _anyActive && !_expanded,
                        child: Text.rich(
                          _loading
                              ? TextSpan(
                                  text: 'Loading tools…',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: labelColor,
                                    fontWeight: FontWeight.w500,
                                    height: 1.3,
                                  ),
                                )
                              : _groupLabel(theme, labelColor),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (!_loading && hard) ...[
                      Text(
                        _hardFailCount == 1
                            ? 'Failed'
                            : '$_hardFailCount failed',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.error),
                      ),
                      const SizedBox(width: 4),
                    ] else if (!_loading && softOnly) ...[
                      Text(
                        _softFailCount == 1
                            ? 'Exit 1'
                            : '$_softFailCount exit ≠0',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.outline),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 16,
                      color: scheme.outline,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded) ...[
              if (_loading)
                const Padding(
                  padding: EdgeInsets.fromLTRB(22, 8, 8, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else ...[
                if (_loadError != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 4, 8, 4),
                    child: Text(
                      'Could not load full tool details',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.error),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Column(
                    children: [
                      for (final tool in _details ?? widget.tools)
                        if (tool.isSubagent)
                          SubagentCard(tool: tool, animate: widget.animate)
                        else
                          ToolCallCard(tool: tool),
                    ],
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Icon for a tool's coarse category.
IconData toolKindIcon(ToolCallState tool) => switch (tool.actionKind) {
      ToolActionKind.subagent => Icons.hub_outlined,
      ToolActionKind.web => Icons.language_rounded,
      ToolActionKind.exec => Icons.terminal_rounded,
      ToolActionKind.read => Icons.description_outlined,
      ToolActionKind.edit => Icons.edit_outlined,
      ToolActionKind.search => Icons.search_rounded,
      ToolActionKind.mcp => Icons.extension_outlined,
      ToolActionKind.other => Icons.auto_awesome_outlined,
    };

/// One line of agent activity, expandable into the raw input/output.
///
/// Only mounted while a [ToolCallGroupCard] is expanded — collapse removes it.
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.tool});

  final ToolCallState tool;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tool = widget.tool;

    final active = tool.isActive;
    final hardFail = tool.isHardFail;
    final softFail = tool.isSoftFail;

    final labelColor = hardFail
        ? scheme.error
        : active
            ? scheme.onSurfaceVariant
            : scheme.onSurfaceVariant.withValues(alpha: 0.85);

    final hasDetails = (tool.rawInput?.isNotEmpty ?? false) ||
        (tool.rawOutput?.isNotEmpty ?? false) ||
        tool.locations.isNotEmpty;

    final titleStyle = theme.textTheme.bodySmall?.copyWith(
      color: labelColor,
      fontWeight: FontWeight.w500,
      height: 1.3,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: hasDetails
                    ? () => setState(() => _expanded = !_expanded)
                    : null,
                child: Row(
                  children: [
                    Icon(
                      hardFail
                          ? Icons.error_outline
                          : softFail
                              ? Icons.warning_amber_outlined
                              : (active && tool.isPollingWait)
                                  ? Icons.hourglass_top_rounded
                                  : toolKindIcon(tool),
                      size: 14,
                      color: hardFail
                          ? scheme.error
                          : softFail
                              ? scheme.outline
                              : active
                                  ? scheme.primary
                                  : scheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Shimmer(
                        enabled: false,
                        child: Text.rich(
                          TextSpan(
                            style: titleStyle,
                            children: [
                              TextSpan(text: tool.displayTitle),
                              if (tool.preview != null)
                                TextSpan(
                                  text: '  ${tool.preview}',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: scheme.outline,
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    height: 1.3,
                                  ),
                                ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (hardFail ||
                        softFail ||
                        (active && tool.isPollingWait)) ...[
                      Text(
                        tool.statusLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: hardFail
                              ? scheme.error
                              : softFail
                                  ? scheme.outline
                                  : scheme.primary,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (hasDetails)
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: scheme.outline,
                      ),
                  ],
                ),
              ),
              if (_expanded && hasDetails)
                Padding(
                  padding: const EdgeInsets.only(left: 22, top: 8, bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (tool.locations.isNotEmpty) ...[
                        _SectionLabel('Paths'),
                        const SizedBox(height: 4),
                        ...tool.locations.map(
                          (p) => Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: SelectableText(
                              p,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (tool.rawInput?.isNotEmpty ?? false) ...[
                        _SectionLabel('Input'),
                        const SizedBox(height: 4),
                        _CodeBlock(text: tool.rawInput!),
                        const SizedBox(height: 8),
                      ],
                      if (tool.rawOutput?.isNotEmpty ?? false) ...[
                        _SectionLabel('Output'),
                        const SizedBox(height: 4),
                        _CodeBlock(text: tool.rawOutput!),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.outline,
        letterSpacing: 0.8,
        fontSize: 10,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: SingleChildScrollView(
        child: SelectableLinkify(
          text: text,
          onOpen: (link) async {
            var raw = link.url.trim();
            if (!raw.contains('://')) raw = 'https://$raw';
            final uri = Uri.tryParse(raw);
            if (uri == null) return;
            try {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            } catch (_) {}
          },
          options: const LinkifyOptions(humanize: false, looseUrl: true),
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.4,
          ),
          linkStyle: TextStyle(
            color: theme.colorScheme.primary,
            decoration: TextDecoration.underline,
            fontFamily: 'monospace',
            fontSize: 11,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
