// A bridge that attaches and dies seconds later used to reconnect from
// attempt zero every time: `replaceSession` cleared the counter the instant
// a session attached, so the backoff stayed at its first step and
// `maxReconnectAttempts` was never reached. The loop ran unbounded and
// silent — one host logged 16 jump-host logins in 14 minutes, tightening to
// one every ten seconds. Connecting is not succeeding; holding is.
import 'dart:async';

import 'package:agentplantation/data/local/app_database.dart';
import 'package:agentplantation/data/models/agent_mode.dart';
import 'package:agentplantation/data/models/agent_model.dart';
import 'package:agentplantation/data/models/agent_provider.dart';
import 'package:agentplantation/data/models/chat.dart';
import 'package:agentplantation/data/models/host.dart';
import 'package:agentplantation/data/models/prompt_image.dart';
import 'package:agentplantation/data/models/repo.dart';
import 'package:agentplantation/services/agent_session.dart';
import 'package:agentplantation/services/chat_session_runtime.dart';
import 'package:agentplantation/services/cursor_acp_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Session implements AgentSession {
  final _updates = StreamController<AcpUpdate>.broadcast();

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
  Future<void> prompt(String text,
      {List<PromptImage> images = const [],
      String? userMessageId,
      DateTime? userCreatedAt}) async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> setMode(AgentSessionMode next) async => mode = next;
  @override
  Future<void> setModel(String modelId) async {}
  @override
  void setPermissionPolicy(PermissionPolicy policy) {}
  @override
  void resolvePermission(Object requestId, String optionId) {}
  @override
  void cancelOpenPermissions() {}
  @override
  Future<void> ensureModelCatalog(
      {required List<Map<String, dynamic>> mcpServers}) async {}
  @override
  void handOffPrompt() {}
  @override
  Future<void> close() => _updates.close();
}

Future<AppDatabase> _db() async {
  final db = AppDatabase(overridePath: inMemoryDatabasePath);
  final now = DateTime.utc(2026);
  await db.upsertHost(Host(
      id: 'host',
      alias: 'host',
      hostname: 'example.com',
      username: 'test',
      createdAt: now));
  await db.upsertRepo(Repo(
      id: 'repo',
      hostId: 'host',
      name: 'repo',
      remotePath: '/repo',
      createdAt: now));
  await db.upsertChat(Chat(
      id: 'chat',
      repoId: 'repo',
      title: 'chat',
      provider: AgentProvider.claude,
      createdAt: now,
      updatedAt: now));
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('attaching does not by itself forgive the backoff', () async {
    final rt = ChatSessionRuntime(
      chatId: 'chat',
      session: _Session(),
      db: await _db(),
    );
    rt.reconnectAttempts = 4;

    rt.replaceSession(_Session());

    // A bridge that has existed for microseconds has proven nothing. Were
    // this cleared here, a flapping host would retry from zero forever.
    expect(rt.reconnectAttempts, 4);
    await rt.disposeRuntime();
  });

  test('a bridge that holds clears it', () async {
    ChatSessionRuntime.stableAfter = const Duration(milliseconds: 40);
    addTearDown(
      () => ChatSessionRuntime.stableAfter = const Duration(seconds: 60),
    );
    final rt = ChatSessionRuntime(
      chatId: 'chat',
      session: _Session(),
      db: await _db(),
    );
    rt.reconnectAttempts = 4;

    rt.replaceSession(_Session());
    expect(rt.reconnectAttempts, 4, reason: 'too soon to count');

    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(rt.reconnectAttempts, 0, reason: 'it held, so forgive it');

    await rt.disposeRuntime();
  });

  test('a bridge that dies before the window keeps its backoff', () async {
    // The flapping case: attach, drop, attach, drop. Each attach must not
    // wipe the escalation, or the retry delay never grows and the loop runs
    // unbounded — which is what 16 logins in 14 minutes looked like.
    ChatSessionRuntime.stableAfter = const Duration(milliseconds: 200);
    addTearDown(
      () => ChatSessionRuntime.stableAfter = const Duration(seconds: 60),
    );
    final rt = ChatSessionRuntime(
      chatId: 'chat',
      session: _Session(),
      db: await _db(),
    );
    rt.reconnectAttempts = 3;

    rt.replaceSession(_Session());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    rt.closed = true; // died well short of the window
    await Future<void>.delayed(const Duration(milliseconds: 260));

    expect(rt.reconnectAttempts, 3);
    await rt.disposeRuntime();
  });

  test('ten failed attempts is a ceiling, not an infinite loop', () {
    expect(ChatSessionRuntime.maxReconnectAttempts, 10);
  });
}
