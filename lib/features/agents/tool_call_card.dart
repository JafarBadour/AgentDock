import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/tool_call_state.dart';

/// Expandable card for an agent tool / shell command.
class ToolCallCard extends StatefulWidget {
  const ToolCallCard({super.key, required this.tool});

  final ToolCallState tool;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  late bool _expanded = widget.tool.isActive;

  @override
  void didUpdateWidget(covariant ToolCallCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tool.isActive != widget.tool.isActive) {
      _expanded = widget.tool.isActive;
    }
  }

  IconData get _kindIcon {
    final k = (widget.tool.kind ?? '').toLowerCase();
    if (k.contains('exec') || k.contains('shell') || k.contains('terminal')) {
      return Icons.terminal;
    }
    if (k.contains('read')) return Icons.description_outlined;
    if (k.contains('edit') || k.contains('write')) return Icons.edit_outlined;
    if (k.contains('search') || k.contains('grep')) return Icons.search;
    if (k.contains('fetch') || k.contains('http')) return Icons.cloud_download_outlined;
    if (k.contains('delete')) return Icons.delete_outline;
    return Icons.build_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tool = widget.tool;
    final scheme = theme.colorScheme;

    final Color statusColor;
    final IconData statusIcon;
    final bool spinning;
    if (tool.isActive) {
      statusColor = scheme.primary;
      statusIcon = Icons.sync;
      spinning = true;
    } else if (tool.isFailed) {
      statusColor = scheme.error;
      statusIcon = Icons.error_outline;
      spinning = false;
    } else if (tool.isCompleted) {
      statusColor = scheme.tertiary;
      statusIcon = Icons.check_circle_outline;
      spinning = false;
    } else {
      statusColor = scheme.onSurfaceVariant;
      statusIcon = Icons.schedule;
      spinning = false;
    }

    final hasDetails = (tool.rawInput?.isNotEmpty ?? false) ||
        (tool.rawOutput?.isNotEmpty ?? false) ||
        tool.locations.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: hasDetails ? () => setState(() => _expanded = !_expanded) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_kindIcon, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tool.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (spinning)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: statusColor,
                        ),
                      )
                    else
                      Icon(statusIcon, size: 16, color: statusColor),
                    const SizedBox(width: 6),
                    Text(
                      tool.statusLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (hasDetails) ...[
                      const SizedBox(width: 4),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
                if (!_expanded && tool.preview != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    tool.preview!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (_expanded && hasDetails) ...[
                  if (tool.locations.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text('Paths', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 4),
                    ...tool.locations.map(
                      (p) => Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          p,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (tool.rawInput != null && tool.rawInput!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text('Input', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 4),
                    _CodeBlock(text: tool.rawInput!),
                  ],
                  if (tool.rawOutput != null && tool.rawOutput!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text('Output', style: theme.textTheme.labelMedium),
                    const SizedBox(height: 4),
                    _CodeBlock(text: tool.rawOutput!),
                  ],
                ],
              ],
            ),
          ),
        ),
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
            height: 1.35,
          ),
          linkStyle: TextStyle(
            color: theme.colorScheme.primary,
            decoration: TextDecoration.underline,
            fontFamily: 'monospace',
            height: 1.35,
          ),
        ),
      ),
    );
  }
}
