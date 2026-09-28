import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import 'agent_status_indicators.dart';

/// "Thinking… / Exploring… / Ran a command…" pinned over the bottom of the
/// transcript while the agent works.
///
/// This used to be painted with `colorScheme.errorContainer`, so a perfectly
/// healthy agent announced its work in alarm red. Working is the ordinary
/// state here, so it now wears the app's violet agent accent, and says it is
/// live with the same pulsing dots the agents list uses.
///
/// It floats over scrolling content, so the fill stays opaque — a translucent
/// bar let the transcript slide through the label and made it unreadable.
class AgentActivityStrip extends StatelessWidget {
  const AgentActivityStrip({
    super.key,
    required this.label,
    this.animate = true,
  });

  /// Pre-built label — callers vary it (plain text, explore counters, …).
  final Widget label;

  /// Off in tests: the dots pulse forever, and `pumpAndSettle` never returns
  /// while a repeating ticker is alive.
  final bool animate;

  /// Matches the old strip so turning it on and off cannot shift the layout.
  static const height = 32.0;

  @override
  Widget build(BuildContext context) {
    final fill = Color.alphaBlend(
      AppColors.accent.withValues(alpha: 0.12),
      AppColors.surface,
    );
    return Material(
      color: fill,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: AppColors.accent.withValues(alpha: 0.28),
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            if (animate)
              const WorkingDots(size: 4, color: AppColors.accent)
            else
              const _StaticDots(),
            const SizedBox(width: 9),
            Expanded(child: label),
          ],
        ),
      ),
    );
  }
}

/// The dots at rest, so a test can render the strip without a live ticker.
class _StaticDots extends StatelessWidget {
  const _StaticDots();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        3,
        (i) => Padding(
          padding: EdgeInsets.only(left: i == 0 ? 0 : 3),
          child: Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
