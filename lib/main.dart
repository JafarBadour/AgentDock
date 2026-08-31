import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Start the pedometer-style foreground service immediately — do not wait
      // for an agent connect. That is what keeps SSH alive across app switches.
      unawaited(() async {
        final keep = ref.read(backgroundKeepAliveProvider);
        await keep.init();
        await keep.ensureRunning();
      }());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        ref.read(sshServiceProvider).onAppResumed();
        ref.read(activeAcpSessionsProvider.notifier).resumeAll();
        unawaited(ref.read(agentDockServiceProvider).syncAllHostsCatalog());
        // Re-assert FGS in case the OEM killed the notification.
        unawaited(ref.read(backgroundKeepAliveProvider).ensureRunning());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(ref.read(agentDockServiceProvider).flushPendingPushes());
        if (!ref.read(backgroundKeepAliveProvider).canSurviveBackground) {
          ref.read(activeAcpSessionsProvider.notifier).suspendAll();
          ref.read(sshServiceProvider).onAppPaused();
        }
      case AppLifecycleState.detached:
        // Hand durable turns to the host, but leave the foreground service up
        // (stopWithTask=false) so the process can survive like a pedometer.
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
    return WithForegroundTask(
      child: MaterialApp.router(
        title: 'Agent Dock',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        darkTheme: buildAppTheme(),
        themeMode: ThemeMode.dark,
        builder: (context, child) =>
            WavyBackground(child: child ?? const SizedBox.shrink()),
        routerConfig: router,
      ),
    );
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const ProviderScope(child: AgentDockApp()));
}
