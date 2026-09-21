import 'dart:convert';

import 'package:agent_dock/data/models/chat_message.dart';
import 'package:agent_dock/services/transcript_parse.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _msg(String id, MessageRole role, String content) => ChatMessage(
      id: id,
      chatId: 'c',
      role: role,
      content: content,
      createdAt: DateTime(2026, 1, 1),
    );

String _tool(String id, {int outputBytes = 0}) => jsonEncode({
      'toolCallId': id,
      'title': 'Bash',
      'kind': 'execute',
      'status': 'completed',
      'rawInput': jsonEncode({'command': 'ls -la /tmp/$id'}),
      'rawOutput': 'x' * outputBytes,
    });

void main() {
  test('small batches parse inline with summaries and full payloads', () async {
    final rows = await parseTranscriptRowsOffThread([
      _msg('u', MessageRole.user, 'hi'),
      _msg('t', MessageRole.tool, _tool('tc1')),
      _msg('bad', MessageRole.tool, 'not json'),
    ]);
    expect(rows, hasLength(3));
    expect(rows[0].tool, isNull);
    expect(rows[1].tool?.toolCallId, 'tc1');
    expect(rows[1].tool?.rawInput, isNotNull);
    expect(rows[1].summary?.rawInput, isNull);
    expect(rows[1].summary?.preview, 'ls -la /tmp/tc1');
    expect(rows[2].tool, isNull);
    expect(rows[2].message.role, MessageRole.tool);
  });

  test('large batches go through the worker isolate with the same result',
      () async {
    final messages = [
      for (var i = 0; i < 40; i++)
        _msg('t$i', MessageRole.tool, _tool('tc$i', outputBytes: 4000)),
      _msg('a', MessageRole.assistant, 'done'),
    ];
    expect(
      messages.fold<int>(0, (n, m) => n + m.content.length),
      greaterThan(kInlineParseBytes),
    );
    final rows = await parseTranscriptRowsOffThread(messages);
    expect(rows, hasLength(41));
    expect(rows.last.message.id, 'a');
    expect(rows[7].tool?.rawOutput?.length, 4000);
    expect(rows[7].summary?.rawOutput, isNull);
    expect(rows[7].summary?.outputHead?.length, 2000);

    final entries = await entriesFromMessagesOffThread(messages);
    expect(entries[7].tool?.toolCallId, 'tc7');
    expect(entries[7].tool?.hasPayloads, isFalse);
    expect(entries[7].messageId, 't7');
    expect(entries.last.message?.content, 'done');
  });
}
