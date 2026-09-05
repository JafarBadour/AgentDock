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
  if (path.startsWith('/connect')) return DesktopRightPanel.connect;
  if (path.startsWith('/settings')) return DesktopRightPanel.settings;
  return null;
}

/// List roots that belong in the right panel only (not the center column).
bool isDesktopPanelRoot(String path) {
  return path == '/automate' ||
      path == '/hosts' ||
      path == '/connect' ||
      path == '/settings';
}

/// Nested routes (edit host, schedule, MCP, repos, terminal) that must render
/// via [StatefulNavigationShell] in the center column on desktop.
bool isDesktopDetailRoute(String path) {
  if (path.startsWith('/agents')) return false;
  if (isDesktopPanelRoot(path)) return false;
  return path.startsWith('/hosts') ||
      path.startsWith('/automate') ||
      path.startsWith('/settings') ||
      path.startsWith('/connect');
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
    case DesktopRightPanel.connect:
      context.go('/connect');
    case DesktopRightPanel.settings:
      context.go('/settings');
    case DesktopRightPanel.none:
      break;
  }
}
