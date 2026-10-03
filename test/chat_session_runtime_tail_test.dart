import 'dart:async';

import 'package:agentplantation/data/local/app_database.dart';
import 'package:agentplantation/data/models/agent_provider.dart';
import 'package:agentplantation/data/models/agent_mode.dart';
import 'package:agentplantation/data/models/agent_model.dart';
import 'package:agentplantation/data/models/chat.dart';
import 'package:agentplantation/data/models/chat_message.dart';
import 'package:agentplantation/data/models/host.dart';
import 'package:agentplantation/data/models/prompt_image.dart';
import 'package:agentplantation/data/models/repo.dart';
import 'package:agentplantation/data/models/tool_call_state.dart';
import 'package:agentplantation/services/adsm_client.dart';
import 'package:agentplantation/services/agent_session.dart';
import 'package:agentplantation/services/chat_session_runtime.dart';
import 'package:agentplantation/services/cursor_acp_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeSession implements AgentSession {
  final _updates = StreamController<AcpUpdate>.broadcast();

  void emit(AcpUpdate update) => _updates.add(update);

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
  }) async {}

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

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('runtime keeps a bounded indexed transcript tail', () async {
    final session = _FakeSession();
    final runtime = ChatSessionRuntime(
      chatId: 'chat',
      session: session,
      db: AppDatabase(overridePath: ':memory:'),
    );
    final start = DateTime.utc(2026);
    final messages = [
      for (var i = 0; i < 5000; i++)
        ChatMessage(
          id: 'm-$i',
          chatId: 'chat',
          role: i.isEven ? MessageRole.user : MessageRole.assistant,
          content: 'message $i',
          createdAt: start.add(Duration(seconds: i)),
        ),
    ];

    runtime.absorbMessages(messages);

    expect(
      runtime.entries,
      hasLength(ChatSessionRuntime.residentTranscriptLimit),
    );
    expect(runtime.entries.first.messageId, 'm-4100');
    expect(runtime.entries.last.messageId, 'm-4999');

    runtime.absorbMessages([
      ChatMessage(
        id: messages.last.id,
        chatId: messages.last.chatId,
        role: messages.last.role,
        content: 'message 4999 expanded',
        createdAt: messages.last.createdAt,
      ),
    ]);
    expect(runtime.entries, hasLength(900));
    expect(runtime.entries.last.message?.content, 'message 4999 expanded');

    await runtime.disposeRuntime();
  });

  test('tool progress storms coalesce and terminal state wins', () async {
    final session = _FakeSession();
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
        provider: AgentProvider.cursor,
        createdAt: now,
        updatedAt: now,
      ),
    );
    final runtime = ChatSessionRuntime(chatId: 'chat', session: session, db: db)
      ..startListening();

    for (var i = 0; i < 100; i++) {
      session.emit(
        AcpUpdate.toolCall(
          ToolCallState(
            toolCallId: 'tool-1',
            title: 'Search',
            status: 'in_progress',
            rawOutput: 'chunk $i',
          ),
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(runtime.entries.where((e) => e.tool != null), hasLength(1));
    expect(runtime.entries.single.tool?.outputHead, 'chunk 99');

    session.emit(
      AcpUpdate.toolCall(
        const ToolCallState(
          toolCallId: 'tool-1',
          title: 'Search',
          status: 'completed',
          rawOutput: 'done',
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(runtime.entries.single.tool?.status, 'completed');
    expect(runtime.entries.single.tool?.outputHead, 'done');

    await runtime.disposeRuntime();
  });

  group('multi-device', () {
    Future<(AppDatabase, _FakeSession, ChatSessionRuntime)> open() async {
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
      final session = _FakeSession();
      final runtime = ChatSessionRuntime(
        chatId: 'chat',
        session: session,
        db: db,
      )..startListening();
      return (db, session, runtime);
    }

    ChatMessage fromPhone(String id, String text) => ChatMessage(
      id: id,
      chatId: 'chat',
      role: MessageRole.user,
      content: text,
      createdAt: DateTime.utc(2026, 1, 2),
    );

    test('a message sent from another device shows up once', () async {
      final (db, session, runtime) = await open();
      session.emit(AcpUpdate.userMessage(fromPhone('m1', 'from the phone')));
      session.emit(AcpUpdate.userMessage(fromPhone('m1', 'from the phone')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final users = runtime.entries.where((e) => e.messageId == 'm1');
      expect(users, hasLength(1));
      expect((await db.getMessage('m1'))?.content, 'from the phone');
      await runtime.disposeRuntime();
    });

    test('our own send echoed back by the host is ignored', () async {
      final (db, session, runtime) = await open();
      // As sent from this device: stored with image markers under its id.
      final sent = fromPhone('m1', '<!--agentdock-img:a.png|image/png-->\nhi');
      await db.upsertMessage(sent);
      runtime.absorbMessages([sent]);
      session.emit(AcpUpdate.userMessage(fromPhone('m1', '🖼 Image\n\nhi')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(runtime.entries.where((e) => e.messageId == 'm1'), hasLength(1));
      expect((await db.getMessage('m1'))?.content, sent.content);
      await runtime.disposeRuntime();
    });

    test('streamed reply and thought take host-derived ids', () async {
      final (db, session, runtime) = await open();
      session.emit(const AcpUpdate.thought('hmm', streamId: 't1:3'));
      session.emit(const AcpUpdate.delta('Hello', streamId: 't1:5'));
      session.emit(const AcpUpdate.delta(' there', streamId: 't1:6'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await runtime.flushAssistantBuffer();
      await runtime.commitThought();
      final thought = await db.getMessage(
        streamSegmentMessageId('chat', 't1:3')!,
      );
      final reply = await db.getMessage(
        streamSegmentMessageId('chat', 't1:5')!,
      );
      expect(thought?.role, MessageRole.system);
      expect(reply?.content, 'Hello there');
      await runtime.disposeRuntime();
    });
  });
}
