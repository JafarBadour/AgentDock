import 'package:agent_dock/data/models/chat_message.dart';
import 'package:agent_dock/services/transcript_budget.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _msg(String id, String content, {int seconds = 0}) => ChatMessage(
      id: id,
      chatId: 'c1',
      role: MessageRole.user,
      content: content,
      createdAt: DateTime.utc(2026, 1, 1, 0, 0, seconds),
    );

void main() {
  test('takeRecentMessagesByBytes keeps newest under budget', () {
    final all = [
      _msg('a', 'a' * 100, seconds: 1),
      _msg('b', 'b' * 100, seconds: 2),
      _msg('c', 'c' * 100, seconds: 3),
    ];
    // Each message is 100 + 64 overhead = 164 bytes.
    final slice = takeRecentMessagesByBytes(all, maxBytes: 200);
    expect(slice.map((m) => m.id), ['c']);
  });

  test('takeOlderMessagesByBytes pages before cursor', () {
    final all = [
      for (var i = 0; i < 5; i++)
        _msg('m$i', 'x' * 50, seconds: i),
    ];
    final older = takeOlderMessagesByBytes(
      all,
      beforeId: 'm3',
      maxBytes: 200,
    );
    expect(older, isNotEmpty);
    expect(older.every((m) => m.id != 'm3' && m.id != 'm4'), isTrue);
    expect(older.last.id, anyOf('m2', 'm1', 'm0'));
  });

  test('chunk constant is 1 MiB', () {
    expect(kTranscriptChunkBytes, 1024 * 1024);
  });
}
