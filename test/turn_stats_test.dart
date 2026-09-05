import 'package:agent_dock/data/models/code_change_stats.dart';
import 'package:agent_dock/data/models/turn_stats_message.dart';
import 'package:agent_dock/services/cursor_acp_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TurnStatsMessage', () {
    test('round-trips code + tokens', () {
      final encoded = TurnStatsMessage.encode(
        added: 12,
        removed: 3,
        files: 2,
        tokensUsed: 53000,
        contextSize: 200000,
      );
      expect(encoded, startsWith(TurnStatsMessage.marker));
      final parsed = TurnStatsMessage.tryParse(encoded);
      expect(parsed, isNotNull);
      expect(parsed!.added, 12);
      expect(parsed.removed, 3);
      expect(parsed.files, 2);
      expect(parsed.tokensUsed, 53000);
      expect(parsed.contextSize, 200000);
      expect(parsed.hasCodeDelta, isTrue);
      expect(parsed.hasTokens, isTrue);
    });

    test('empty when all zero and no tokens', () {
      expect(const TurnStats().isEmpty, isTrue);
      expect(
        TurnStatsMessage.tryParse(TurnStatsMessage.encode())!.isEmpty,
        isTrue,
      );
    });

    test('mergeComputed prefers persisted code when present', () {
      const persisted = TurnStats(added: 1, removed: 1, files: 1, tokensUsed: 9);
      final merged = persisted.mergeComputed(
        const CodeChangeStats(added: 99, removed: 99, files: {'a'}),
      );
      expect(merged.added, 1);
      expect(merged.tokensUsed, 9);
    });

    test('mergeComputed fills code when persisted had none', () {
      const persisted = TurnStats(tokensUsed: 100);
      final merged = persisted.mergeComputed(
        const CodeChangeStats(added: 5, removed: 2, files: {'a', 'b'}),
      );
      expect(merged.added, 5);
      expect(merged.removed, 2);
      expect(merged.files, 2);
      expect(merged.tokensUsed, 100);
    });
  });

  group('usage_update parsing', () {
    test('usage_update becomes AcpUpdate.usage', () {
      final update = AcpUpdate.fromParams({
        'sessionUpdate': 'usage_update',
        'used': 53000,
        'size': 200000,
      });
      expect(update.kind, AcpUpdateKind.usage);
      expect(update.tokensUsed, 53000);
      expect(update.contextSize, 200000);
    });

    test('usageUpdate camelCase works', () {
      final update = AcpUpdate.fromParams({
        'sessionUpdate': 'usageUpdate',
        'used': 10,
        'size': 100,
      });
      expect(update.kind, AcpUpdateKind.usage);
      expect(update.tokensUsed, 10);
    });

    test('incomplete usage is ignored', () {
      final update = AcpUpdate.fromParams({
        'sessionUpdate': 'usage_update',
        'used': 10,
      });
      expect(update.kind, AcpUpdateKind.ignored);
    });
  });
}
