import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/app_database.dart';
import '../data/secure/secure_store.dart';
import '../services/agentdock_service.dart';
import '../services/chat_session_runtime.dart';
import '../services/config_backup_service.dart';
import '../services/cursor_acp_service.dart';
import '../services/mcp_deploy_service.dart';
import '../services/ssh_service.dart';
import '../services/tmux_service.dart';

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

final sshServiceProvider = Provider<SshService>(
  (ref) => SshService(
    ref.watch(secureStoreProvider),
    ref.watch(appDatabaseProvider),
  ),
);

final tmuxServiceProvider = Provider<TmuxService>(
  (ref) => TmuxService(ref.watch(sshServiceProvider)),
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
  (ref) => ActiveAcpSessions(
    ref.watch(appDatabaseProvider),
    onLocalChange: (chatId) {
      ref.read(agentDockServiceProvider).schedulePushChat(chatId);
    },
  ),
);

class ActiveAcpSessions extends StateNotifier<Map<String, ChatSessionRuntime>> {
  ActiveAcpSessions(
    this._db, {
    this.onLocalChange,
  }) : super({});

  final AppDatabase _db;
  final void Function(String chatId)? onLocalChange;

  ChatSessionRuntime? get(String chatId) => state[chatId];

  AcpSession? sessionFor(String chatId) => state[chatId]?.session;

  Future<ChatSessionRuntime> attach({
    required String chatId,
    required AcpSession session,
  }) async {
    final existing = state[chatId];
    if (existing != null) {
      existing.replaceSession(session);
      state = {...state};
      return existing;
    }

    final runtime = ChatSessionRuntime(
      chatId: chatId,
      session: session,
      db: _db,
      onLocalChange: onLocalChange,
    );
    final messages = await _db.listMessages(chatId);
    runtime.hydrateFromMessages(messages);
    runtime.startListening();
    state = {...state, chatId: runtime};
    return runtime;
  }

  Future<void> close(String chatId) async {
    final runtime = state[chatId];
    if (runtime == null) return;
    await runtime.disposeRuntime();
    final next = Map<String, ChatSessionRuntime>.from(state)..remove(chatId);
    state = next;
  }

  Future<void> closeAll() async {
    for (final runtime in state.values) {
      await runtime.disposeRuntime();
    }
    state = {};
  }
}

final hasSshKeyProvider = FutureProvider<bool>((ref) async {
  return ref.watch(secureStoreProvider).hasSshPrivateKey();
});
