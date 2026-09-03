import 'package:agent_dock/services/adsm_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('adsm version helpers', () {
    test('compare and meets', () {
      expect(compareAdsmVersions(null, '0.4.2'), lessThan(0));
      expect(compareAdsmVersions('0.4.1', '0.4.2'), lessThan(0));
      expect(compareAdsmVersions('0.4.2', '0.4.2'), 0);
      expect(compareAdsmVersions('0.5.0', '0.4.2'), greaterThan(0));
      expect(adsmVersionMeets('0.4.1', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.4.2', kRequiredAdsmVersion), isTrue);
    });

    test('wire chunks gate at 0.4.2', () {
      expect(adsmSupportsWireChunks(null), isFalse);
      expect(adsmSupportsWireChunks('0.4.1'), isFalse);
      expect(adsmSupportsWireChunks('0.4.2'), isTrue);
      expect(adsmSupportsWireChunks('1.0.0'), isTrue);
    });

    test('required version matches protocol bump', () {
      expect(kRequiredAdsmVersion, '0.4.2');
    });
  });
}
