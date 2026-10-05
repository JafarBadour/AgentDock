// A prompt sent while the host is mid-turn is queued, because ADSM refuses it
// with "agent is already running a turn". Draining only happened on focus,
// reconnect and turn_complete — miss all three and the message sat in the
// queue indefinitely while the chat showed it as sent.
import 'dart:async';
import 'dart:io';

import 'package:agentplantation/data/local/app_database.dart';
import 'package:agentplantation/data/models/agent_mode.dart';
import 'package:agentplantation/data/models/agent_model.dart';
import 'package:agentplantation/data/models/agent_provider.dart';
import 'package:agentplantation/data/models/chat.dart';
import 'package:agentplantation/data/models/chat_message.dart';
import 'package:agentplantation/data/models/host.dart';
import 'package:agentplantation/data/models/prompt_image.dart';
import 'package:agentplantation/data/models/repo.dart';
import 'package:agentplantation/services/adsm_client.dart';
import 'package:agentplantation/services/agent_session.dart';
import 'package:agentplantation/services/chat_session_runtime.dart';
import 'package:agentplantation/services/cursor_acp_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingSession implements AgentSession {
  final _updates = StreamController<AcpUpdate>.broadcast();
  final List<String> prompts = [];

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

Future<AppDatabase> _dbWithChat() async {
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

ChatMessage _queued() => ChatMessage(
  id: 'queued-1',
  chatId: 'chat',
  role: MessageRole.user,
  content: 'did u finish?',
  createdAt: DateTime.utc(2026, 10, 5, 6, 32, 47),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // The prompt path resolves image attachments against the documents dir.
    final tmp = Directory.systemTemp.createTempSync('outbound-queue-test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tmp.path,
        );
  });

  test('a queued prompt is delivered by the periodic retry', () async {
    final db = await _dbWithChat();
    await db.setOutboundQueue('chat', [_queued()]);
    final session = _RecordingSession();
    final runtime = ChatSessionRuntime(
      chatId: 'chat',
      session: session,
      db: db,
    );
    await runtime.restoreOutboundQueue();

    expect(runtime.hasUndeliveredOutbound, isTrue);

    runtime.retryPendingOutbound();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(session.prompts, ['did u finish?']);
    expect(runtime.outboundQueue, isEmpty);

    await runtime.disposeRuntime();
  });

  test('the retry stands down while the host is mid-turn', () async {
    final db = await _dbWithChat();
    await db.setOutboundQueue('chat', [_queued()]);
    final session = _RecordingSession();
    final runtime = ChatSessionRuntime(
      chatId: 'chat',
      session: session,
      db: db,
    );
    await runtime.restoreOutboundQueue();
    runtime.remoteTurnActive = true;

    expect(runtime.hasUndeliveredOutbound, isFalse);

    runtime.retryPendingOutbound();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(session.prompts, isEmpty);
    expect(runtime.outboundQueue, hasLength(1));

    // Once the turn ends the next sweep picks it up.
    runtime.remoteTurnActive = false;
    runtime.retryPendingOutbound();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(session.prompts, ['did u finish?']);

    await runtime.disposeRuntime();
  });

  test('an empty queue is a no-op', () async {
    final db = await _dbWithChat();
    final session = _RecordingSession();
    final runtime = ChatSessionRuntime(
      chatId: 'chat',
      session: session,
      db: db,
    );
    await runtime.restoreOutboundQueue();

    expect(runtime.hasUndeliveredOutbound, isFalse);
    runtime.retryPendingOutbound();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(session.prompts, isEmpty);

    await runtime.disposeRuntime();
  });
}
