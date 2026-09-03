import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Three dots that rise and fade in sequence while the agent is producing a
/// turn. Deliberately small enough to sit in a list row's leading slot.
class WorkingDots extends StatefulWidget {
  const WorkingDots({super.key, this.size = 5, this.color});

  final double size;
  final Color? color;

  @override
  State<WorkingDots> createState() => _WorkingDotsState();
}

class _WorkingDotsState extends State<WorkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) SizedBox(width: widget.size * 0.6),
              _dot(color, i),
            ],
          ],
        );
      },
    );
  }

  Widget _dot(Color color, int index) {
    // Stagger each dot a third of a cycle apart.
    final phase = (_controller.value + index / 3) % 1.0;
    final wave = math.sin(phase * 2 * math.pi);
    final lift = wave.clamp(0.0, 1.0) * widget.size * 0.7;
    final opacity = 0.45 + 0.55 * ((wave + 1) / 2);

    return Transform.translate(
      offset: Offset(0, -lift),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: opacity),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// Sweeps a soft highlight across [child] while [enabled].
///
/// Used for work that is in progress but has no measurable percentage — it
/// reads as "alive" without putting a spinner on every row. The highlight is
/// composited over the child rather than replacing it, so multi-coloured
/// content keeps its own colours.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Always create in initState — a lazy late field would be first touched
    // from dispose() when enabled was never true, and creating a ticker while
    // unmounting looks up a deactivated ancestor.
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    if (widget.enabled) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant Shimmer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.enabled && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // An endless moving highlight is precisely what "reduce motion" is for.
    if (!widget.enabled || MediaQuery.disableAnimationsOf(context)) {
      return widget.child;
    }

    // Lighten on dark, darken on light: either way the band reads as a pulse
    // travelling along the text.
    final sweep = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              sweep.withValues(alpha: 0),
              sweep.withValues(alpha: 0.55),
              sweep.withValues(alpha: 0),
            ],
            stops: const [0.2, 0.5, 0.8],
            transform: _SlidingGradient(_controller.value),
          ).createShader(bounds),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Slides the gradient during paint, so the sweep never triggers layout.
class _SlidingGradient extends GradientTransform {
  const _SlidingGradient(this.progress);

  final double progress;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    // -1 → 2 so the highlight enters from off-screen left and fully exits right.
    return Matrix4.translationValues(bounds.width * (progress * 3 - 1), 0, 0);
  }
}

/// Telegram-style pill showing how many agent replies you have not read.
class UnreadBadge extends StatelessWidget {
  const UnreadBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: unreadAccent(context),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}

/// The unread blue. Kept distinct from the app's green seed colour so it reads
/// as "new activity" rather than as a themed accent.
Color unreadAccent(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? const Color(0xFF4DA3FF) : const Color(0xFF1E88E5);
}

/// Compact relative timestamp, e.g. `now`, `7m`, `4d`.
String shortTimeAgo(DateTime time, {DateTime? now}) {
  final delta = (now ?? DateTime.now()).difference(time);
  if (delta.isNegative || delta.inSeconds < 45) return 'now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m';
  if (delta.inHours < 24) return '${delta.inHours}h';
  if (delta.inDays < 7) return '${delta.inDays}d';
  if (delta.inDays < 365) return '${(delta.inDays / 7).floor()}w';
  return '${(delta.inDays / 365).floor()}y';
}

/// Green `+X` / red `-Y` / `N φ` files — agent code churn.
class CodeDeltaLabel extends StatelessWidget {
  const CodeDeltaLabel({
    super.key,
    required this.added,
    required this.removed,
    required this.files,
    this.compact = false,
  });

  final int added;
  final int removed;
  final int files;
  final bool compact;

  bool get isEmpty => added == 0 && removed == 0 && files == 0;

  @override
  Widget build(BuildContext context) {
    if (isEmpty) return const SizedBox.shrink();
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          fontWeight: FontWeight.w600,
          height: 1.1,
        );
    const green = Color(0xFF2E7D32);
    const red = Color(0xFFC62828);
    return Text.rich(
      TextSpan(
        style: style?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        children: [
          if (!compact) const TextSpan(text: 'Delta '),
          TextSpan(
            text: '+$added',
            style: style?.copyWith(color: green),
          ),
          const TextSpan(text: ' '),
          TextSpan(
            text: '-$removed',
            style: style?.copyWith(color: red),
          ),
          if (files > 0) ...[
            TextSpan(
              text: compact ? ' · ' : ' | ',
              style: style?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
            TextSpan(
              text: '$files φ',
              style: style?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Live `Exploring 8 φ, 7 🔍` while the agent reads/searches.
class ExploreStatsLabel extends StatelessWidget {
  const ExploreStatsLabel({
    super.key,
    required this.files,
    required this.searches,
    this.style,
    this.showEllipsis = false,
  });

  final int files;
  final int searches;
  final TextStyle? style;
  final bool showEllipsis;

  bool get isEmpty => files == 0 && searches == 0;

  @override
  Widget build(BuildContext context) {
    if (isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final resolved = style ??
        theme.textTheme.labelSmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          fontWeight: FontWeight.w600,
          height: 1.1,
          color: theme.colorScheme.primary,
        );
    final iconSize = (resolved?.fontSize ?? 12) + 2;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Exploring ', style: resolved),
        if (files > 0) Text('$files φ', style: resolved),
        if (files > 0 && searches > 0) Text(', ', style: resolved),
        if (searches > 0) ...[
          Text('$searches', style: resolved),
          const SizedBox(width: 2),
          Icon(Icons.search, size: iconSize, color: resolved?.color),
        ],
        if (showEllipsis) Text('…', style: resolved),
      ],
    );
  }
}

/// Shows which automated schedule (`#N`) last ran into an agent chat.
class AutoNumberBadge extends StatelessWidget {
  const AutoNumberBadge({super.key, required this.number, this.compact = true});

  final int number;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = compact ? '#$number' : 'Auto #$number';
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : 8,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.schedule,
            size: compact ? 11 : 13,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              fontSize: compact ? 10 : 11,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}
