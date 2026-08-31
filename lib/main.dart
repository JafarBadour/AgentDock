import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app_theme.dart';
import 'app/providers.dart';
import 'app/router.dart';
import 'app/wavy_background.dart';

class AgentDockApp extends ConsumerStatefulWidget {
  const AgentDockApp({super.key});

  @override
  ConsumerState<AgentDockApp> createState() => _AgentDockAppState();
}

class _AgentDockAppState extends ConsumerState<AgentDockApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Sockets do not survive suspension. Rather than discover that on the user's
  /// next tap, drop them on the way out and re-verify on the way back in.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        ref.read(sshServiceProvider).onAppResumed();
        ref.read(activeAcpSessionsProvider.notifier).resumeAll();
        unawaited(ref.read(agentDockServiceProvider).syncAllHostsCatalog());
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        unawaited(ref.read(agentDockServiceProvider).flushPendingPushes());
        ref.read(activeAcpSessionsProvider.notifier).suspendAll();
        ref.read(sshServiceProvider).onAppPaused();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(goRouterProvider);
    return MaterialApp.router(
      title: 'Agent Dock',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      darkTheme: buildAppTheme(),
      themeMode: ThemeMode.dark,
      builder: (context, child) =>
          WavyBackground(child: child ?? const SizedBox.shrink()),
      routerConfig: router,
    );
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: AgentDockApp()));
}
