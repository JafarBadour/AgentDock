import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_database.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import '../services/agent_runtime_host.dart';
import '../services/agent_session.dart';
import '../services/agentdock_service.dart';
import '../services/background_keep_alive.dart';
import '../services/chat_session_runtime.dart';
import '../services/config_backup_service.dart';
import '../services/mcp_deploy_service.dart';
import '../services/ssh_service.dart';

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

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
  ref.onDispose(service.dispose);
  return service;
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
      onLocalChange: (chatId) {
        ref.read(agentDockServiceProvider).schedulePushChat(chatId);
        tick ??= Timer(const Duration(milliseconds: 700), () {
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
    this.onLocalChange,
  })  : _keepAlive = keepAlive,
        super({});

  final AppDatabase _db;
  final BackgroundKeepAlive _keepAlive;
  final void Function(String chatId)? onLocalChange;

  final Map<String, Timer> _offsetTimers = {};
  final Map<String, int> _pendingOffsets = {};

  ChatSessionRuntime? get(String chatId) => state[chatId];

  AgentSession? sessionFor(String chatId) => state[chatId]?.session;

  Future<ChatSessionRuntime> attach({
    required String chatId,
    required AgentSession session,
    Future<AgentSession> Function()? sessionFactory,
  }) async {
    final existing = state[chatId];
    if (existing != null) {
      if (sessionFactory != null) existing.sessionFactory = sessionFactory;
      existing.replaceSession(session);
      // Host/DB may have advanced while the bridge was down.
      unawaited(existing.syncTranscriptFromDb());
      state = {...state};
      _syncKeepAlive();
      return existing;
    }

    final runtime = ChatSessionRuntime(
      chatId: chatId,
      session: session,
      db: _db,
      onLocalChange: onLocalChange,
      onTransportReady: _onTransportReady,
      sessionFactory: sessionFactory,
    );
    await runtime.restoreOutboundQueue();
    final messages = await _db.listMessages(chatId);
    runtime.hydrateFromMessages(messages);
    runtime.startListening();
    await runtime.rememberSessionId();
    state = {...state, chatId: runtime};
    runtime.resumeOutboundQueue();
    _syncKeepAlive();
    return runtime;
  }

  void _onTransportReady(String chatId) {
    if (!state.containsKey(chatId)) return;
    // Auto-reconnect calls replaceSession without attach — bump map identity
    // so ChatScreen rebinds after a closed/reconnecting stretch.
    state = {...state};
    unawaited(state[chatId]?.syncTranscriptFromDb());
    _syncKeepAlive();
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
    await runtime.disposeRuntime();
    final next = Map<String, ChatSessionRuntime>.from(state)..remove(chatId);
    state = next;
    _syncKeepAlive();
  }

  Future<void> closeAll() async {
    for (final timer in _offsetTimers.values) {
      timer.cancel();
    }
    _offsetTimers.clear();
    _pendingOffsets.clear();
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
    super.dispose();
  }
}

final hasSshKeyProvider = FutureProvider<bool>((ref) async {
  return ref.watch(secureStoreProvider).hasSshPrivateKey();
});
