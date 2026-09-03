import 'package:agent_dock/data/models/explore_stats.dart';
import 'package:agent_dock/data/models/tool_call_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExploreStats.fromTools', () {
    test('counts distinct reads and search tools', () {
      final stats = ExploreStats.fromTools([
        const ToolCallState(
          toolCallId: 'r1',
          title: 'Read',
          kind: 'read',
          locations: ['lib/a.dart'],
        ),
        const ToolCallState(
          toolCallId: 'r2',
          title: 'Read',
          kind: 'read_file',
          rawInput: '{"path":"lib/b.dart"}',
        ),
        const ToolCallState(
          toolCallId: 'r3',
          title: 'Read',
          kind: 'read',
          locations: ['lib/a.dart'],
        ),
        const ToolCallState(
          toolCallId: 'g1',
          title: 'Grep',
          kind: 'grep',
          rawInput: '{"pattern":"foo"}',
        ),
        const ToolCallState(
          toolCallId: 'g2',
          title: 'Glob',
          kind: 'glob',
          rawInput: '{"glob_pattern":"**/*.dart"}',
        ),
        const ToolCallState(
          toolCallId: 'e1',
          title: 'Edit',
          kind: 'edit',
          locations: ['lib/a.dart'],
        ),
      ]);
      expect(stats.fileCount, 2);
      expect(stats.searchCount, 2);
      expect(stats.label, 'Exploring 2 φ, 2 🔍');
    });

    test('ignores web search as code explore', () {
      final stats = ExploreStats.fromTools([
        const ToolCallState(
          toolCallId: 'w1',
          title: 'WebSearch',
          kind: 'web_search',
        ),
      ]);
      expect(stats.isEmpty, isTrue);
    });
  });
}
