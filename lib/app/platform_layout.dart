import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';

/// True on desktop builds — always use the Cursor-style three-column shell.
///
/// Do not gate on window width: the macOS default frame is 800px, which used
/// to fall below an 840px threshold and leave users stuck on the phone bottom
/// nav forever.
bool useDesktopShell([BuildContext? context]) {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

DesktopRightPanel? desktopPanelForPath(String path) {
  if (path.startsWith('/automate')) return DesktopRightPanel.automate;
  if (path.startsWith('/hosts')) return DesktopRightPanel.hosts;
  if (path.startsWith('/vpn')) return DesktopRightPanel.vpn;
  if (path.startsWith('/settings')) return DesktopRightPanel.settings;
  if (path.startsWith('/connect')) return DesktopRightPanel.settings;
  return null;
}

/// List roots that belong in the right panel only (not the center column).
bool isDesktopPanelRoot(String path) {
  return path == '/automate' ||
      path == '/hosts' ||
      path == '/vpn' ||
      path == '/settings';
}

/// Nested routes (edit host, schedule, terminal) that must render
/// via [StatefulNavigationShell] in the center column on desktop.
///
/// Settings MCP / API-key subpages stay in the right Settings panel instead.
bool isDesktopDetailRoute(String path) {
  if (path.startsWith('/agents')) return false;
  if (isDesktopPanelRoot(path)) return false;
  if (isDesktopSettingsSubroute(path)) return false;
  return path.startsWith('/hosts') ||
      path.startsWith('/automate') ||
      path.startsWith('/vpn');
}

/// MCP editor and API-key screens opened from the Settings panel.
bool isDesktopSettingsSubroute(String path) {
  if (!path.startsWith('/settings/')) return false;
  final segs = Uri.tryParse(path)?.pathSegments ?? const <String>[];
  if (segs.length < 2 || segs[0] != 'settings') return false;
  return segs[1] == 'mcp' || segs[1] == 'keys';
}

/// Host id for `/hosts/terminal/:hostId`, if [path] is a terminal session.
String? terminalHostIdFromPath(String path) {
  final segs = Uri.tryParse(path)?.pathSegments;
  if (segs == null || segs.length < 3) return null;
  if (segs[0] == 'hosts' && segs[1] == 'terminal' && segs[2].isNotEmpty) {
    return segs[2];
  }
  return null;
}

String? chatIdFromRoute(GoRouterState state) {
  final fromParam = state.pathParameters['chatId'];
  if (fromParam != null && fromParam.isNotEmpty) return fromParam;
  final segs = state.uri.pathSegments;
  if (segs.length >= 3 && segs[0] == 'agents' && segs[1] == 'chat') {
    return segs[2];
  }
  return null;
}

/// Open a secondary panel — right column on desktop, full tab on phone.
void openAppPanel(
  BuildContext context,
  WidgetRef ref,
  DesktopRightPanel panel,
) {
  if (useDesktopShell(context)) {
    ref.read(desktopRightPanelProvider.notifier).state = panel;
    return;
  }
  switch (panel) {
    case DesktopRightPanel.automate:
      context.go('/automate');
    case DesktopRightPanel.hosts:
      context.go('/hosts');
    case DesktopRightPanel.vpn:
      context.go('/vpn');
    case DesktopRightPanel.settings:
      context.go('/settings');
    case DesktopRightPanel.files:
    case DesktopRightPanel.none:
      break;
  }
}

/// Open a Settings subpage (MCP editor, API keys). On desktop this stays in the
/// right panel and keeps the current chat; on phone it uses go_router.
void openSettingsSubpage(
  BuildContext context,
  WidgetRef ref,
  String route,
) {
  if (useDesktopShell(context)) {
    ref.read(desktopRightPanelProvider.notifier).state =
        DesktopRightPanel.settings;
    ref.read(desktopSettingsOverlayProvider.notifier).state = route;
    return;
  }
  context.push(route);
}

/// Back to Settings home (desktop overlay) or pop the phone stack.
void closeSettingsSubpage(BuildContext context, WidgetRef ref) {
  if (useDesktopShell(context)) {
    ref.read(desktopSettingsOverlayProvider.notifier).state = null;
    return;
  }
  if (context.canPop()) {
    context.pop();
  } else {
    context.go('/settings');
  }
}
