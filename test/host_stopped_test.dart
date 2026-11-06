// A reaped agent used to vanish without a word: the host stops the worker
// and says so, but the app handled `dead` in the same branch as `idle` ("the
// turn finished"), dropped the host's explanation (the label only renders
// while streaming), and fell through to " · live" because the SSH bridge was
// still open. The bridge being up says nothing about the agent.
import 'dart:async';

import 'package:agentplantation/data/local/app_database.dart';
import 'package:agentplantation/data/models/agent_mode.dart';
import 'package:agentplantation/data/models/agent_model.dart';
import 'package:agentplantation/data/models/chat.dart';
import 'package:agentplantation/data/models/agent_provider.dart';
import 'package:agentplantation/data/models/host.dart';
import 'package:agentplantation/data/models/prompt_image.dart';
import 'package:agentplantation/data/models/repo.dart';
import 'package:agentplantation/services/agent_session.dart';
import 'package:agentplantation/services/chat_session_runtime.dart';
import 'package:agentplantation/services/cursor_acp_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingSession implements AgentSession {
  final _updates = StreamController<AcpUpdate>.broadcast();
  final List<String> prompts = [];

  /// Push an update as the host would.
  void push(AcpUpdate u) => _updates.add(u);

  @override
  Stream<AcpUpdate> get updates => _updates.stream;

  @override
  String? get sessionId => 'test';

  @override
  AcpTransport get transport => AcpTransport.durable;

  @override
  AgentSessionMode mode = AgentSessionMode.agent;

  @override
  PermissionPolicy permissionPolicy = PermissionPolicy.ask;

  @override
  List<AgentModel> get availableModels => const [];

  @override
  String? get currentModelId => null;

  @override
  List<String> get availableModeIds => const [];

  @override
  AcpAgentCapabilities get capabilities =>
      const AcpAgentCapabilities(loadSession: true);

  @override
  bool get isPromptActive => false;

  @override
  bool get resumedInPlace => true;

  @override
  void seedModelCatalog(List<AgentModel> models) {}

  @override
  Future<void> prompt(
    String text, {
    List<PromptImage> images = const [],
    String? userMessageId,
    DateTime? userCreatedAt,
  }) async {
    prompts.add(text);
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> setMode(AgentSessionMode next) async => mode = next;

  @override
  Future<void> setModel(String modelId) async {}

  @override
  void setPermissionPolicy(PermissionPolicy policy) {
    permissionPolicy = policy;
  }

  @override
  void resolvePermission(Object requestId, String optionId) {}

  @override
  void cancelOpenPermissions() {}

  @override
  Future<void> ensureModelCatalog({
    required List<Map<String, dynamic>> mcpServers,
  }) async {}

  @override
  void handOffPrompt() {}

  @override
  Future<void> close() => _updates.close();
}

Future<AppDatabase> _db() async {
  final db = AppDatabase(overridePath: inMemoryDatabasePath);
  final now = DateTime.utc(2026);
  await db.upsertHost(
    Host(
      id: 'host',
      alias: 'host',
      hostname: 'example.com',
      username: 'test',
      createdAt: now,
    ),
  );
  await db.upsertRepo(
    Repo(
      id: 'repo',
      hostId: 'host',
      name: 'repo',
      remotePath: '/repo',
      createdAt: now,
    ),
  );
  await db.upsertChat(
    Chat(
      id: 'chat',
      repoId: 'repo',
      title: 'chat',
      provider: AgentProvider.claude,
      createdAt: now,
      updatedAt: now,
    ),
  );
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<(ChatSessionRuntime, _RecordingSession)> build() async {
    final session = _RecordingSession();
    final rt = ChatSessionRuntime(
      chatId: 'chat',
      session: session,
      db: await _db(),
    );
    rt.startListening();
    return (rt, session);
  }

  test('a dead status marks the agent stopped', () async {
    final (rt, session) = await build();
    expect(rt.hostStopped, isFalse);

    session.push(const AcpUpdate.daemonStatus('dead'));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(rt.hostStopped, isTrue);
    await rt.disposeRuntime();
  });

  test('idle means the turn finished, not that the agent is gone', () async {
    // Collapsing these two is what produced the silent disconnect.
    final (rt, session) = await build();
    session.push(const AcpUpdate.daemonStatus('idle'));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(rt.hostStopped, isFalse);
    await rt.disposeRuntime();
  });

  test('it keeps the wording the host sent', () async {
    final (rt, session) = await build();
    session.push(const AcpUpdate.daemonStatus('dead'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    session.push(
      const AcpUpdate.activity('Agent paused on host — will resume on next message'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(rt.hostStoppedReason, contains('paused on host'));
    await rt.disposeRuntime();
  });

  test('the agent coming back clears it', () async {
    final (rt, session) = await build();
    session.push(const AcpUpdate.daemonStatus('dead'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rt.hostStopped, isTrue);

    session.push(const AcpUpdate.daemonStatus('running'));
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(rt.hostStopped, isFalse);
    expect(rt.hostStoppedReason, isNull);
    await rt.disposeRuntime();
  });
}
