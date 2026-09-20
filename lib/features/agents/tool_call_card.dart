import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/tool_call_state.dart';
import 'agent_status_indicators.dart';

/// Count-only row for a run of consecutive tool calls.
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
  });

  /// Lightweight summaries (no raw input/output) used for the count row.
  final List<ToolCallState> tools;

  /// Parallel SQLite message ids for [tools], when known.
  final List<String?> messageIds;

  /// Loads full tool payloads when the group is expanded.
  final Future<List<ToolCallState>> Function(
    List<ToolCallState> summaries,
    List<String?> messageIds,
  )? resolveDetails;

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

  String get _groupLabel {
    final count = widget.tools.length;
    if (_anyActive) {
      return count == 1 ? '1 tool running' : '$count tools running';
    }
    return count == 1 ? '1 tool' : '$count tools';
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
    // If the group identity changed while expanded, drop stale details.
    if (_expanded &&
        (oldWidget.tools.length != widget.tools.length ||
            oldWidget.tools.first.toolCallId != widget.tools.first.toolCallId)) {
      _details = null;
      _expanded = false;
      _loading = false;
      _loadError = null;
    }
  }

  @override
  Widget build(BuildContext context) {
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
                            : Icons.auto_awesome_outlined,
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
                        enabled: _anyActive && !_expanded,
                        child: Text(
                          _loading ? 'Loading tools…' : _groupLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: labelColor,
                            fontWeight: FontWeight.w500,
                            height: 1.3,
                          ),
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

  IconData get _kindIcon {
    final k = (widget.tool.kind ?? '').toLowerCase();
    final title = widget.tool.title.toLowerCase();
    final blob = '$k $title';
    if (k.contains('think') ||
        k.contains('task') ||
        k.contains('agent') ||
        blob.contains('subagent')) {
      return Icons.hub_outlined;
    }
    if (blob.contains('web') ||
        blob.contains('browser') ||
        k.contains('fetch') ||
        k.contains('http')) {
      return Icons.language_rounded;
    }
    if (k.contains('exec') || k.contains('shell') || k.contains('terminal')) {
      return Icons.terminal_rounded;
    }
    if (k.contains('read')) return Icons.description_outlined;
    if (k.contains('edit') || k.contains('write')) return Icons.edit_outlined;
    if (k.contains('search') || k.contains('grep') || k.contains('glob')) {
      return Icons.search_rounded;
    }
    if (k.contains('delete')) return Icons.delete_outline;
    if (k.contains('mcp')) return Icons.extension_outlined;
    return Icons.auto_awesome_outlined;
  }

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
                                  : _kindIcon,
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
