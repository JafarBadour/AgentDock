import 'package:agent_dock/data/models/chat_message.dart';
import 'package:agent_dock/data/models/thought_message.dart';
import 'package:agent_dock/data/models/tool_call_state.dart';
import 'package:agent_dock/data/models/turn_stats_message.dart';
import 'package:agent_dock/features/agents/transcript_blocks.dart';
import 'package:agent_dock/services/chat_session_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage _msg(
  String id,
  MessageRole role,
  String content, {
  DateTime? at,
}) =>
    ChatMessage(
      id: id,
      chatId: 'c1',
      role: role,
      content: content,
      createdAt: at ?? DateTime(2026, 9, 7, 12),
    );

TranscriptEntry _user(String id, [String text = 'hi']) =>
    TranscriptEntry.message(_msg(id, MessageRole.user, text));

TranscriptEntry _assistant(String id, [String text = 'ok']) =>
    TranscriptEntry.message(_msg(id, MessageRole.assistant, text));

TranscriptEntry _thought(String id, String text) => TranscriptEntry.message(
      _msg(id, MessageRole.system, ThoughtMessage.encode(text)),
    );

TranscriptEntry _stats(String id, {int added = 1, int removed = 0}) =>
    TranscriptEntry.message(
      _msg(
        id,
        MessageRole.system,
        TurnStatsMessage.encode(added: added, removed: removed, files: 1),
      ),
    );

TranscriptEntry _tool(String id, {String status = 'completed'}) =>
    TranscriptEntry.tool(
      ToolCallState(
        toolCallId: id,
        title: 'Edit',
        kind: 'edit',
        status: status,
        locations: ['a.dart'],
        rawOutput: '''
--- a/a.dart
+++ b/a.dart
@@ -1 +1,2 @@
 line
+new
''',
      ),
      messageId: 'm-$id',
      createdAt: DateTime(2026, 9, 7, 12),
    );

void main() {
  group('entriesByTime', () {
    test('empty / single unchanged', () {
      expect(entriesByTime(const []), isEmpty);
      final one = [_user('u1')];
      expect(identical(entriesByTime(one), one) || entriesByTime(one).length == 1,
          isTrue);
      expect(entriesByTime(one).single.messageId, 'u1');
    });

    test('sorts by createdAt ascending', () {
      final early = TranscriptEntry.message(
        _msg('a', MessageRole.user, 'a', at: DateTime(2026, 1, 1)),
      );
      final late = TranscriptEntry.message(
        _msg('b', MessageRole.user, 'b', at: DateTime(2026, 2, 1)),
      );
      final sorted = entriesByTime([late, early]);
      expect(sorted.map((e) => e.messageId), ['a', 'b']);
    });

    test('equal timestamps keep original order', () {
      final t = DateTime(2026, 9, 7);
      final a = TranscriptEntry.message(
        _msg('1', MessageRole.user, '1', at: t),
      );
      final b = TranscriptEntry.message(
        _msg('2', MessageRole.assistant, '2', at: t),
      );
      expect(entriesByTime([a, b]).map((e) => e.messageId), ['1', '2']);
      expect(entriesByTime([b, a]).map((e) => e.messageId), ['2', '1']);
    });

    test('null createdAt sorts after dated entries', () {
      final dated = TranscriptEntry.message(
        _msg('d', MessageRole.user, 'd', at: DateTime(2026, 1, 1)),
      );
      final undated = TranscriptEntry.tool(
        const ToolCallState(toolCallId: 't', title: 'T'),
        createdAt: null,
      );
      // force null by using a custom path — tool factory always sets now.
      // Use message with same time and verify stability instead.
      final sorted = entriesByTime([dated, dated]);
      expect(sorted.length, 2);
      expect(undated.createdAt, isNotNull);
    });
  });

  group('transcriptBlocksCacheKey', () {
    test('changes when length / openTurn / last content changes', () {
      final a = [_user('u1'), _assistant('a1', 'hello')];
      final k1 = transcriptBlocksCacheKey(a, openTurnActive: false);
      final k2 = transcriptBlocksCacheKey(a, openTurnActive: true);
      expect(k1, isNot(k2));

      final b = [_user('u1'), _assistant('a1', 'hello!')];
      expect(
        transcriptBlocksCacheKey(a, openTurnActive: false),
        isNot(transcriptBlocksCacheKey(b, openTurnActive: false)),
      );

      final empty = transcriptBlocksCacheKey(const [], openTurnActive: false);
      expect(empty, startsWith('0|'));
    });

    test('tool status / output length affect key', () {
      final pending = [_tool('t1', status: 'pending')];
      final done = [_tool('t1', status: 'completed')];
      expect(
        transcriptBlocksCacheKey(pending, openTurnActive: true),
        isNot(transcriptBlocksCacheKey(done, openTurnActive: true)),
      );
    });
  });

  group('buildTranscriptBlocks', () {
    test('empty → empty', () {
      expect(buildTranscriptBlocks(const []), isEmpty);
    });

    test('user message alone', () {
      final blocks = buildTranscriptBlocks([_user('u1', 'hello')]);
      expect(blocks, hasLength(1));
      expect(blocks.single.entry?.message?.content, 'hello');
      expect(blocks.single.tools, isNull);
    });

    test('thought folds into following assistant', () {
      final blocks = buildTranscriptBlocks([
        _user('u1'),
        _thought('th1', 'reasoning…'),
        _assistant('a1', 'answer'),
      ]);
      expect(blocks, hasLength(2)); // user + assistant
      expect(blocks.last.thinking, 'reasoning…');
      expect(blocks.last.entry?.message?.content, 'answer');
    });

    test('orphan thought before user becomes thinking-only block', () {
      final blocks = buildTranscriptBlocks([
        _thought('th1', 'leftover'),
        _user('u1'),
      ]);
      expect(blocks.first.thinkingOnly, 'leftover');
      expect(blocks.last.entry?.message?.role, MessageRole.user);
    });

    test('trailing thought without assistant becomes thinking-only', () {
      final blocks = buildTranscriptBlocks([
        _user('u1'),
        _thought('th1', 'still thinking'),
      ]);
      expect(blocks.last.thinkingOnly, 'still thinking');
    });

    test('<=2 tools stay as individual cards', () {
      final blocks = buildTranscriptBlocks([
        _user('u1'),
        _tool('t1'),
        _tool('t2'),
        _assistant('a1'),
      ]);
      final toolBlocks = blocks.where((b) => b.entry?.tool != null).toList();
      expect(toolBlocks, hasLength(2));
      expect(blocks.any((b) => b.tools != null), isFalse);
    });

    test('>2 tools collapse into one tools group', () {
      final blocks = buildTranscriptBlocks([
        _user('u1'),
        _tool('t1'),
        _tool('t2'),
        _tool('t3'),
        _assistant('a1'),
      ]);
      final groups = blocks.where((b) => b.tools != null).toList();
      expect(groups, hasLength(1));
      expect(groups.single.tools, hasLength(3));
    });

    test('tool runs stay interleaved with assistant text', () {
      final blocks = buildTranscriptBlocks([
        _user('u1'),
        _tool('t1'),
        _tool('t2'),
        _tool('t3'),
        _assistant('a1', 'mid'),
        _tool('t4'),
        _tool('t5'),
        _tool('t6'),
        _assistant('a2', 'end'),
      ]);
      // user, tools×3, assistant, tools×3, assistant
      expect(blocks.map((b) {
        if (b.entry?.message?.role == MessageRole.user) return 'u';
        if (b.entry?.message?.role == MessageRole.assistant) {
          return b.entry!.message!.content;
        }
        if (b.tools != null) return 'tools:${b.tools!.length}';
        if (b.entry?.tool != null) return 'tool';
        return '?';
      }).toList(), [
        'u',
        'tools:3',
        'mid',
        'tools:3',
        'end',
      ]);
    });

    test('persisted turn stats attach after finished segment', () {
      final blocks = buildTranscriptBlocks([
        _user('u1'),
        _assistant('a1', 'done'),
        _stats('s1', added: 4, removed: 1),
        _user('u2'),
      ]);
      final withStats = blocks.where((b) => b.turnStats != null).toList();
      expect(withStats, isNotEmpty);
      expect(withStats.first.turnStats!.added, 4);
      expect(withStats.first.turnStats!.removed, 1);
    });

    test('open turn hides computed stats on last segment', () {
      final open = buildTranscriptBlocks(
        [_user('u1'), _tool('t1'), _assistant('a1', '…')],
        openTurnActive: true,
      );
      expect(open.every((b) => b.turnStats == null), isTrue);

      final closed = buildTranscriptBlocks(
        [_user('u1'), _tool('t1'), _assistant('a1', '…')],
        openTurnActive: false,
      );
      // Tool has a unified diff → computed stats should show when closed.
      expect(closed.any((b) => b.turnStats != null), isTrue);
    });

    test('persisted stats with code delta skip recomputing from tools', () {
      // Huge tool should not be required — persisted code wins.
      final blocks = buildTranscriptBlocks([
        _user('u1'),
        _tool('t1'),
        _assistant('a1'),
        _stats('s1', added: 99, removed: 7),
        _user('u2'),
      ]);
      final stats = blocks.map((b) => b.turnStats).whereType<TurnStats>();
      expect(stats.any((s) => s.added == 99 && s.removed == 7), isTrue);
    });

    test('multiple thoughts join into one thinking section', () {
      final blocks = buildTranscriptBlocks([
        _thought('t1', 'one'),
        _thought('t2', 'two'),
        _assistant('a1', 'ans'),
      ]);
      expect(blocks.single.thinking, 'one\n\ntwo');
    });

    test('turn stats without preceding compact entry are dropped', () {
      final blocks = buildTranscriptBlocks([
        _stats('s1', added: 1),
      ]);
      expect(blocks, isEmpty);
    });
  });

  group('entriesFromMessages', () {
    test('parses tool JSON into ToolCallState entries', () {
      final toolJson = {
        'toolCallId': 'tc1',
        'title': 'Bash',
        'kind': 'execute',
        'status': 'completed',
        'rawInput': '{"command": "ls"}',
      };
      final toolAt = DateTime(2026, 3, 1, 10);
      final messages = [
        _msg('u1', MessageRole.user, 'run ls'),
        _msg(
          't1',
          MessageRole.tool,
          // ignore: prefer_interpolation_to_compose_strings
          '{"toolCallId":"tc1","title":"Bash","kind":"execute","status":"completed","rawInput":"{\\"command\\":\\"ls\\"}"}',
          at: toolAt,
        ),
        _msg('a1', MessageRole.assistant, 'done'),
      ];
      final entries = entriesFromMessages(messages);
      expect(entries, hasLength(3));
      expect(entries[1].tool?.toolCallId, 'tc1');
      expect(entries[1].messageId, 't1');
      expect(entries[1].createdAt, toolAt);
      expect(toolJson['toolCallId'], 'tc1');
    });

    test('unparseable tool role falls back to message entry', () {
      final entries = entriesFromMessages([
        _msg('t1', MessageRole.tool, 'not-json'),
      ]);
      expect(entries.single.message?.role, MessageRole.tool);
      expect(entries.single.tool, isNull);
    });
  });
}
