import 'package:agent_dock/data/models/code_change_stats.dart';
import 'package:agent_dock/data/models/tool_call_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CodeChangeStats.fromTool', () {
    test('counts unified diff lines and files', () {
      const tool = ToolCallState(
        toolCallId: '1',
        title: 'Edit',
        kind: 'edit',
        rawOutput: '''
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,3 +1,4 @@
 line
-old
+new1
+new2
''',
      );
      final s = CodeChangeStats.fromTool(tool);
      expect(s.added, 2);
      expect(s.removed, 1);
      expect(s.fileCount, 1);
      expect(s.label, contains('+2'));
      expect(s.label, contains('-1'));
      expect(s.label, contains('φ'));
    });

    test('mergeDisplay keeps persisted totals when live is empty', () {
      final d = CodeChangeStats.mergeDisplay(
        live: const CodeChangeStats(),
        persistedAdded: 10,
        persistedRemoved: 3,
        persistedFiles: 5,
      );
      expect(d.added, 10);
      expect(d.removed, 3);
      expect(d.files, 5);
    });

    test('mergeDisplay prefers larger live totals', () {
      final d = CodeChangeStats.mergeDisplay(
        live: const CodeChangeStats(
          added: 40,
          removed: 1,
          files: {'a', 'b', 'c'},
        ),
        persistedAdded: 10,
        persistedRemoved: 3,
        persistedFiles: 2,
      );
      expect(d.added, 40);
      expect(d.removed, 3);
      expect(d.files, 3);
    });

    test('counts old_string / new_string replacements', () {
      const tool = ToolCallState(
        toolCallId: '2',
        title: 'StrReplace',
        kind: 'edit',
        rawInput: '''
{"path":"lib/foo.dart","old_string":"a\\nb\\nc","new_string":"a\\nb\\nc\\nd\\ne"}
''',
      );
      final s = CodeChangeStats.fromTool(tool);
      expect(s.removed, 3);
      expect(s.added, 5);
      expect(s.files, contains(contains('foo.dart')));
    });

    test('reads ACP content diff blocks', () {
      const tool = ToolCallState(
        toolCallId: '3',
        title: 'Apply',
        kind: 'edit',
        content: '''
[{"type":"diff","path":"src/main.ts","oldText":"one\\ntwo","newText":"one\\ntwo\\nthree"}]
''',
      );
      final s = CodeChangeStats.fromTool(tool);
      expect(s.removed, 2);
      expect(s.added, 3);
      expect(s.fileCount, 1);
    });

    test('ignores read tools', () {
      const tool = ToolCallState(
        toolCallId: '4',
        title: 'Read',
        kind: 'read',
        locations: ['lib/a.dart'],
        rawInput: '{"path":"lib/a.dart"}',
      );
      expect(CodeChangeStats.fromTool(tool).isEmpty, isTrue);
    });
  });
}
