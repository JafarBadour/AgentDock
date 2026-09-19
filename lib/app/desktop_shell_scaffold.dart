import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/agents/agents_screen.dart';
import '../features/agents/chat_screen.dart';
import '../features/agents/new_agent_flow.dart';
import '../features/agents/project_files_screen.dart';
import '../features/automations/automations_screen.dart';
import '../features/hosts/hosts_screen.dart';
import '../features/settings/api_keys_screen.dart';
import '../features/settings/mcp_edit_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/terminal/terminal_session_screen.dart';
import '../features/vpn/vpn_screen.dart';
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
  static const _railWidth = 52.0;
  static const _minLeft = 200.0;
  static const _maxLeft = 520.0;
  static const _minRight = 280.0;
  static const _maxRight = 800.0;
  static const _minCenter = 280.0;

  double _leftWidth = 300;
  double _rightWidth = 400;

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
    if (isDesktopPanelRoot(path) && widget.navigationShell.currentIndex != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.navigationShell.goBranch(0, initialLocation: false);
      });
    }
  }

  void _closeRightPanel() {
    ref.read(desktopRightPanelProvider.notifier).state = DesktopRightPanel.none;
    ref.read(desktopProjectFilesProvider.notifier).state = null;
    ref.read(desktopSettingsOverlayProvider.notifier).state = null;
  }

  void _selectPanel(DesktopRightPanel panel) {
    final current = ref.read(desktopRightPanelProvider);
    final next = current == panel ? DesktopRightPanel.none : panel;
    ref.read(desktopRightPanelProvider.notifier).state = next;
    if (next != DesktopRightPanel.files) {
      ref.read(desktopProjectFilesProvider.notifier).state = null;
    }
    if (next != DesktopRightPanel.settings) {
      ref.read(desktopSettingsOverlayProvider.notifier).state = null;
    }
  }

  void _resizeLeft(double dx, double totalWidth, bool rightOpen) {
    final right = rightOpen ? _rightWidth : 0.0;
    final maxLeft = (totalWidth - _railWidth - right - _minCenter).clamp(
      _minLeft,
      _maxLeft,
    );
    setState(() {
      _leftWidth = (_leftWidth + dx).clamp(_minLeft, maxLeft);
    });
  }

  void _resizeRight(double dx, double totalWidth) {
    final maxRight = (totalWidth - _railWidth - _leftWidth - _minCenter).clamp(
      _minRight,
      _maxRight,
    );
    // Handle is the left edge of the right panel: drag left → wider panel.
    setState(() {
      _rightWidth = (_rightWidth - dx).clamp(_minRight, maxRight);
    });
  }

  Widget _centerColumn(String path, String? chatId) {
    // Terminal is opened from the embedded Hosts panel (outside the hosts
    // branch navigator). Render it here directly — relying on navigationShell
    // alone left the center column on Agents/chat and the session never appeared.
    final terminalHostId = terminalHostIdFromPath(path);
    if (terminalHostId != null) {
      final cwd = widget.state.uri.queryParameters['cwd'];
      return TerminalSessionScreen(
        key: ValueKey('terminal-$terminalHostId-${cwd ?? ''}'),
        hostId: terminalHostId,
        initialDirectory: cwd,
      );
    }
    // Host edit, schedule editor, MCP editor, etc.
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
    final totalWidth = MediaQuery.sizeOf(context).width;
    final rightOpen = panel != DesktopRightPanel.none;

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
          _PanelResizeHandle(
            onDrag: (dx) => _resizeLeft(dx, totalWidth, rightOpen),
          ),
          Expanded(child: _centerColumn(path, chatId)),
          if (rightOpen) ...[
            _PanelResizeHandle(onDrag: (dx) => _resizeRight(dx, totalWidth)),
            SizedBox(
              width: _rightWidth,
              child: ColoredBox(
                color: scheme.surfaceContainer.withValues(alpha: 0.72),
                child: _DesktopRightPanel(
                  panel: panel,
                  onClose: _closeRightPanel,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Drag handle between desktop columns.
class _PanelResizeHandle extends StatelessWidget {
  const _PanelResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: SizedBox(
          width: 5,
          child: Center(
            child: Container(
              width: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.8),
            ),
          ),
        ),
      ),
    );
  }
}

class _DesktopSidebarHeader extends ConsumerWidget {
  const _DesktopSidebarHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(agentsSidebarModeProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  switch (mode) {
                    AgentsSidebarMode.agents => 'Agents',
                    AgentsSidebarMode.directories => 'Directories',
                    AgentsSidebarMode.hosts => 'Hosts',
                  },
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
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
                  unawaited(ref.read(catalogSyncProvider.notifier).refresh());
                  ref.invalidate(unreadCountsProvider);
                },
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _AgentsModeSwitcher(),
        ],
      ),
    );
  }
}

class _AgentsModeSwitcher extends ConsumerWidget {
  const _AgentsModeSwitcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(agentsSidebarModeProvider);
    final scheme = Theme.of(context).colorScheme;
    Widget chip(AgentsSidebarMode value, String label, IconData icon) {
      final selected = mode == value;
      return Expanded(
        child: Material(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.18)
              : scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () =>
                ref.read(agentsSidebarModeProvider.notifier).state = value,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Column(
                children: [
                  Icon(
                    icon,
                    size: 15,
                    color: selected
                        ? AppColors.accent
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? AppColors.accent
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip(AgentsSidebarMode.agents, 'Agents', Icons.forum_outlined),
        const SizedBox(width: 6),
        chip(AgentsSidebarMode.directories, 'Directory', Icons.folder_outlined),
        const SizedBox(width: 6),
        chip(AgentsSidebarMode.hosts, 'Hosts', Icons.dns_outlined),
      ],
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
              tooltip: 'VPN',
              icon: Icons.vpn_lock_outlined,
              selected: activePanel == DesktopRightPanel.vpn,
              onTap: () => onSelectPanel(DesktopRightPanel.vpn),
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
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.chatMeta),
          ),
        ],
      ),
    );
  }
}

class _DesktopRightPanel extends ConsumerWidget {
  const _DesktopRightPanel({required this.panel, required this.onClose});

  final DesktopRightPanel panel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filesArgs = ref.watch(desktopProjectFilesProvider);
    final overlay = ref.watch(desktopSettingsOverlayProvider);
    final settingsSub = panel == DesktopRightPanel.settings && overlay != null
        ? _desktopSettingsBody(overlay)
        : null;
    final title = switch (panel) {
      DesktopRightPanel.automate => 'Automate',
      DesktopRightPanel.hosts => 'Hosts',
      DesktopRightPanel.vpn => 'VPN',
      DesktopRightPanel.settings => settingsSub?.title ?? 'Settings',
      DesktopRightPanel.files => filesArgs?.title ?? 'Project files',
      DesktopRightPanel.none => '',
    };

    final body = switch (panel) {
      DesktopRightPanel.automate => const AutomationsScreen(embedded: true),
      DesktopRightPanel.hosts => const HostsScreen(embedded: true),
      DesktopRightPanel.vpn => const VpnScreen(embedded: true),
      DesktopRightPanel.settings =>
        settingsSub?.child ?? const SettingsScreen(embedded: true),
      DesktopRightPanel.files =>
        filesArgs == null
            ? const Center(child: Text('No project selected'))
            : ProjectFilesScreen(
                key: ValueKey('${filesArgs.host.id}:${filesArgs.rootPath}'),
                host: filesArgs.host,
                rootPath: filesArgs.rootPath,
                title: filesArgs.title,
                embedded: true,
              ),
      DesktopRightPanel.none => const SizedBox.shrink(),
    };

    final hideChrome = settingsSub != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!hideChrome)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
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
        if (!hideChrome) const Divider(height: 1),
        if (hideChrome)
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Close panel',
              icon: const Icon(Icons.close),
              onPressed: onClose,
            ),
          ),
        Expanded(child: body),
      ],
    );
  }
}

class _SettingsPanelPage {
  const _SettingsPanelPage({required this.title, required this.child});
  final String title;
  final Widget child;
}

_SettingsPanelPage? _desktopSettingsBody(String path) {
  final segs = Uri.tryParse(path)?.pathSegments ?? const <String>[];
  if (segs.length < 2 || segs[0] != 'settings') return null;
  if (segs[1] == 'mcp') {
    if (segs.length < 3) return null;
    final id = segs[2];
    if (id == 'new') {
      return const _SettingsPanelPage(
        title: 'Add MCP',
        child: McpEditScreen(embedded: true),
      );
    }
    return _SettingsPanelPage(
      title: 'MCP',
      child: McpEditScreen(mcpId: id, embedded: true),
    );
  }
  if (segs[1] == 'keys') {
    if (segs.length == 2) {
      return const _SettingsPanelPage(
        title: 'API keys',
        child: ApiKeysScreen(embedded: true),
      );
    }
    final kind = ApiKeyKind.tryParse(segs[2]);
    if (kind == null) {
      return const _SettingsPanelPage(
        title: 'API keys',
        child: ApiKeysScreen(embedded: true),
      );
    }
    return _SettingsPanelPage(
      title: kind.title,
      child: ApiKeyEditScreen(kind: kind, embedded: true),
    );
  }
  return null;
}
