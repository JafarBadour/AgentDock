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
import 'features/hosts/hosts_screen.dart';
import 'features/agents/agents_screen.dart';
import 'services/local_host_bootstrap.dart';

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
      // Keep provider alive so remote deletes tear down ACP sessions.
      ref.read(remoteDeletedChatsPrunerProvider);
      // Mac / Windows: offer this machine as a host for local agents.
      unawaited(() async {
        final host = await ensureLocalThisComputerHost(
          ref.read(appDatabaseProvider),
        );
        if (host == null || !mounted) return;
        ref.invalidate(hostsListProvider);
        ref.invalidate(agentsTreeProvider);
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
        ref.read(appInForegroundProvider.notifier).state = true;
        ref.read(sshServiceProvider).onAppResumed();
        // Host agents are durable. Do not reconnect every chat or sweep every
        // host just because the window regained focus; either operation runs
        // dartssh2 crypto on the UI isolate and stalls the first interactive
        // frames. The focused chat reconnects on Send/Connect, and catalog
        // refresh is an explicit user action.
        // Re-assert FGS in case the OEM killed the notification.
        unawaited(ref.read(backgroundKeepAliveProvider).ensureRunning());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        ref.read(appInForegroundProvider.notifier).state = false;
        unawaited(_suspendBridgesUnlessKeepAlive());
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

  /// Prefer starting the foreground service over dropping SSH mid-send.
  Future<void> _suspendBridgesUnlessKeepAlive() async {
    final keep = ref.read(backgroundKeepAliveProvider);
    if (keep.canSurviveBackground) return;
    if (await keep.isEnabled()) {
      // Notification permission / OEM deny may have left _holding false.
      if (await keep.ensureRunning()) return;
    }
    if (!mounted) return;
    // Only force an immediate remote flush when transports really are about to
    // be suspended. Desktop window switching and a healthy foreground service
    // keep the normal debounced push path; forcing a full encrypted write on
    // every focus change was visible as UI jank after returning.
    await ref.read(agentDockServiceProvider).flushPendingPushes();
    if (!mounted) return;
    ref.read(activeAcpSessionsProvider.notifier).suspendAll();
    ref.read(sshServiceProvider).onAppPaused();
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
                    textScaler: MediaQuery.textScalerOf(
                      context,
                    ).clamp(minScaleFactor: 0.9, maxScaleFactor: 1.1),
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
