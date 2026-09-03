import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';

/// True on macOS desktop builds (and other desktop targets when wide enough).
bool useDesktopShell(BuildContext context) {
  if (kIsWeb) return false;
  if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
    return false;
  }
  return MediaQuery.sizeOf(context).width >= 840;
}

DesktopRightPanel? desktopPanelForPath(String path) {
  if (path.startsWith('/automate')) return DesktopRightPanel.automate;
  if (path.startsWith('/hosts')) return DesktopRightPanel.hosts;
  if (path.startsWith('/connect')) return DesktopRightPanel.connect;
  if (path.startsWith('/settings')) return DesktopRightPanel.settings;
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
