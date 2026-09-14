import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_theme.dart';
import '../../app/providers.dart';
import '../../data/models/agent_provider.dart';
import '../../data/secure/safe_log.dart';
import '../../features/connect/claude_login_sheet.dart';
import '../../services/adsm_client.dart';
import '../../services/ssh_service.dart';

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
    return TurnMetricsLabel(
      added: added,
      removed: removed,
      files: files,
      compact: compact,
    );
  }
}

/// Per-command footer: `+X -Y · Z φ · N τ` (omits all-zero code; τ after finish).
class TurnMetricsLabel extends StatelessWidget {
  const TurnMetricsLabel({
    super.key,
    this.added = 0,
    this.removed = 0,
    this.files = 0,
    this.tokensUsed,
    this.contextSize,
    this.compact = true,
  });

  final int added;
  final int removed;
  final int files;
  final int? tokensUsed;
  final int? contextSize;
  final bool compact;

  bool get hasCode => added > 0 || removed > 0 || files > 0;
  bool get hasTokens => tokensUsed != null;
  bool get isEmpty => !hasCode && !hasTokens;

  @override
  Widget build(BuildContext context) {
    if (isEmpty) return const SizedBox.shrink();
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
          fontWeight: FontWeight.w600,
          height: 1.1,
        );
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final outline = Theme.of(context).colorScheme.outline;
    const green = AppColors.diffAdd;
    const red = AppColors.diffRemove;
    final sep = TextSpan(
      text: ' · ',
      style: style?.copyWith(color: outline),
    );
    final children = <InlineSpan>[];
    if (hasCode) {
      if (!compact) {
        children.add(TextSpan(text: 'Δ ', style: style?.copyWith(color: muted)));
      }
      children.add(
        TextSpan(text: '+$added', style: style?.copyWith(color: green)),
      );
      children.add(const TextSpan(text: ' '));
      children.add(
        TextSpan(text: '-$removed', style: style?.copyWith(color: red)),
      );
      if (files > 0) {
        children.add(sep);
        children.add(
          TextSpan(text: '$files φ', style: style?.copyWith(color: muted)),
        );
      }
    }
    if (hasTokens) {
      if (children.isNotEmpty) children.add(sep);
      final tokenText = formatContextUsage(tokensUsed, contextSize) ?? '';
      children.add(
        TextSpan(text: '$tokenText τ', style: style?.copyWith(color: muted)),
      );
    }
    return Tooltip(
      message: hasTokens
          ? 'Context window from the agent (ACP usage_update).\n'
              '+/−/φ is code churn this turn.'
          : 'Code churn this turn (+ added, − removed, φ files).',
      waitDuration: const Duration(milliseconds: 400),
      child: Text.rich(
        TextSpan(style: style?.copyWith(color: muted), children: children),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  static String _compactInt(int n) {
    final sign = n < 0 ? '-' : '';
    final a = n.abs();
    if (a < 1000) return '$n';
    if (a < 1000000) {
      final k = a / 1000;
      final s =
          k >= 100 ? k.round().toString() : k.toStringAsFixed(k >= 10 ? 0 : 1);
      final trimmed = s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
      return '$sign${trimmed}k';
    }
    final m = a / 1000000;
    final s = m >= 10 ? m.round().toString() : m.toStringAsFixed(1);
    final trimmed = s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
    return '$sign${trimmed}M';
  }

  /// Live / persisted context window: `37k/1M (4%)`.
  static String? formatContextUsage(int? used, int? size) {
    if (used == null) return null;
    if (size == null || size <= 0) return '${_compactInt(used)} τ';
    final pct = ((used / size) * 100).clamp(0, 100);
    final pctLabel =
        pct >= 10 ? pct.toStringAsFixed(0) : pct.toStringAsFixed(1);
    return '${_compactInt(used)}/${_compactInt(size)} ($pctLabel%)';
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
          color: AppColors.accent.withValues(alpha: 0.92),
        );
    final iconSize = (resolved?.fontSize ?? 12) + 2;
    return LayoutBuilder(
      builder: (context, constraints) {
        final row = Row(
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
        if (!constraints.hasBoundedWidth ||
            constraints.maxWidth == double.infinity) {
          return row;
        }
        return FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: row,
          ),
        );
      },
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

/// Bottom sheet: ADSM version + daemon health for the current host.
class AdsmHealthSheet extends ConsumerStatefulWidget {
  const AdsmHealthSheet({
    super.key,
    required this.session,
    required this.bridgeOpen,
    this.provider,
    this.onReconnect,
    this.onReauthed,
    this.onStopped,
  });

  final AdsmSession session;
  final bool bridgeOpen;
  final AgentProvider? provider;
  final VoidCallback? onReconnect;
  final VoidCallback? onReauthed;

  /// Called after ADSM was stopped and the sheet closes.
  final VoidCallback? onStopped;

  static Future<void> show(
    BuildContext context, {
    required AdsmSession session,
    required bool bridgeOpen,
    AgentProvider? provider,
    VoidCallback? onReconnect,
    VoidCallback? onReauthed,
    VoidCallback? onStopped,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => AdsmHealthSheet(
        session: session,
        bridgeOpen: bridgeOpen,
        provider: provider,
        onReconnect: onReconnect,
        onReauthed: onReauthed,
        onStopped: onStopped,
      ),
    );
  }

  @override
  ConsumerState<AdsmHealthSheet> createState() => _AdsmHealthSheetState();
}

class _AdsmHealthSheetState extends ConsumerState<AdsmHealthSheet> {
  AdsmHostHealth? _health;
  HostSystemMetrics? _metrics;
  bool _loading = true;
  bool _reauthing = false;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final ssh = ref.read(sshServiceProvider);
    final host = widget.session.host;

    final healthFuture = widget.session.fetchHostHealth(
      bridgeOpen: widget.bridgeOpen,
    );
    final metricsFuture = ssh.fetchHostSystemMetrics(
      host,
      timeout: const Duration(seconds: 1),
    );

    AdsmHostHealth? health;
    Object? healthError;
    try {
      health = await healthFuture;
    } catch (e) {
      healthError = e;
    }
    HostSystemMetrics? metrics;
    try {
      metrics = await metricsFuture;
    } catch (e) {
      metrics = HostSystemMetrics(error: '$e');
    }

    if (!mounted) return;
    setState(() {
      _metrics = metrics;
      if (health != null) {
        _health = health;
      } else {
        _health = AdsmHostHealth(
          hostLabel: host.displayLabel,
          bridgeOpen: widget.bridgeOpen,
          pingVersion: widget.session.protocolVersion,
          requiredVersion: kRequiredAdsmVersion,
          agentStatus: widget.session.daemonStatus,
          fetchError: '$healthError',
        );
      }
      _loading = false;
    });
  }

  bool get _authErrorVisible {
    final err = _health?.agentLastError;
    return err != null && isAgentAuthFailureText(err);
  }

  Future<void> _reauth() async {
    if (_reauthing) return;
    final provider = widget.provider ?? AgentProvider.claude;
    final host = widget.session.host;

    if (provider == AgentProvider.claude) {
      setState(() => _reauthing = true);
      try {
        final ok = await ClaudeLoginSheet.show(context, host: host);
        if (!mounted) return;
        if (ok == true) {
          Navigator.pop(context);
          widget.onReauthed?.call();
        }
      } finally {
        if (mounted) setState(() => _reauthing = false);
      }
      return;
    }

    final goConnect = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Re-authenticate Cursor'),
        content: const Text(
          'Cursor ACP uses `agent login` on the host (or a Cursor API key in '
          'Settings).\n\nOpen Settings to save a key, or run `agent login` from '
          'Hosts → Terminal on this machine.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (goConnect == true) {
      Navigator.pop(context);
      context.go('/settings');
    }
  }

  Future<void> _stopAdsm() async {
    if (_stopping) return;
    final host = widget.session.host;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Turn off ADSM?'),
        content: Text(
          'Stops the ADSM daemon on ${host.displayLabel}. '
          'Open chats disconnect until you reconnect '
          '(ADSM starts again automatically then).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _stopping = true);
    try {
      final ssh = ref.read(sshServiceProvider);
      final pool = ref.read(adsmBridgePoolProvider);
      await ssh.stopAdsm(host);
      try {
        await pool.drop(host.id);
      } catch (e) {
        SafeLog.d('ADSM bridge drop after stop failed', e);
      }
      try {
        await widget.session.close();
      } catch (e) {
        SafeLog.d('ADSM session close after stop failed', e);
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      widget.onStopped?.call();
      messenger.showSnackBar(
        SnackBar(content: Text('ADSM stopped on ${host.displayLabel}')),
      );
    } catch (e) {
      SafeLog.d('stop ADSM failed', e);
      if (mounted) {
        setState(() => _stopping = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not stop ADSM: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = _health;
    final healthy = h?.healthy ?? false;
    final provider = widget.provider;
    final busy = _loading || _reauthing || _stopping;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          12,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  healthy ? Icons.sensors : Icons.sensors_off,
                  color: healthy
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Host · ${widget.session.host.displayLabel}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: provider == AgentProvider.cursor
                      ? 'Re-authenticate Cursor'
                      : 'Re-authenticate Claude',
                  onPressed: busy ? null : _reauth,
                  icon: _reauthing
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        )
                      : Icon(
                          Icons.lock_reset_outlined,
                          color: _authErrorVisible
                              ? theme.colorScheme.error
                              : null,
                        ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: busy ? null : _refresh,
                  icon: _loading
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (h != null) ...[
              _HealthRow(
                label: 'Bridge',
                value: h.bridgeOpen ? 'Connected' : 'Disconnected',
                ok: h.bridgeOpen,
              ),
              _HealthRow(
                label: 'ADSM version',
                value: h.pingVersion ?? 'unknown',
                detail: 'app needs ${h.requiredVersion}',
                ok: h.versionMeets,
              ),
              _HealthRow(
                label: 'Daemon',
                value: h.daemonPid != null
                    ? 'pid ${h.daemonPid}'
                    : (h.fetchError != null ? 'unreachable' : '…'),
                detail: h.workerCount != null
                    ? '${h.workerCount} worker${h.workerCount == 1 ? '' : 's'}'
                    : null,
                ok: h.daemonReachable,
              ),
              if (h.eventSeq != null)
                _HealthRow(
                  label: 'Event seq',
                  value: '${h.eventSeq}',
                  ok: true,
                ),
              _HealthRow(
                label: 'This agent',
                value: h.agentStatus ?? 'unknown',
                ok: h.agentHealthy,
              ),
              if (h.acpSessionId != null && h.acpSessionId!.isNotEmpty)
                _HealthRow(
                  label: 'ACP session',
                  value: h.acpSessionId!,
                  ok: true,
                  monospace: true,
                ),
              if (h.agentLastError != null && h.agentLastError!.isNotEmpty)
                _HealthRow(
                  label: 'Last error',
                  value: h.agentLastError!,
                  ok: false,
                ),
              if (h.fetchError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    h.fetchError!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
            if (_metrics != null) ...[
              const SizedBox(height: 4),
              _HealthRow(
                label: 'CPU',
                value: _metrics!.cpuPercent != null
                    ? _metrics!.cpuLabel
                    : (_metrics!.error ?? '—'),
                ok: _metrics!.cpuPercent != null,
              ),
              _HealthRow(
                label: 'Memory',
                value: _metrics!.memTotalBytes != null
                    ? _metrics!.memoryLabel
                    : (_metrics!.error ?? '—'),
                ok: _metrics!.memTotalBytes != null,
              ),
              _HealthRow(
                label: 'Disk free',
                value: _metrics!.diskFreeBytes != null
                    ? _metrics!.diskFreeLabel
                    : (_metrics!.error ?? '—'),
                ok: _metrics!.diskFreeBytes != null,
              ),
            ],
            if (_authErrorVisible) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: busy ? null : _reauth,
                icon: const Icon(Icons.lock_reset_outlined),
                label: Text(
                  provider == AgentProvider.cursor
                      ? 'Re-authenticate Cursor'
                      : 'Re-authenticate Claude',
                ),
              ),
            ],
            if (!widget.bridgeOpen && widget.onReconnect != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () {
                        Navigator.pop(context);
                        widget.onReconnect!();
                      },
                icon: const Icon(Icons.link),
                label: const Text('Reconnect'),
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: busy ? null : _stopAdsm,
              icon: _stopping
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.error,
                      ),
                    )
                  : Icon(
                      Icons.power_settings_new,
                      color: theme.colorScheme.error,
                    ),
              label: Text(
                _stopping ? 'Turning off…' : 'Turn off ADSM',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                side: BorderSide(color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({
    required this.label,
    required this.value,
    this.detail,
    required this.ok,
    this.monospace = false,
  });

  final String label;
  final String value;
  final String? detail;
  final bool ok;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 18,
            color: ok
                ? theme.colorScheme.primary
                : theme.colorScheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                SelectableText(
                  value,
                  style: (monospace
                          ? theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            )
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(fontWeight: FontWeight.w500),
                ),
                if (detail != null)
                  Text(
                    detail!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
