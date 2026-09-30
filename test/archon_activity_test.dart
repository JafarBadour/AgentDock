import 'package:agent_dock/features/archon/archon_activity_panel.dart';
import 'package:flutter_test/flutter_test.dart';

/// The log is what the user checks instead of taking Archon's word for it, so
/// a malformed row must be skipped rather than take the whole list down.
void main() {
  test('a full row parses', () {
    final action = ArchonAction.tryParse({
      'id': 7,
      'at': '2026-09-30T14:02:00+00:00',
      'command': 'prompt',
      'target': 'chat-1',
      'summary': 'rerun the failing test',
      'ok': true,
    })!;
    expect(action.command, 'prompt');
    expect(action.target, 'chat-1');
    expect(action.summary, 'rerun the failing test');
    expect(action.ok, isTrue);
  });

  test('a refusal is kept, not dropped', () {
    // What Archon was stopped from doing matters as much as what it did.
    final action = ArchonAction.tryParse({
      'id': 8,
      'at': '2026-09-30T14:03:00+00:00',
      'command': 'prompt',
      'target': 'chat-2',
      'summary': 'set to Ask',
      'ok': false,
    })!;
    expect(action.ok, isFalse);
  });

  test('times are shown in the reader\'s zone, not the host\'s', () {
    final action = ArchonAction.tryParse({
      'id': 1,
      'at': '2026-09-30T14:02:00+00:00',
      'command': 'done',
    })!;
    expect(action.at.isUtc, isFalse);
  });

  test('a row missing what identifies it is skipped', () {
    for (final raw in [
      null,
      'not a map',
      <String, Object?>{},
      {'at': 'nonsense', 'command': 'done'},
      {'at': '2026-09-30T14:02:00+00:00'},
      {'command': 'done'},
      {'at': '2026-09-30T14:02:00+00:00', 'command': 42},
    ]) {
      expect(ArchonAction.tryParse(raw), isNull, reason: 'raw: $raw');
    }
  });

  test('optional detail may be absent', () {
    final action = ArchonAction.tryParse({
      'id': 2,
      'at': '2026-09-30T14:02:00+00:00',
      'command': 'schedule',
    })!;
    expect(action.target, isNull);
    expect(action.summary, isNull);
    // Absent means it worked; only an explicit false is a refusal.
    expect(action.ok, isTrue);
  });
}
