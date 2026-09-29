import 'package:agent_dock/data/models/chat_message.dart';
import 'package:agent_dock/services/transcript_budget.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _m(String id, String body, int sec) => ChatMessage(
  id: id,
  chatId: 'c',
  role: MessageRole.user,
  content: body,
  createdAt: DateTime.utc(2026, 1, 1, 10, 0, sec),
);

void main() {
  final all = [for (var i = 0; i < 6; i++) _m('m$i', 'message $i', i)];

  test('an unknown beforeId still yields the archive', () {
    // The view is showing a live segment this store has never persisted, so
    // everything stored is older than it. Reporting nothing is what made
    // "Load earlier messages" answer "no earlier messages" over a full archive.
    final got = takeOlderMessagesByBytes(
      all,
      beforeId: 'never-persisted',
      maxBytes: 1 << 20,
    );
    expect(got, isNotEmpty);
    expect(got.length, 6);
  });

  test('the oldest beforeId correctly reports nothing older', () {
    expect(
      takeOlderMessagesByBytes(all, beforeId: 'm0', maxBytes: 1 << 20),
      isEmpty,
    );
  });

  test('a middle beforeId returns only what precedes it', () {
    final got = takeOlderMessagesByBytes(
      all,
      beforeId: 'm3',
      maxBytes: 1 << 20,
    );
    expect(got.map((m) => m.id), ['m0', 'm1', 'm2']);
  });

  test('the byte budget still bounds an unknown pivot', () {
    final got = takeOlderMessagesByBytes(
      all,
      beforeId: 'never-persisted',
      maxBytes: 1,
    );
    expect(got.length, lessThanOrEqualTo(1));
  });
}
