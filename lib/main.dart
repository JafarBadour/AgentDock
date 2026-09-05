import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app/app_theme.dart';
import 'app/providers.dart';
import 'app/router.dart';
import 'app/platform_layout.dart';
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
      unawaited(ref.read(localNotificationServiceProvider).init());
      // Schedule runner polls due automated prompts while the app is alive.
      ref.read(scheduleRunnerProvider).start();
      // Keep provider alive so remote deletes tear down ACP sessions.
      ref.read(remoteDeletedChatsPrunerProvider);
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
        ref.read(appInForegroundProvider.notifier).state = true;
        ref.read(sshServiceProvider).onAppResumed();
        ref.read(activeAcpSessionsProvider.notifier).resumeAll();
        unawaited(ref.read(agentDockServiceProvider).syncAllHostsCatalog());
        // Re-assert FGS in case the OEM killed the notification.
        unawaited(ref.read(backgroundKeepAliveProvider).ensureRunning());
        unawaited(ref.read(scheduleRunnerProvider).tick());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        ref.read(appInForegroundProvider.notifier).state = false;
        unawaited(ref.read(agentDockServiceProvider).flushPendingPushes());
        if (!ref.read(backgroundKeepAliveProvider).canSurviveBackground) {
          ref.read(activeAcpSessionsProvider.notifier).suspendAll();
          ref.read(sshServiceProvider).onAppPaused();
        }
      case AppLifecycleState.detached:
        ref.read(appInForegroundProvider.notifier).state = false;
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
    final dense = useDesktopShell();
    final theme = buildAppTheme(dense: dense);
    return WithForegroundTask(
      child: MaterialApp.router(
        title: 'Agent Dock',
        debugShowCheckedModeBanner: false,
        theme: theme,
        darkTheme: theme,
        themeMode: ThemeMode.dark,
        builder: (context, child) {
          final body = child ?? const SizedBox.shrink();
          // Cap OS accessibility text scaling on desktop so the shell stays
          // Cursor-dense even when macOS text size is turned up.
          final scaled = dense
              ? MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: MediaQuery.textScalerOf(context).clamp(
                      minScaleFactor: 0.85,
                      maxScaleFactor: 1.05,
                    ),
                  ),
                  child: body,
                )
              : body;
          if (dense) return scaled;
          return WavyBackground(child: scaled);
        },
        routerConfig: router,
      ),
    );
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // sqflite has no native Windows/Linux plugin — use FFI SQLite there.
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  FlutterForegroundTask.initCommunicationPort();
  runApp(const ProviderScope(child: AgentDockApp()));
}
