import 'dart:convert';

import 'package:agent_dock/data/models/chat_message.dart';
import 'package:agent_dock/data/models/inline_images.dart';
import 'package:agent_dock/data/models/tool_call_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final png = 'iVBORw0KGgo${'A' * 50000}==';

  test('strips long base64 images and keeps the JSON valid', () {
    final raw = jsonEncode([
      {
        'type': 'image',
        'source': {'type': 'base64', 'data': png},
      },
    ]);
    // Tool rows store rawOutput as a JSON string inside JSON.
    final row = jsonEncode({'title': 'Read', 'rawOutput': raw});
    final out = stripInlineImages(row);
    expect(out.length, lessThan(300));
    final decoded = jsonDecode(out) as Map<String, dynamic>;
    final inner = jsonDecode(decoded['rawOutput'] as String) as List;
    expect(inner.first['source']['data'], startsWith('[image omitted,'));
  });

  test('leaves ordinary and short payloads alone', () {
    const text = 'exit code 0\n/9j/ appears in a path but is short';
    expect(stripInlineImages(text), text);
    final short = 'iVBORw0KGgo${'A' * 100}';
    expect(stripInlineImages(short), short);
    final long = 'x' * 100000;
    expect(identical(stripInlineImages(long), long), isTrue);
  });

  test('formatOpaque drops images from structured tool content', () {
    final out = ToolCallState.formatOpaque([
      {
        'type': 'content',
        'content': {'type': 'image', 'data': png},
      },
    ])!;
    expect(out, contains('[image omitted,'));
    expect(out.length, lessThan(200));
  });

  test('tool rows read from storage come back without the blob', () {
    final msg = ChatMessage.fromMap({
      'id': '1',
      'chat_id': 'c',
      'role': 'tool',
      'content': jsonEncode({'rawOutput': png}),
      'created_at': '2026-09-28T00:00:00.000',
    });
    expect(msg.content.length, lessThan(200));
    final user = ChatMessage.fromMap({
      'id': '2',
      'chat_id': 'c',
      'role': 'user',
      'content': png,
      'created_at': '2026-09-28T00:00:00.000',
    });
    expect(user.content, png);
  });

  test('handles real-size blobs without a backtracking regex', () {
    // A RegExp `{2000,}` run threw StackOverflowError on 60 KB+ blobs in
    // AOT (release) builds and crashed the v21 cleanup at startup. JIT tests
    // did not reproduce it, so pin the size and the linear-time behavior.
    final big = 'iVBORw0KGgo${'Ab+/' * 500000}=';
    final row = '{"rawOutput":"$big","content":"$big"}';
    final sw = Stopwatch()..start();
    final out = stripInlineImages(row);
    expect(sw.elapsedMilliseconds, lessThan(2000));
    expect(out, '{"rawOutput":"[image omitted, 1464 KB]",'
        '"content":"[image omitted, 1464 KB]"}');
  });
}
