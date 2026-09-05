import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_database.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import '../services/adsm_client.dart';
import '../services/agent_runtime_host.dart';
import '../services/agent_session.dart';
import '../services/agentdock_service.dart';
import '../services/background_keep_alive.dart';
import '../services/chat_session_runtime.dart';
import '../services/config_backup_service.dart';
import '../services/gcp_speech_service.dart';
import '../services/local_notification_service.dart';
import '../services/mcp_deploy_service.dart';
import '../services/schedule_runner.dart';
import '../services/schedule_sync_service.dart';
import '../services/ssh_service.dart';

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final localNotificationServiceProvider =
    Provider<LocalNotificationService>((ref) => LocalNotificationService());

final gcpSpeechServiceProvider = Provider<GcpSpeechService>((ref) {
  final service = GcpSpeechService(ref.watch(secureStoreProvider));
  ref.onDispose(service.dispose);
  return service;
});

final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

/// Bumped when schedules are created/edited/toggled/run so the list refreshes.
final scheduledJobsTickProvider = StateProvider<int>((ref) => 0);

final backgroundKeepAliveProvider = Provider<BackgroundKeepAlive>((ref) {
  return BackgroundKeepAlive();
});

final sshServiceProvider = Provider<SshService>((ref) {
  final service = SshService(
    ref.watch(secureStoreProvider),
    ref.watch(appDatabaseProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Bumped every time a runtime writes something to the local transcript.
///
/// Lets the agents list refresh unread counts as replies land, instead of
/// polling or only noticing when you navigate.
final chatActivityTickProvider = StateProvider<int>((ref) => 0);

final agentRuntimeHostProvider = Provider<AgentRuntimeHost>(
  (ref) => AgentRuntimeHost(ref.watch(sshServiceProvider)),
);

final mcpDeployServiceProvider = Provider<McpDeployService>(
  (ref) => McpDeployService(
    ref.watch(sshServiceProvider),
    ref.watch(appDatabaseProvider),
  ),
);

final agentDockServiceProvider = Provider<AgentDockService>((ref) {
  final service = AgentDockService(
    ref.watch(sshServiceProvider),
    ref.watch(appDatabaseProvider),
  );
  service.onChatRemoved = (chatId) {
    // Refresh the agents list when a remote delete lands. ACP teardown is
    // handled separately to avoid a Riverpod provider cycle with
    // activeAcpSessionsProvider.
    ref.read(agentsCatalogEpochProvider.notifier).state++;
    ref.read(pendingRemoteDeletedChatIdsProvider.notifier).update(
          (ids) => [...ids, chatId],
        );
  };
  ref.onDispose(service.dispose);
  return service;
});

/// Bumped when the host catalog removes chats (cross-device delete).
final agentsCatalogEpochProvider = StateProvider<int>((ref) => 0);

/// Chat ids removed by host sync — drained by [remoteDeletedChatsPrunerProvider].
final pendingRemoteDeletedChatIdsProvider =
    StateProvider<List<String>>((ref) => const []);

/// Closes ACP runtimes for chats deleted on another device.
final remoteDeletedChatsPrunerProvider = Provider<void>((ref) {
  ref.listen<List<String>>(pendingRemoteDeletedChatIdsProvider, (prev, next) {
    if (next.isEmpty) return;
    ref.read(pendingRemoteDeletedChatIdsProvider.notifier).state = const [];
    final sessions = ref.read(activeAcpSessionsProvider.notifier);
    for (final id in next) {
      unawaited(sessions.close(id));
    }
  });
});

final configBackupServiceProvider = Provider<ConfigBackupService>(
  (ref) => ConfigBackupService(ref.watch(appDatabaseProvider)),
);

/// Long-lived ACP runtimes keyed by chat id — survive leaving the chat screen.
final activeAcpSessionsProvider =
    StateNotifierProvider<ActiveAcpSessions, Map<String, ChatSessionRuntime>>(
  (ref) {
    // Tool updates land many times a second while a turn streams; coalesce them
    // so the agents list is not re-querying SQLite per token.
    Timer? tick;
    ref.onDispose(() => tick?.cancel());
    return ActiveAcpSessions(
      ref.watch(appDatabaseProvider),
      keepAlive: ref.watch(backgroundKeepAliveProvider),
      notifications: ref.watch(localNotificationServiceProvider),
      isChatFocused: (chatId) {
        final focused = ref.read(focusedChatIdProvider);
        final foreground = ref.read(appInForegroundProvider);
        return foreground && focused == chatId;
      },
      onLocalChange: (chatId) {
        ref.read(agentDockServiceProvider).schedulePushChat(chatId);
        // Coalesce aggressively — Agents sidebar must not rebuild every token.
        tick ??= Timer(const Duration(seconds: 8), () {
          tick = null;
          ref.read(chatActivityTickProvider.notifier).state++;
        });
      },
    );
  },
);

class ActiveAcpSessions extends StateNotifier<Map<String, ChatSessionRuntime>> {
  ActiveAcpSessions(
    this._db, {
    required BackgroundKeepAlive keepAlive,
    required LocalNotificationService notifications,
    required bool Function(String chatId) isChatFocused,
    this.onLocalChange,
  })  : _keepAlive = keepAlive,
        _notifications = notifications,
        _isChatFocused = isChatFocused,
        super({});

  final AppDatabase _db;
  final BackgroundKeepAlive _keepAlive;
  final LocalNotificationService _notifications;
  final bool Function(String chatId) _isChatFocused;
  final void Function(String chatId)? onLocalChange;

  final Map<String, Timer> _offsetTimers = {};
  final Map<String, int> _pendingOffsets = {};
  final Map<String, Timer> _transcriptPushTimers = {};
  Timer? _adsmStatusPoll;
  bool _adsmStatusPollInFlight = false;

  /// How often to ask ADSM for authoritative worker status across all live
  /// bridges. Cheap (`agents.list`) and keeps sticky UI in sync with the host.
  static const _adsmStatusPollInterval = Duration(seconds: 15);

  ChatSessionRuntime? get(String chatId) => state[chatId];

  AgentSession? sessionFor(String chatId) => state[chatId]?.session;

  void _syncAdsmStatusPoll() {
    final hasAdsm = state.values.any(
      (r) => !r.closed && r.session is AdsmSession,
    );
    if (!hasAdsm) {
      _adsmStatusPoll?.cancel();
      _adsmStatusPoll = null;
      return;
    }
    if (_adsmStatusPoll != null) return;
    // Immediate pass, then every interval — sticky chrome should not wait
    // a full period after connect / resume.
    unawaited(_pollAllAdsmStatuses());
    _adsmStatusPoll = Timer.periodic(_adsmStatusPollInterval, (_) {
      unawaited(_pollAllAdsmStatuses());
    });
  }

  Future<void> _pollAllAdsmStatuses() async {
    if (_adsmStatusPollInFlight) return;
    _adsmStatusPollInFlight = true;
    try {
      final sessions = <AdsmSession>[
        for (final runtime in state.values)
          if (!runtime.closed && runtime.session is AdsmSession)
            runtime.session as AdsmSession,
      ];
      // Parallel per bridge — each session owns its own ADSM SSH client.
      await Future.wait(
        sessions.map((s) => s.refreshDaemonStatus()),
        eagerError: false,
      );
    } catch (e) {
      SafeLog.d('ADSM status poll sweep failed', e);
    } finally {
      _adsmStatusPollInFlight = false;
    }
  }

  void _onRuntimeLocalChange(String chatId) {
    onLocalChange?.call(chatId);
    _scheduleTranscriptPush(chatId);
  }

  /// Debounced ADSM `transcript.sync` so host messages/*.jsonl stay complete.
  void _scheduleTranscriptPush(String chatId) {
    _transcriptPushTimers[chatId]?.cancel();
    _transcriptPushTimers[chatId] = Timer(const Duration(seconds: 5), () {
      _transcriptPushTimers.remove(chatId);
      unawaited(state[chatId]?.pushTranscriptToHost());
    });
  }

  Future<ChatSessionRuntime> attach({
    required String chatId,
    required AgentSession session,
    Future<AgentSession> Function()? sessionFactory,
  }) async {
    // Fold host-durable transcript into SQLite before the UI binds.
    if (session is AdsmSession && session.hostTranscript.isNotEmpty) {
      try {
        await _db.mergeMessages(chatId, session.hostTranscript);
      } catch (e) {
        SafeLog.d('merge host transcript failed', e);
      }
    }

    final existing = state[chatId];
    if (existing != null) {
      if (sessionFactory != null) existing.sessionFactory = sessionFactory;
      existing.replaceSession(session);
      // Host/DB may have advanced while the bridge was down.
      unawaited(existing.pullHostTranscriptAndSync());
      state = {...state};
      _syncKeepAlive();
      _syncAdsmStatusPoll();
      return existing;
    }

    late final ChatSessionRuntime runtime;
    runtime = ChatSessionRuntime(
      chatId: chatId,
      session: session,
      db: _db,
      onLocalChange: _onRuntimeLocalChange,
      onTransportReady: _onTransportReady,
      sessionFactory: sessionFactory,
      onAssistantText: (snippet) {
        final title = runtime.chatMeta?.title ?? 'Agent';
        unawaited(
          _notifications.notifyAssistantText(
            chatId: chatId,
            title: title,
            snippet: snippet,
            suppressBecauseFocused: _isChatFocused(chatId),
          ),
        );
      },
    );
    await runtime.restoreOutboundQueue();
    final messages = await _db.listMessages(chatId);
    runtime.hydrateFromMessages(messages);
    runtime.startListening();
    await runtime.rememberSessionId();
    state = {...state, chatId: runtime};
    runtime.resumeOutboundQueue();
    // Push any local-only rows up so the host stays complete.
    unawaited(runtime.pushTranscriptToHost());
    _syncKeepAlive();
    _syncAdsmStatusPoll();
    return runtime;
  }

  void _onTransportReady(String chatId) {
    if (!state.containsKey(chatId)) return;
    // Auto-reconnect calls replaceSession without attach — bump map identity
    // so ChatScreen rebinds after a closed/reconnecting stretch.
    state = {...state};
    unawaited(state[chatId]?.syncTranscriptFromDb());
    _syncKeepAlive();
    _syncAdsmStatusPoll();
  }

  void _syncKeepAlive() {
    // Pedometer-style: stay running even with zero open sessions.
    unawaited(_keepAlive.sync(sessionCount: state.length));
  }

  /// Remember how far into the remote journal we have read, so the next
  /// connection resumes instead of replaying. Debounced — this fires for every
  /// chunk of streamed output.
  void noteJournalOffset(String chatId, int bytes) {
    _pendingOffsets[chatId] = bytes;
    _armOffsetTimer(chatId);
  }

  void _armOffsetTimer(String chatId) {
    _offsetTimers[chatId]?.cancel();
    _offsetTimers[chatId] = Timer(const Duration(seconds: 2), () async {
      final bytes = _pendingOffsets[chatId];
      if (bytes == null) return;
      // This offset is a commit watermark, not a read one. The next connection
      // skips everything before it, so publishing it while the text it decoded
      // to is still only in memory would drop the tail of a turn for good.
      // Wait for the runtime to catch up instead.
      if (state[chatId]?.hasUnpersistedOutput ?? false) {
        _armOffsetTimer(chatId);
        return;
      }
      _pendingOffsets.remove(chatId);
      try {
        await _db.setJournalOffset(chatId, bytes);
        onLocalChange?.call(chatId);
      } catch (e) {
        SafeLog.d('persist journal offset failed', e);
      }
    });
  }

  void suspendAll() {
    for (final runtime in state.values) {
      runtime.suspend();
    }
  }

  void resumeAll() {
    for (final runtime in state.values) {
      runtime.resume();
    }
  }

  Future<void> close(String chatId) async {
    final runtime = state[chatId];
    if (runtime == null) return;
    _offsetTimers.remove(chatId)?.cancel();
    _pendingOffsets.remove(chatId);
    _transcriptPushTimers.remove(chatId)?.cancel();
    // Final flush before tearing down the ADSM session.
    unawaited(runtime.pushTranscriptToHost());
    await runtime.disposeRuntime();
    final next = Map<String, ChatSessionRuntime>.from(state)..remove(chatId);
    state = next;
    _syncKeepAlive();
    _syncAdsmStatusPoll();
  }

  Future<void> closeAll() async {
    for (final timer in _offsetTimers.values) {
      timer.cancel();
    }
    _offsetTimers.clear();
    _pendingOffsets.clear();
    for (final timer in _transcriptPushTimers.values) {
      timer.cancel();
    }
    _transcriptPushTimers.clear();
    _adsmStatusPoll?.cancel();
    _adsmStatusPoll = null;
    for (final runtime in state.values) {
      await runtime.disposeRuntime();
    }
    state = {};
    _syncKeepAlive();
  }

  @override
  void dispose() {
    for (final timer in _offsetTimers.values) {
      timer.cancel();
    }
    _offsetTimers.clear();
    for (final timer in _transcriptPushTimers.values) {
      timer.cancel();
    }
    _transcriptPushTimers.clear();
    _adsmStatusPoll?.cancel();
    _adsmStatusPoll = null;
    super.dispose();
  }
}

final hasSshKeyProvider = FutureProvider<bool>((ref) async {
  return ref.watch(secureStoreProvider).hasSshPrivateKey();
});

final scheduleSyncServiceProvider = Provider<ScheduleSyncService>((ref) {
  return ScheduleSyncService(
    db: ref.watch(appDatabaseProvider),
    ssh: ref.watch(sshServiceProvider),
    secureStore: ref.watch(secureStoreProvider),
    dock: ref.watch(agentDockServiceProvider),
  );
});

final scheduleRunnerProvider = Provider<ScheduleRunner>((ref) {
  final runner = ScheduleRunner(
    db: ref.watch(appDatabaseProvider),
    sync: ref.watch(scheduleSyncServiceProvider),
    dock: ref.watch(agentDockServiceProvider),
    onJobsChanged: () {
      ref.read(scheduledJobsTickProvider.notifier).state++;
      ref.read(chatActivityTickProvider.notifier).state++;
    },
  );
  ref.onDispose(runner.dispose);
  return runner;
});

/// Composer text drafts keyed by chat id — survives leaving and re-opening a chat.
class ChatComposerDrafts extends StateNotifier<Map<String, String>> {
  ChatComposerDrafts() : super(const {});

  String? draftFor(String chatId) => state[chatId];

  void setDraft(String chatId, String text) {
    if (text.isEmpty) {
      if (!state.containsKey(chatId)) return;
      final next = Map<String, String>.from(state)..remove(chatId);
      state = next;
      return;
    }
    if (state[chatId] == text) return;
    state = {...state, chatId: text};
  }

  void clearDraft(String chatId) => setDraft(chatId, '');
}

final chatComposerDraftsProvider =
    StateNotifierProvider<ChatComposerDrafts, Map<String, String>>(
  (ref) => ChatComposerDrafts(),
);

/// Chat currently open in the UI — used to suppress local notifications.
final focusedChatIdProvider = StateProvider<String?>((ref) => null);

enum DesktopRightPanel {
  none,
  automate,
  hosts,
  connect,
  settings,
}

/// Right-hand panel on macOS / desktop (Automate, Hosts, Connect, Settings).
final desktopRightPanelProvider =
    StateProvider<DesktopRightPanel>((ref) => DesktopRightPanel.none);

/// True while the Flutter app is in the resumed lifecycle state.
final appInForegroundProvider = StateProvider<bool>((ref) => true);
