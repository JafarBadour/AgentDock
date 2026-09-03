import 'package:agent_dock/data/models/tool_call_state.dart';
import 'package:flutter_test/flutter_test.dart';

ToolCallState _tool({String title = 'Tool', String? kind, String? input}) {
  return ToolCallState(
    toolCallId: 't1',
    title: title,
    kind: kind,
    rawInput: input,
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
  });

  group('displayTitle', () {
    test('a missing title becomes a verb phrase from the kind', () {
      expect(_tool(kind: 'execute').displayTitle, 'Ran a command');
      expect(_tool(kind: 'read_file').displayTitle, 'Read a file');
      expect(_tool(kind: 'grep').displayTitle, 'Searched the code');
      expect(_tool(kind: 'search').displayTitle, 'Searched the code');
      expect(_tool(kind: 'web_search').displayTitle, 'Web search');
      expect(_tool(kind: 'WebFetch').displayTitle, 'Fetched a URL');
      expect(_tool(kind: null).displayTitle, 'Tool call');
    });

    test('a real title from the agent is preserved', () {
      expect(
        _tool(title: 'Read chat_screen.dart', kind: 'read').displayTitle,
        'Read chat_screen.dart',
      );
    });
  });
}
