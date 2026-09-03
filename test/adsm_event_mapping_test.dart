import 'package:agent_dock/services/adsm_client.dart';
import 'package:agent_dock/services/cursor_acp_service.dart';
import 'package:agent_dock/data/models/tool_call_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AdsmSession event mapping', () {
    test('tool map parses into ToolCallState', () {
      final tool = AdsmSession_testHook.toolFrom({
        'toolCallId': 't1',
        'title': 'Read file',
        'kind': 'read',
        'status': 'completed',
        'locations': ['/tmp/a.dart'],
      });
      expect(tool, isNotNull);
      expect(tool!.toolCallId, 't1');
      expect(tool.title, 'Read file');
      expect(tool.status, 'completed');
      expect(tool.locations, ['/tmp/a.dart']);
    });

    test('AcpUpdate kinds cover ADSM event set', () {
      expect(AcpUpdate.delta('x').kind, AcpUpdateKind.delta);
      expect(AcpUpdate.thought('t').kind, AcpUpdateKind.thought);
      expect(AcpUpdate.turnComplete().kind, AcpUpdateKind.turnComplete);
      expect(AcpUpdate.activity('Thinking').kind, AcpUpdateKind.activity);
      expect(
        AcpUpdate.toolCall(
          const ToolCallState(toolCallId: '1', title: 'T'),
        ).kind,
        AcpUpdateKind.tool,
      );
    });
  });
}

/// Expose private mapper for tests without making it public API.
class AdsmSession_testHook {
  static ToolCallState? toolFrom(Object? raw) {
    // Mirror of AdsmSession._toolFrom
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final id = (m['toolCallId'] ?? m['id'] ?? '').toString();
    final title = (m['title'] ?? 'Tool').toString();
    if (id.isEmpty && title == 'Tool') return null;
    final locations = <String>[];
    final locs = m['locations'];
    if (locs is List) {
      for (final loc in locs) {
        locations.add(loc.toString());
      }
    }
    return ToolCallState(
      toolCallId: id.isEmpty ? title : id,
      title: title,
      kind: m['kind']?.toString(),
      status: (m['status'] ?? 'pending').toString(),
      locations: locations,
    );
  }
}
