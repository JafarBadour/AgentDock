import 'package:flutter/material.dart';

/// Model + context reading under the composer, tappable to change the model.
///
/// Strictly one line. Model names come from the agent's own catalog and run
/// long — Cursor ships `Default (recommended)` — so this used to sit in a
/// narrow two-line box beside the attach button, where it broke names mid-word
/// (`Default (rec` / `ommended)`) and clipped the second line. Now the name is
/// the only thing that gives up space, and it does so with an ellipsis.
class ComposerModelFooter extends StatelessWidget {
  const ComposerModelFooter({
    super.key,
    required this.label,
    this.usage,
    this.onTap,
  });

  /// Model summary, e.g. `Sonnet 5 · thinking`.
  final String label;

  /// Context reading, e.g. `42k/200k (21%)`. Hidden when the agent has not
  /// reported one yet.
  final String? usage;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final accent = theme.colorScheme.primary.withValues(alpha: 0.9);
    final style = theme.textTheme.labelSmall?.copyWith(height: 1.1);

    return Align(
      alignment: Alignment.centerLeft,
      // Hug the single line: a bare Align fills whatever height it is offered,
      // which would pad the composer out wherever the parent bounds it.
      heightFactor: 1,
      child: Tooltip(
        message: usage == null
            ? 'Model: $label — tap to change'
            : 'Model: $label\nContext: $usage\nTap to change',
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome, size: 12, color: accent),
                const SizedBox(width: 5),
                // Flexible, so a long name shortens instead of overflowing —
                // and the context reading beside it always stays whole.
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: style?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (usage != null) ...[
                  Text('  ·  ', style: style?.copyWith(color: muted)),
                  Text(
                    usage!,
                    maxLines: 1,
                    softWrap: false,
                    style: style?.copyWith(color: muted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
