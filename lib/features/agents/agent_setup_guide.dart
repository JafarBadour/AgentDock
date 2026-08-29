import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/remote_setup_guide.dart';

export '../../services/remote_setup_guide.dart';

/// Banner with selectable / copyable remote setup instructions.
class AgentSetupErrorBanner extends StatelessWidget {
  const AgentSetupErrorBanner({
    super.key,
    required this.message,
    required this.setupGuide,
    this.onDismiss,
  });

  final String message;
  final String setupGuide;
  final VoidCallback? onDismiss;

  /// Pick the right guide from a failure message / exception text.
  factory AgentSetupErrorBanner.fromFailure({
    Key? key,
    required String message,
    VoidCallback? onDismiss,
  }) {
    final lower = message.toLowerCase();
    final guide = lower.contains('tmux')
        ? kRemoteTmuxSetupGuide
        : lower.contains('claude')
            ? kRemoteClaudeSetupGuide
            : kRemoteCursorSetupGuide;
    return AgentSetupErrorBanner(
      key: key,
      message: message,
      setupGuide: guide,
      onDismiss: onDismiss,
    );
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: setupGuide));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Setup commands copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onError = theme.colorScheme.onErrorContainer;

    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SelectableText(
                    message,
                    style: theme.textTheme.bodyMedium?.copyWith(color: onError),
                  ),
                ),
                if (onDismiss != null)
                  IconButton(
                    tooltip: 'Dismiss',
                    onPressed: onDismiss,
                    icon: Icon(Icons.close, color: onError),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Run this on the remote host (Terminal tab):',
              style: theme.textTheme.labelLarge?.copyWith(color: onError),
            ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 48, 12),
                    child: SelectableText(
                      setupGuide.trimRight(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Color(0xFFE8E8E8),
                        height: 1.35,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton(
                      tooltip: 'Copy setup commands',
                      onPressed: () => _copy(context),
                      icon: const Icon(Icons.copy, size: 18, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy),
                label: const Text('Copy setup commands'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
