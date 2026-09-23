import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/tool_call_state.dart';
import 'agent_status_indicators.dart';
import 'message_body.dart';

/// A delegated sub-agent run, shown at its own weight in the transcript.
///
/// A Task call is not "one more tool": it is a second agent that read its own
/// files, ran its own commands and came back with a report. So it gets a card
/// naming the agent type and the job, a live status while it works, and — on
/// expand — the instructions it was given and the report it returned, rendered
/// as markdown instead of the raw JSON blob a plain tool row would show.
class SubagentCard extends StatefulWidget {
  const SubagentCard({
    super.key,
    required this.tool,
    this.messageId,
    this.resolveDetails,
    this.animate = true,
  });

  /// Summary (payload-free) tool call for the header.
  final ToolCallState tool;

  /// SQLite message id for [tool], when known.
  final String? messageId;

  /// Loads the full prompt/report when the card is expanded.
  final Future<List<ToolCallState>> Function(
    List<ToolCallState> summaries,
    List<String?> messageIds,
  )? resolveDetails;

  /// When false (user scrolled up), skip shimmer tickers so scroll stays smooth.
  final bool animate;

  @override
  State<SubagentCard> createState() => _SubagentCardState();
}

class _SubagentCardState extends State<SubagentCard> {
  bool _expanded = false;
  bool _loading = false;
  bool _showPrompt = false;
  String? _loadError;
  ToolCallState? _details;

  ToolCallState get _tool => _details ?? widget.tool;

  Future<void> _toggle() async {
    if (_expanded) {
      // Drop the payloads out of the tree again on collapse.
      setState(() {
        _expanded = false;
        _loading = false;
        _showPrompt = false;
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
    // Let the spinner paint before we hit ADSM / SQLite.
    await Future<void>.delayed(Duration.zero);
    if (!mounted || !_expanded) return;

    try {
      final loader = widget.resolveDetails;
      final loaded = loader == null
          ? [widget.tool]
          : await loader([widget.tool], [widget.messageId]);
      if (!mounted || !_expanded) return;
      setState(() {
        _details = loaded.isEmpty ? widget.tool : loaded.first;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || !_expanded) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
        _details = widget.tool;
      });
    }
  }

  @override
  void didUpdateWidget(covariant SubagentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_expanded) return;
    if (oldWidget.tool.toolCallId != widget.tool.toolCallId) {
      // Different sub-agent under the same element — drop stale details.
      _expanded = false;
      _loading = false;
      _showPrompt = false;
      _loadError = null;
      _details = null;
    } else if (oldWidget.tool.status != widget.tool.status && !_loading) {
      // It finished while open: the report only exists in the new payload.
      _details = null;
    }
  }

  Future<void> _copyReport(String report) async {
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Report copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tool = widget.tool;
    final active = tool.isActive;
    final failed = tool.isHardFail;

    final accent = failed
        ? scheme.error
        : active
            ? scheme.primary
            : scheme.outline;
    final task = tool.subagentTask ?? tool.displayTitle;
    final type = tool.subagentTypeLabel;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      child: Material(
        color: scheme.surfaceContainerHigh.withValues(alpha: active ? 0.7 : 0.5),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _loading ? null : _toggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AgentBadge(active: active, failed: failed),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  type == null
                                      ? 'Subagent'
                                      : '$type subagent',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: accent,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _StatusPill(
                                tool: tool,
                                animate: widget.animate,
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Shimmer(
                            enabled: widget.animate && active && !_expanded,
                            child: Text(
                              task,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurface.withValues(alpha: 0.9),
                                fontWeight: FontWeight.w500,
                                height: 1.3,
                              ),
                            ),
                          ),
                          if (!_expanded) ...[
                            Builder(
                              builder: (context) {
                                final peek = _reportPeek(tool);
                                if (peek == null) return const SizedBox.shrink();
                                return Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(
                                    peek,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.outline,
                                      fontSize: 11,
                                      height: 1.3,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
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
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: scheme.outline,
                      ),
                  ],
                ),
                if (_expanded && !_loading) ...[
                  const SizedBox(height: 8),
                  _body(theme),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// First meaningful line of the report, for the collapsed card.
  String? _reportPeek(ToolCallState tool) {
    if (tool.isActive) return null;
    final report = tool.subagentReport;
    if (report == null) return null;
    for (final line in report.split('\n')) {
      final t = line.trim().replaceAll(RegExp(r'^[#>*\-\s]+'), '');
      if (t.length < 3) continue;
      return t.length > 120 ? '${t.substring(0, 119)}…' : t;
    }
    return null;
  }

  Widget _body(ThemeData theme) {
    final scheme = theme.colorScheme;
    final tool = _tool;
    final prompt = tool.subagentPrompt;
    final report = tool.subagentReport;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_loadError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Could not load the full sub-agent run',
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.error),
            ),
          ),
        if (prompt != null) ...[
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _showPrompt = !_showPrompt),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _showPrompt
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 14,
                    color: scheme.outline,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _showPrompt ? 'Hide instructions' : 'Instructions',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_showPrompt)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 220),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    prompt,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 4),
        ],
        if (report != null) ...[
          Row(
            children: [
              Text(
                tool.isHardFail ? 'ERROR' : 'REPORT',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: tool.isHardFail ? scheme.error : scheme.outline,
                  letterSpacing: 0.8,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _copyReport(report),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.copy_rounded,
                    size: 14,
                    color: scheme.outline,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          MessageBody(
            text: report,
            dense: true,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.88),
              height: 1.4,
            ),
          ),
        ] else if (tool.isActive)
          Row(
            children: [
              if (widget.animate) ...[
                WorkingDots(size: 4, color: scheme.primary),
                const SizedBox(width: 8),
              ],
              Text(
                'The sub-agent has not reported back yet',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          )
        else
          Text(
            'No report was returned',
            style:
                theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
          ),
      ],
    );
  }
}

/// Round badge that pulses while the sub-agent is working.
class _AgentBadge extends StatelessWidget {
  const _AgentBadge({required this.active, required this.failed});

  final bool active;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = failed
        ? scheme.error
        : active
            ? scheme.primary
            : scheme.outline;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: active ? 0.18 : 0.10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Icon(
        failed ? Icons.error_outline : Icons.hub_rounded,
        size: 13,
        color: color,
      ),
    );
  }
}

/// `Working…` / `Done` / `Failed` for the header line.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.tool, required this.animate});

  final ToolCallState tool;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final active = tool.isActive;
    final failed = tool.isHardFail;
    final label = active
        ? (tool.status == 'pending' ? 'Queued' : 'Working')
        : failed
            ? 'Failed'
            : tool.statusLabel;
    final color = failed
        ? scheme.error
        : active
            ? scheme.primary
            : scheme.outline;

    final text = Text(
      label,
      style: theme.textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      ),
    );

    if (!active) return text;
    // Tickers stay off while the user reads history (scrolled up).
    if (!animate) return text;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Shimmer(enabled: true, child: text),
        const SizedBox(width: 4),
        WorkingDots(size: 3, color: color),
      ],
    );
  }
}
