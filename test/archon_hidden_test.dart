import 'package:agent_dock/data/models/archon_chat.dart';
import 'package:agent_dock/data/models/agent_provider.dart';
import 'package:agent_dock/data/models/chat.dart';
import 'package:flutter_test/flutter_test.dart';

Chat _chat(String id) => Chat(
  id: id,
  repoId: 'r',
  title: id,
  provider: AgentProvider.claude,
  createdAt: DateTime.utc(2026, 9, 30),
  updatedAt: DateTime.utc(2026, 9, 30),
);

/// Archon is a chat row so it inherits transcript, streaming, reconnect and
/// multi-device sync — but it manages the agents rather than being one, so the
/// Agents list must never show it.
void main() {
  test('Archon is recognised by its reserved id', () {
    expect(_chat(kArchonChatId).isArchon, isTrue);
    expect(_chat('some-uuid').isArchon, isFalse);
  });

  test('withoutArchon drops it and keeps the rest in order', () {
    final chats = [_chat('a'), _chat(kArchonChatId), _chat('b')];
    expect(withoutArchon(chats).map((c) => c.id), ['a', 'b']);
  });

  test('a list with no Archon is unchanged', () {
    final chats = [_chat('a'), _chat('b')];
    expect(withoutArchon(chats).map((c) => c.id), ['a', 'b']);
  });

  test('a list of only Archon becomes empty, not null', () {
    expect(withoutArchon([_chat(kArchonChatId)]), isEmpty);
  });
}
