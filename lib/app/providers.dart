import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_database.dart';
import '../data/models/host.dart';
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
import '../services/skill_deploy_service.dart';
import '../services/schedule_runner.dart';
import '../services/schedule_sync_service.dart';
import '../services/ssh_service.dart';
import '../services/ssh_socks_service.dart';
import '../services/transcript_budget.dart';

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final localNotificationServiceProvider = Provider<LocalNotificationService>(
  (ref) => LocalNotificationService(),
);

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
  unawaited(service.loadPersistedCaches());
  ref.onDispose(service.dispose);
  return service;
});

final sshSocksServiceProvider = ChangeNotifierProvider<SshSocksService>((ref) {
  final service = SshSocksService(
    ref.watch(sshServiceProvider),
    notifications: ref.watch(localNotificationServiceProvider),
    keepAlive: ref.watch(backgroundKeepAliveProvider),
  );
  ref.onDispose(service.dispose);
  return service;
});

/// Shared ADSM NDJSON bridge per host (one SSH for many chats).
final adsmBridgePoolProvider = Provider<AdsmBridgePool>((ref) {
  return AdsmBridgePool(ref.watch(sshServiceProvider));
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

final skillDeployServiceProvider = Provider<SkillDeployService>(
  (ref) => SkillDeployService(
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
    ref
        .read(pendingRemoteDeletedChatIdsProvider.notifier)
        .update((ids) => [...ids, chatId]);
  };
  unawaited(service.loadPersistedCaches());
  ref.onDispose(service.dispose);
  return service;
});

/// Bumped when the host catalog removes chats (cross-device delete).
final agentsCatalogEpochProvider = StateProvider<int>((ref) => 0);

/// Explicit, deduplicated host-catalog refresh.
///
/// Bulk SSH work must never start merely because a widget was mounted. The
/// previous FutureProvider did exactly that from the permanently mounted
/// desktop sidebar, while app-resume and schedule startup launched overlapping
/// sweeps. Key parsing, SSH packet handling, transcript decoding, and DB merge
/// notifications then competed with every animation and keystroke.
final catalogSyncProvider =
    StateNotifierProvider<CatalogSyncController, AsyncValue<String?>>((ref) {
      return CatalogSyncController(
        ref.watch(agentDockServiceProvider),
        onComplete: () {
          ref.read(agentsCatalogEpochProvider.notifier).state++;
        },
      );
    });

class CatalogSyncController extends StateNotifier<AsyncValue<String?>> {
  CatalogSyncController(this._dock, {required this.onComplete})
    : super(const AsyncValue.data(null));

  final AgentDockService _dock;
  final void Function() onComplete;
  Future<String?>? _inFlight;

  Future<String?> refresh() {
    final active = _inFlight;
    if (active != null) return active;

    state = const AsyncValue.loading();
    late final Future<String?> run;
    run = () async {
      try {
        final note = await _dock.syncAllHostsCatalog();
        if (mounted) state = AsyncValue.data(note);
        return note;
      } catch (error, stack) {
        SafeLog.d('catalog sync failed', error, stack);
        if (mounted) state = AsyncValue.error(error, stack);
        return 'Could not sync hosts';
      } finally {
        onComplete();
        if (identical(_inFlight, run)) _inFlight = null;
      }
    }();
    _inFlight = run;
    return run;
  }
}

/// Chat ids removed by host sync — drained by [remoteDeletedChatsPrunerProvider].
final pendingRemoteDeletedChatIdsProvider = StateProvider<List<String>>(
  (ref) => const [],
);

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
    StateNotifierProvider<ActiveAcpSessions, Map<String, ChatSessionRuntime>>((
      ref,
    ) {
      // Tool updates land many times a second while a turn streams; coalesce them
      // so the agents list is not re-querying SQLite per token.
      Timer? tick;
      Timer? orderTick;
      ref.onDispose(() {
        tick?.cancel();
        orderTick?.cancel();
      });
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
          // True debounce: wait until transcript writes go quiet. The previous
          // `??=` timers fired every few seconds throughout a long turn, causing
          // recurring SQLite queries/sidebar rebuilds while the user scrolled.
          tick?.cancel();
          tick = Timer(const Duration(seconds: 2), () {
            tick = null;
            ref.read(chatActivityTickProvider.notifier).state++;
          });
          orderTick?.cancel();
          orderTick = Timer(const Duration(seconds: 3), () {
            orderTick = null;
            ref.read(agentsCatalogEpochProvider.notifier).state++;
          });
        },
      );
    });

class ActiveAcpSessions extends StateNotifier<Map<String, ChatSessionRuntime>> {
  ActiveAcpSessions(
    this._db, {
    required BackgroundKeepAlive keepAlive,
    required LocalNotificationService notifications,
    required bool Function(String chatId) isChatFocused,
    this.onLocalChange,
  }) : _keepAlive = keepAlive,
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
  Timer? _adsmStatusPollSoon;
  bool _adsmStatusPollInFlight = false;

  /// Consecutive unanswered `agents.list` polls per bridge. dartssh2's
  /// keepalive stops after its first unanswered ping, so a half-dead TCP
  /// path (VPN handover, sleeping laptop) otherwise stays "open" until the
  /// OS gives up — a quarter hour of a chat that neither works nor reconnects.
  final Map<AdsmClient, int> _bridgePollMisses = {};

  /// Misses before the bridge is declared dead and closed, which surfaces a
  /// `closed` event to its chats so their normal auto-reconnect takes over.
  static const _deadBridgeMisses = 2;

  /// How often to ask ADSM for authoritative worker status across all live
  /// bridges. One `agents.list` per shared bridge — not per chat.
  static const _adsmStatusPollInterval = Duration(seconds: 30);

  ChatSessionRuntime? get(String chatId) => state[chatId];

  AgentSession? sessionFor(String chatId) => state[chatId]?.session;

  void _syncAdsmStatusPoll({bool kickSoon = false}) {
    final hasAdsm = state.values.any(
      (r) => !r.closed && r.session is AdsmSession,
    );
    if (!hasAdsm) {
      _adsmStatusPoll?.cancel();
      _adsmStatusPoll = null;
      _adsmStatusPollSoon?.cancel();
      _adsmStatusPollSoon = null;
      return;
    }
    _adsmStatusPoll ??= Timer.periodic(_adsmStatusPollInterval, (_) {
      unawaited(_pollAllAdsmStatuses());
    });
    // Coalesce transport-ready storms (N chats reconnecting on one host)
    // instead of firing N immediate agents.list sweeps that jank the UI.
    if (kickSoon) {
      _adsmStatusPollSoon ??= Timer(const Duration(seconds: 2), () {
        _adsmStatusPollSoon = null;
        unawaited(_pollAllAdsmStatuses());
      });
    }
  }

  Future<void> _pollAllAdsmStatuses() async {
    if (_adsmStatusPollInFlight) return;
    _adsmStatusPollInFlight = true;
    try {
      final byBridge = <AdsmClient, List<AdsmSession>>{};
      for (final runtime in state.values) {
        if (runtime.closed || runtime.session is! AdsmSession) continue;
        // Skip sessions mid-reconnect — their bridge is about to be replaced.
        if (runtime.reconnecting) continue;
        final session = runtime.session as AdsmSession;
        byBridge.putIfAbsent(session.bridgeClient, () => []).add(session);
      }
      _bridgePollMisses.removeWhere((c, _) => !c.isOpen);
      await Future.wait(
        byBridge.entries.map((entry) async {
          final client = entry.key;
          final sessions = entry.value;
          if (!client.isOpen) return;
          try {
            final list = await client.request(
              'agents.list',
              {},
              timeout: const Duration(seconds: 8),
            );
            _bridgePollMisses.remove(client);
            for (final session in sessions) {
              session.applyAgentsList(list, forceEmit: false);
            }
          } on TimeoutException catch (e) {
            final misses = (_bridgePollMisses[client] ?? 0) + 1;
            _bridgePollMisses[client] = misses;
            SafeLog.d('ADSM status poll for bridge timed out ($misses)', e);
            if (misses < _deadBridgeMisses) {
              // Confirm quickly instead of waiting a full poll interval.
              _adsmStatusPollSoon ??= Timer(const Duration(seconds: 5), () {
                _adsmStatusPollSoon = null;
                unawaited(_pollAllAdsmStatuses());
              });
              return;
            }
            _bridgePollMisses.remove(client);
            SafeLog.d(
              'ADSM bridge unresponsive after $misses polls — closing it so '
              '${sessions.length} chat(s) reconnect',
            );
            try {
              await client.close();
            } catch (_) {}
          } catch (e) {
            SafeLog.d('ADSM status poll for bridge failed', e);
          }
        }),
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
      unawaited(existing.syncTranscriptFromDb());
      // Do NOT copy the map here — identity churn rebuilt Agents sidebar +
      // ChatScreen on every reconnect while the runtime instance is unchanged.
      _syncKeepAlive();
      _syncAdsmStatusPoll(kickSoon: true);
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
      shouldAutoReconnect: () => _isChatFocused(chatId),
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
    final page = await _db.listRecentMessagesByBytes(
      chatId,
      maxBytes: kTranscriptChunkBytes,
    );
    await runtime.hydrateFromMessagesAsync(page.messages);
    runtime.hasMoreOlder =
        page.hasMore ||
        (session is AdsmSession && session.hostTranscriptHasMore);
    runtime.startListening();
    await runtime.rememberSessionId();
    state = {...state, chatId: runtime};
    runtime.resumeOutboundQueue();
    _syncKeepAlive();
    _syncAdsmStatusPoll(kickSoon: true);
    return runtime;
  }

  void _onTransportReady(String chatId) {
    if (!state.containsKey(chatId)) return;
    // Runtime instance is stable across reconnect — ChatScreen already listens
    // to it. Copying the Riverpod map was rebuilding the whole Agents list.
    // attach already merged the bounded host transcript; do not launch a
    // second concurrent DB merge here.
    _syncKeepAlive();
    _syncAdsmStatusPoll(kickSoon: true);
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
        // Journal watermark is not a catalog/order change — skip onLocalChange
        // so Agents sidebar does not reload SQLite during streaming.
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
    _adsmStatusPollSoon?.cancel();
    _adsmStatusPollSoon = null;
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
    _adsmStatusPollSoon?.cancel();
    _adsmStatusPollSoon = null;
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
  vpn,
  settings,

  /// Project file browser for the active chat's repo (opened from chat).
  files,
}

/// Args for the desktop project-files right panel.
class DesktopProjectFilesArgs {
  const DesktopProjectFilesArgs({
    required this.host,
    required this.rootPath,
    this.title,
  });

  final Host host;
  final String rootPath;
  final String? title;
}

/// Right-hand panel on macOS / desktop (Automate, Hosts, VPN, Settings, Files).
final desktopRightPanelProvider = StateProvider<DesktopRightPanel>(
  (ref) => DesktopRightPanel.none,
);

/// In-panel Settings navigation on desktop (MCP / API keys) without leaving
/// the current chat URL. Values like `/settings/keys` or `/settings/mcp/<id>`.
final desktopSettingsOverlayProvider = StateProvider<String?>((ref) => null);

/// Left-sidebar browse mode on macOS: recency agents, directories, or hosts.
enum AgentsSidebarMode { agents, directories, hosts }

final agentsSidebarModeProvider = StateProvider<AgentsSidebarMode>(
  (ref) => AgentsSidebarMode.agents,
);

/// Host + path for [DesktopRightPanel.files]; cleared when the panel closes.
final desktopProjectFilesProvider = StateProvider<DesktopProjectFilesArgs?>(
  (ref) => null,
);

/// True while the Flutter app is in the resumed lifecycle state.
final appInForegroundProvider = StateProvider<bool>((ref) => true);
