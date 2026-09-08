import 'package:agent_dock/data/models/tool_call_state.dart';
import 'package:flutter_test/flutter_test.dart';

ToolCallState _tool({
  String title = 'Tool',
  String? kind,
  String? input,
  String status = 'pending',
  String? output,
  String? content,
  List<String> locations = const [],
}) {
  return ToolCallState(
    toolCallId: 't1',
    title: title,
    kind: kind,
    status: status,
    rawInput: input,
    rawOutput: output,
    content: content,
    locations: locations,
  );
}

void main() {
  group('preview', () {
    test('pretty-printed JSON does not surface a bare brace', () {
      final tool = _tool(
        kind: 'execute',
        input: '{\n  "command": "git status --short",\n  "cwd": "/repo"\n}',
      );

      expect(tool.preview, 'git status --short');
    });

    test('picks the most specific key available', () {
      expect(
        _tool(kind: 'search', input: '{"path": "/repo", "query": "TODO"}')
            .preview,
        'TODO',
      );
      expect(_tool(kind: 'read', input: '{"path": "/repo/main.dart"}').preview,
          '/repo/main.dart');
    });

    test('a known path wins over anything in the input', () {
      const tool = ToolCallState(
        toolCallId: 't1',
        title: 'Read',
        locations: ['lib/main.dart'],
        rawInput: '{"command": "cat lib/main.dart"}',
      );
      expect(tool.preview, 'lib/main.dart');
    });

    test('non-JSON input falls back to its first meaningful line', () {
      expect(_tool(input: '\n\n  npm test  \nmore output').preview, 'npm test');
    });

    test('unparseable JSON falls back without a bare brace', () {
      expect(_tool(input: '{"command": broken').preview, '{"command": broken');
    });

    test('pretty-printed JSON with no useful keys yields no preview', () {
      expect(_tool(input: '{\n  "foo": 1\n}').preview, isNull);
    });

    test('long previews are clipped', () {
      final tool = _tool(input: '{"command": "${'x' * 400}"}');
      expect(tool.preview!.length, lessThanOrEqualTo(100));
      expect(tool.preview, endsWith('…'));
    });

    test('multi-line values collapse to one line', () {
      expect(
        _tool(input: '{"command": "line one\\n   line two"}').preview,
        'line one line two',
      );
    });

    test('empty / null input yields null', () {
      expect(_tool(input: null).preview, isNull);
      expect(_tool(input: '   ').preview, isNull);
    });

    test('JSON array uses first object', () {
      expect(
        _tool(input: '[{"command": "echo hi"}, {"command": "other"}]').preview,
        'echo hi',
      );
    });

    test('list-valued preview keys join', () {
      expect(
        _tool(input: '{"path": ["a.dart", "b.dart"]}').preview,
        'a.dart b.dart',
      );
    });

    test('huge rawInput is only scanned at the head (still finds command)', () {
      final huge = '{"command": "ok", "blob": "${'z' * 20000}"}';
      expect(_tool(input: huge).preview, 'ok');
    });

    test('preview is cached on the same instance', () {
      final tool = _tool(input: '{"command": "once"}');
      expect(tool.preview, 'once');
      expect(tool.preview, 'once'); // second hit uses Expando cache
    });
  });

  group('displayTitle', () {
    test('a missing title becomes a verb phrase from the kind', () {
      expect(_tool(kind: 'execute').displayTitle, 'Ran a command');
      expect(_tool(kind: 'read_file').displayTitle, 'Read a file');
      expect(_tool(kind: 'grep').displayTitle, 'Searched the code');
      expect(_tool(kind: 'search').displayTitle, 'Searched the code');
      expect(_tool(kind: 'web_search').displayTitle, 'Web search');
      expect(_tool(kind: 'WebFetch').displayTitle, 'Fetched a URL');
      expect(_tool(kind: 'delete_file').displayTitle, 'Deleted a file');
      expect(_tool(kind: 'edit_file').displayTitle, 'Edited a file');
      expect(_tool(kind: 'write').displayTitle, 'Edited a file');
      expect(_tool(kind: 'shell').displayTitle, 'Ran a command');
      expect(_tool(kind: 'terminal').displayTitle, 'Ran a command');
      expect(_tool(kind: 'browser').displayTitle, 'Web search');
      expect(_tool(kind: 'http').displayTitle, 'Fetched a URL');
      expect(_tool(kind: null).displayTitle, 'Tool call');
    });

    test('a real title from the agent is preserved', () {
      expect(
        _tool(title: 'Read chat_screen.dart', kind: 'read').displayTitle,
        'Read chat_screen.dart',
      );
    });

    test('literal Tool / JSON titles are treated as missing', () {
      expect(_tool(title: 'Tool', kind: 'read').displayTitle, 'Read a file');
      expect(_tool(title: 'tool', kind: 'read').displayTitle, 'Read a file');
      expect(
        _tool(title: '{"command":"x"}', kind: 'execute').displayTitle,
        'Ran a command',
      );
      expect(
        _tool(title: '["x"]', kind: 'read').displayTitle,
        'Read a file',
      );
    });

    test('does not scan an entire 100KB rawInput for classification', () {
      final huge = 'x' * 100000;
      final sw = Stopwatch()..start();
      final title = _tool(title: 'Tool', kind: 'execute', input: huge)
          .displayTitle;
      sw.stop();
      expect(title, 'Ran a command');
      expect(sw.elapsedMilliseconds, lessThan(50));
    });

    test('web search phrases inside input head', () {
      expect(
        _tool(
          title: 'Tool',
          kind: 'other',
          input: '{"query": "web search something"}',
        ).displayTitle,
        'Web search',
      );
    });
    test('polling wait uses description and Polling status', () {
      final t = _tool(
        title:
            'until grep -q "epoch" log; do sleep 30; done',
        kind: 'execute',
        status: 'in_progress',
        input:
            '{"command":"until grep -q epoch log; do sleep 30; done","description":"Waiting for first epoch"}',
      );
      expect(t.isPollingWait, isTrue);
      expect(t.statusLabel, 'Polling');
      expect(t.displayTitle, 'Waiting for first epoch');
    });

    test('polling wait without description still collapses', () {
      final t = _tool(
        title: 'until true; do sleep 30; done',
        kind: 'shell',
        status: 'running',
        input: '{"command":"until true; do sleep 30; done"}',
      );
      expect(t.isPollingWait, isTrue);
      expect(t.displayTitle, 'Waiting on remote job');
      expect(t.statusLabel, 'Polling');
    });
  });

  group('status flags', () {
    test('isActive covers pending / in_progress / running', () {
      expect(_tool(status: 'pending').isActive, isTrue);
      expect(_tool(status: 'in_progress').isActive, isTrue);
      expect(_tool(status: 'running').isActive, isTrue);
      expect(_tool(status: 'completed').isActive, isFalse);
      expect(_tool(status: 'failed').isActive, isFalse);
    });

    test('isCompleted covers completed / success / done', () {
      expect(_tool(status: 'completed').isCompleted, isTrue);
      expect(_tool(status: 'success').isCompleted, isTrue);
      expect(_tool(status: 'done').isCompleted, isTrue);
      expect(_tool(status: 'pending').isCompleted, isFalse);
    });

    test('isFailed covers failed / error', () {
      expect(_tool(status: 'failed').isFailed, isTrue);
      expect(_tool(status: 'error').isFailed, isTrue);
      expect(_tool(status: 'completed').isFailed, isFalse);
    });
  });

  group('soft / hard fail', () {
    test('non-failed is never soft or hard fail', () {
      expect(_tool(status: 'completed').isSoftFail, isFalse);
      expect(_tool(status: 'completed').isHardFail, isFalse);
    });

    test('exit code 1 is soft fail', () {
      final t = _tool(status: 'failed', output: 'exit code 1');
      expect(t.isSoftFail, isTrue);
      expect(t.isHardFail, isFalse);
      expect(t.statusLabel, 'Exit 1');
    });

    test('exact exit code 1 blob is soft fail', () {
      expect(
        _tool(status: 'failed', output: 'exit code 1').isSoftFail,
        isTrue,
      );
    });

    test('permission / denied / 127 / not found are hard fails', () {
      for (final blob in [
        'permission denied',
        'Access denied',
        'internal error',
        'exit code 127',
        'command not found',
      ]) {
        final t = _tool(status: 'failed', output: blob);
        expect(t.isSoftFail, isFalse, reason: blob);
        expect(t.isHardFail, isTrue, reason: blob);
      }
    });

    test('soft-fail scan caps huge outputs', () {
      final huge = '${'x' * 50000}\nexit code 1';
      // Exit code is past the 2000-char cap → not soft; still failed.
      final t = _tool(status: 'failed', output: huge);
      expect(t.isSoftFail, isFalse);
      expect(t.isHardFail, isTrue);
    });

    test('exit code 1 within first 2000 chars is soft', () {
      final t = _tool(
        status: 'failed',
        output: 'exit code 1\n${'y' * 50000}',
      );
      expect(t.isSoftFail, isTrue);
    });

    test('content channel can also trigger soft fail', () {
      expect(
        _tool(status: 'error', content: 'exit code 1').isSoftFail,
        isTrue,
      );
    });
  });

  group('statusLabel', () {
    test('maps known statuses', () {
      expect(_tool(status: 'running').statusLabel, 'Running');
      expect(_tool(status: 'in_progress').statusLabel, 'Running');
      expect(_tool(status: 'pending').statusLabel, 'Pending');
      expect(_tool(status: 'completed').statusLabel, 'Done');
      expect(_tool(status: 'success').statusLabel, 'Done');
      expect(_tool(status: 'done').statusLabel, 'Done');
      expect(_tool(status: 'failed', output: 'boom').statusLabel, 'Failed');
      expect(_tool(status: 'cancelled').statusLabel, 'Cancelled');
      expect(_tool(status: 'canceled').statusLabel, 'Cancelled');
      expect(_tool(status: 'weird').statusLabel, 'weird');
    });
  });

  group('merge / json', () {
    test('merge keeps non-empty title and status', () {
      final base = _tool(title: 'Old', status: 'pending', kind: 'read');
      final merged = base.merge(title: 'New', status: 'completed', kind: 'edit');
      expect(merged.title, 'New');
      expect(merged.status, 'completed');
      expect(merged.kind, 'edit');
      expect(merged.toolCallId, 't1');
    });

    test('merge ignores empty title / status overrides', () {
      final base = _tool(title: 'Keep', status: 'running');
      final merged = base.merge(title: '', status: '');
      expect(merged.title, 'Keep');
      expect(merged.status, 'running');
    });

    test('round-trip toJson / fromJson', () {
      final original = _tool(
        title: 'Bash',
        kind: 'execute',
        status: 'completed',
        input: '{"command":"ls"}',
        output: 'a\nb',
        locations: ['/tmp'],
      );
      final again = ToolCallState.fromJson(original.toJson());
      expect(again.toolCallId, original.toolCallId);
      expect(again.title, original.title);
      expect(again.kind, original.kind);
      expect(again.status, original.status);
      expect(again.rawInput, original.rawInput);
      expect(again.rawOutput, original.rawOutput);
      expect(again.locations, original.locations);
    });

    test('fromJson accepts id alias and defaults', () {
      final t = ToolCallState.fromJson({'id': 'x', 'title': 'T'});
      expect(t.toolCallId, 'x');
      expect(t.status, 'pending');
      expect(t.locations, isEmpty);
    });

    test('tryParseContent rejects non-JSON', () {
      expect(ToolCallState.tryParseContent('nope'), isNull);
      expect(ToolCallState.tryParseContent('[]'), isNull);
    });

    test('tryParseContent parses maps', () {
      final t = ToolCallState.tryParseContent(
        '{"toolCallId":"z","title":"Z","status":"done"}',
      );
      expect(t?.toolCallId, 'z');
      expect(t?.isCompleted, isTrue);
    });

    test('formatOpaque handles null / string / object', () {
      expect(ToolCallState.formatOpaque(null), isNull);
      expect(ToolCallState.formatOpaque('plain'), 'plain');
      expect(ToolCallState.formatOpaque({'a': 1}), contains('"a"'));
    });
  });
}
