import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/agents/agents_screen.dart';
import '../features/agents/chat_screen.dart';
import '../features/agents/new_agent_flow.dart';
import '../features/automations/automations_screen.dart';
import '../features/connect/connect_screen.dart';
import '../features/hosts/hosts_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/terminal/terminal_session_screen.dart';
import 'app_theme.dart';
import 'platform_layout.dart';
import 'providers.dart';

/// Cursor-style macOS layout: agent list | chat / detail | secondary panels.
class DesktopShellScaffold extends ConsumerStatefulWidget {
  const DesktopShellScaffold({
    super.key,
    required this.navigationShell,
    required this.state,
  });

  final StatefulNavigationShell navigationShell;
  final GoRouterState state;

  @override
  ConsumerState<DesktopShellScaffold> createState() =>
      _DesktopShellScaffoldState();
}

class _DesktopShellScaffoldState extends ConsumerState<DesktopShellScaffold> {
  static const _leftWidth = 300.0;
  static const _rightWidth = 400.0;
  static const _railWidth = 52.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncFromRoute(widget.state.uri.path);
    });
  }

  @override
  void didUpdateWidget(covariant DesktopShellScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state.uri.path != widget.state.uri.path) {
      _syncFromRoute(widget.state.uri.path);
    }
  }

  void _syncFromRoute(String path) {
    final panel = desktopPanelForPath(path);
    if (panel != null) {
      final current = ref.read(desktopRightPanelProvider);
      if (current != panel) {
        ref.read(desktopRightPanelProvider.notifier).state = panel;
      }
    }

    // Panel list roots (/hosts, /settings, …) should not steal the center
    // column — bounce back to Agents while keeping the right panel open.
    // Never do this for detail routes (/hosts/new, /automate/edit/…): those
    // must stay on their branch so navigationShell can render them.
    if (isDesktopPanelRoot(path) &&
        widget.navigationShell.currentIndex != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.navigationShell.goBranch(0, initialLocation: false);
      });
    }
  }

  void _selectPanel(DesktopRightPanel panel) {
    final current = ref.read(desktopRightPanelProvider);
    ref.read(desktopRightPanelProvider.notifier).state =
        current == panel ? DesktopRightPanel.none : panel;
  }

  Widget _centerColumn(String path, String? chatId) {
    // Terminal is opened from the embedded Hosts panel (outside the hosts
    // branch navigator). Render it here directly — relying on navigationShell
    // alone left the center column on Agents/chat and the session never appeared.
    final terminalHostId = terminalHostIdFromPath(path);
    if (terminalHostId != null) {
      return TerminalSessionScreen(
        key: ValueKey('terminal-$terminalHostId'),
        hostId: terminalHostId,
      );
    }
    // Host edit, schedule editor, repos, MCP editor, etc.
    if (isDesktopDetailRoute(path)) {
      return widget.navigationShell;
    }
    if (chatId == null) {
      return const _DesktopChatPlaceholder();
    }
    return ChatScreen(key: ValueKey(chatId), chatId: chatId);
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.state.uri.path;
    final chatId = chatIdFromRoute(widget.state);
    final panel = ref.watch(desktopRightPanelProvider);
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          SizedBox(
            width: _leftWidth,
            child: Row(
              children: [
                _DesktopNavRail(
                  width: _railWidth,
                  activePanel: panel,
                  onSelectPanel: _selectPanel,
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: ColoredBox(
                    color: scheme.surfaceContainer.withValues(alpha: 0.55),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _DesktopSidebarHeader(),
                        const Divider(height: 1),
                        Expanded(
                          child: ClipRect(
                            child: AgentsScreen(
                              embedded: true,
                              selectedChatId: chatId,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: _centerColumn(path, chatId)),
          if (panel != DesktopRightPanel.none) ...[
            const VerticalDivider(width: 1),
            SizedBox(
              width: _rightWidth,
              child: ColoredBox(
                color: scheme.surfaceContainer.withValues(alpha: 0.72),
                child: _DesktopRightPanel(
                  panel: panel,
                  onClose: () => ref
                      .read(desktopRightPanelProvider.notifier)
                      .state = DesktopRightPanel.none,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DesktopSidebarHeader extends ConsumerWidget {
  const _DesktopSidebarHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Agents',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          IconButton(
            tooltip: 'New agent',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              unawaited(startNewAgentWizard(context: context, ref: ref));
            },
            icon: const Icon(Icons.add, size: 18),
          ),
          IconButton(
            tooltip: 'Refresh / sync',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              ref.invalidate(agentsTreeProvider);
              ref.invalidate(agentsSyncProvider);
              ref.invalidate(unreadCountsProvider);
            },
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ],
      ),
    );
  }
}

class _DesktopNavRail extends StatelessWidget {
  const _DesktopNavRail({
    required this.width,
    required this.activePanel,
    required this.onSelectPanel,
  });

  final double width;
  final DesktopRightPanel activePanel;
  final ValueChanged<DesktopRightPanel> onSelectPanel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: width,
      child: ColoredBox(
        color: scheme.surfaceContainerLowest,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Tooltip(
              message: 'Agents',
              child: IconButton(
                icon: const Icon(Icons.forum_outlined),
                onPressed: () => onSelectPanel(DesktopRightPanel.none),
              ),
            ),
            const Spacer(),
            _RailIcon(
              tooltip: 'Automate',
              icon: Icons.schedule_outlined,
              selected: activePanel == DesktopRightPanel.automate,
              onTap: () => onSelectPanel(DesktopRightPanel.automate),
            ),
            _RailIcon(
              tooltip: 'Hosts',
              icon: Icons.dns_outlined,
              selected: activePanel == DesktopRightPanel.hosts,
              onTap: () => onSelectPanel(DesktopRightPanel.hosts),
            ),
            _RailIcon(
              tooltip: 'Connect',
              icon: Icons.vpn_key_outlined,
              selected: activePanel == DesktopRightPanel.connect,
              onTap: () => onSelectPanel(DesktopRightPanel.connect),
            ),
            _RailIcon(
              tooltip: 'Settings',
              icon: Icons.settings_outlined,
              selected: activePanel == DesktopRightPanel.settings,
              onTap: () => onSelectPanel(DesktopRightPanel.settings),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _RailIcon extends StatelessWidget {
  const _RailIcon({
    required this.tooltip,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: tooltip,
        child: IconButton(
          style: IconButton.styleFrom(
            backgroundColor: selected
                ? AppColors.accent.withValues(alpha: 0.18)
                : null,
            foregroundColor: selected
                ? AppColors.accent
                : AppColors.mist.withValues(alpha: 0.7),
          ),
          icon: Icon(icon),
          onPressed: onTap,
        ),
      ),
    );
  }
}

class _DesktopChatPlaceholder extends StatelessWidget {
  const _DesktopChatPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 48,
            color: AppColors.mist.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 16),
          Text(
            'Select an agent',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.mist.withValues(alpha: 0.75),
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Pick a chat from the left, or create a new agent.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.chatMeta,
                ),
          ),
        ],
      ),
    );
  }
}

class _DesktopRightPanel extends StatelessWidget {
  const _DesktopRightPanel({
    required this.panel,
    required this.onClose,
  });

  final DesktopRightPanel panel;
  final VoidCallback onClose;

  String get _title => switch (panel) {
        DesktopRightPanel.automate => 'Automate',
        DesktopRightPanel.hosts => 'Hosts',
        DesktopRightPanel.connect => 'Connect',
        DesktopRightPanel.settings => 'Settings',
        DesktopRightPanel.none => '',
      };

  Widget get _body => switch (panel) {
        DesktopRightPanel.automate =>
          const AutomationsScreen(embedded: true),
        DesktopRightPanel.hosts => const HostsScreen(embedded: true),
        DesktopRightPanel.connect => const ConnectScreen(embedded: true),
        DesktopRightPanel.settings => const SettingsScreen(embedded: true),
        DesktopRightPanel.none => const SizedBox.shrink(),
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Close panel',
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _body),
      ],
    );
  }
}
