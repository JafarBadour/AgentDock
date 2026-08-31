import 'package:agent_dock/data/local/app_database.dart';
import 'package:agent_dock/data/models/agent_provider.dart';
import 'package:agent_dock/data/models/chat.dart';
import 'package:agent_dock/data/models/chat_message.dart';
import 'package:agent_dock/data/models/host.dart';
import 'package:agent_dock/data/models/repo.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

/// Stands in for the streaming half of ChatSessionRuntime: text accumulates in
/// memory and is checkpointed to the same row until the turn ends.
class _StreamingTurn {
  _StreamingTurn(this._db, this.chatId);

  final AppDatabase _db;
  final String chatId;

  String buffer = '';
  String? _messageId;
  DateTime? _startedAt;

  ChatMessage _snapshot(String text) => ChatMessage(
        id: _messageId ??= const Uuid().v4(),
        chatId: chatId,
        role: MessageRole.assistant,
        content: text,
        createdAt: _startedAt ??= DateTime(2026, 1, 1, 10),
      );

  Future<void> checkpoint() async {
    final text = buffer.trim();
    if (text.isEmpty) return;
    await _db.upsertMessage(_snapshot(text));
  }

  Future<void> finish() async {
    final text = buffer.trim();
    buffer = '';
    if (text.isEmpty) return;
    final message = _snapshot(text);
    _messageId = null;
    _startedAt = null;
    await _db.upsertMessage(message);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(overridePath: inMemoryDatabasePath);
    final now = DateTime(2026, 1, 1);
    await db.upsertHost(
      Host(
        id: 'host-1',
        alias: 'box',
        hostname: 'example.com',
        username: 'me',
        createdAt: now,
      ),
    );
    await db.upsertRepo(
      Repo(
        id: 'repo-1',
        hostId: 'host-1',
        name: 'proj',
        remotePath: '/home/me/proj',
        createdAt: now,
      ),
    );
    await db.upsertChat(
      Chat(
        id: 'chat-1',
        repoId: 'repo-1',
        title: 'Agent',
        provider: AgentProvider.cursor,
        createdAt: now,
        updatedAt: now,
      ),
    );
  });

  test('a turn killed mid-stream keeps what was already on screen', () async {
    final turn = _StreamingTurn(db, 'chat-1');

    turn.buffer += '**AG Sprint 32** — 24 open tickets:\n';
    await turn.checkpoint();
    turn.buffer += '| AG-4085 | High | Fix the thing |\n';
    await turn.checkpoint();
    turn.buffer += '| AG-4086 | Low | Another thing |';
    await turn.checkpoint();

    // Process dies here: no finish(), no clean close.
    final survived = await db.listMessages('chat-1');
    expect(survived, hasLength(1));
    expect(survived.single.content, contains('AG-4086'));
  });

  test('checkpoints collapse into one message, not a fragment per chunk',
      () async {
    final turn = _StreamingTurn(db, 'chat-1');
    for (final chunk in ['one ', 'two ', 'three']) {
      turn.buffer += chunk;
      await turn.checkpoint();
    }
    await turn.finish();

    final all = await db.listMessages('chat-1');
    expect(all, hasLength(1));
    expect(all.single.content, 'one two three');
  });

  test('a following turn is its own message', () async {
    final turn = _StreamingTurn(db, 'chat-1');
    turn.buffer += 'first answer';
    await turn.finish();
    turn.buffer += 'second answer';
    await turn.finish();

    final all = await db.listMessages('chat-1');
    expect(all.map((m) => m.content).toList(), [
      'first answer',
      'second answer',
    ]);
  });

  test('a checkpointed row is not duplicated by a later remote merge', () async {
    final turn = _StreamingTurn(db, 'chat-1');
    turn.buffer += 'partial';
    await turn.checkpoint();
    final id = (await db.listMessages('chat-1')).single.id;
    turn.buffer += ' and the rest';
    await turn.finish();

    // The host still holds the truncated copy it was pushed mid-stream.
    await db.mergeMessages('chat-1', [
      ChatMessage(
        id: id,
        chatId: 'chat-1',
        role: MessageRole.assistant,
        content: 'partial',
        createdAt: DateTime(2026, 1, 1, 10),
      ),
    ]);

    final all = await db.listMessages('chat-1');
    expect(all, hasLength(1));
    expect(all.single.content, 'partial and the rest');
  });
}
