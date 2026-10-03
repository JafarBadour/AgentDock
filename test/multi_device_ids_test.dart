import 'package:agentplantation/data/models/chat_message.dart';
import 'package:agentplantation/services/adsm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('segment ids match the host formula (worker.segment_message_id)', () {
    // Same vector as host/adsm/tests/test_multi_device.py.
    expect(
      streamSegmentMessageId('c1', 't1:7'),
      '4a1bb356-cfdc-5e27-a855-443c38203e50',
    );
    expect(streamSegmentMessageId('c1', null), isNull);
  });

  test('stream id needs both turn and seq', () {
    expect(adsmStreamId({'turnId': 't1', 'seq': 7}), 't1:7');
    expect(adsmStreamId({'seq': 7}), isNull);
    expect(adsmStreamId({'turnId': 't1'}), isNull);
  });

  test('user_message event becomes a user row', () {
    final m = adsmUserMessage({
      'chatId': 'c1',
      'kind': 'user_message',
      'messageId': 'm1',
      'text': 'look at this',
      'imageCount': 2,
      'createdAt': '2026-09-28T10:00:00+00:00',
    })!;
    expect(m.id, 'm1');
    expect(m.role, MessageRole.user);
    expect(m.content, '🖼 2 images\n\nlook at this');
    expect(m.createdAt.toUtc(), DateTime.utc(2026, 9, 28, 10));
    expect(adsmUserMessage({'chatId': 'c1', 'messageId': 'm2'}), isNull);
  });
}
