import 'package:flutter/material.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/tool_call_state.dart';
import 'agent_status_indicators.dart';

/// One line of agent activity, expandable into the raw input/output.
///
/// Deliberately understated: during a turn there may be a dozen of these
/// between two sentences, so they read as a quiet log next to the agent's
/// actual words rather than a stack of cards competing with them.
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
    if (k.contains('exec') || k.contains('shell') || k.contains('terminal')) {
      return Icons.terminal_rounded;
    }
    if (k.contains('read')) return Icons.description_outlined;
    if (k.contains('edit') || k.contains('write')) return Icons.edit_outlined;
    if (k.contains('search') || k.contains('grep')) return Icons.search_rounded;
    if (k.contains('fetch') || k.contains('http')) return Icons.language_rounded;
    if (k.contains('delete')) return Icons.delete_outline;
    return Icons.auto_awesome_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tool = widget.tool;

    final active = tool.isActive;
    final failed = tool.isFailed;

    final labelColor = failed
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
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: hasDetails ? () => setState(() => _expanded = !_expanded) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      failed ? Icons.error_outline : _kindIcon,
                      size: 14,
                      color: failed
                          ? scheme.error
                          : active
                              ? scheme.primary
                              : scheme.outline,
                    ),
                    const SizedBox(width: 8),
                    // Title and detail are one line so they share the width
                    // naturally and ellipsize as a unit, instead of each being
                    // capped at its own slice of the row.
                    Expanded(
                      child: Shimmer(
                        enabled: active,
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
                    if (failed) ...[
                      Text(
                        tool.statusLabel,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.error),
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
                              child: Text(
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
