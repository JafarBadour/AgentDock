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
      expect(adsmVersionMeets('0.4.2', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.4.14', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.4.15', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.4.18', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.4.20', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.4.19', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.5.0', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.6.0', kRequiredAdsmVersion), isFalse);
      // 0.7.1 carries the transcript.pull pivot fix, so 0.7.0 is stale.
      expect(adsmVersionMeets('0.7.0', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.7.1', kRequiredAdsmVersion), isFalse);
      // 0.7.3 is the first daemon that answers `archon.relay`. 0.7.2 shipped
      // on main without it, so a host reporting 0.7.2 must read as stale —
      // treating it as current is what left Archon with no route.
      expect(adsmVersionMeets('0.7.2', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.7.3', kRequiredAdsmVersion), isTrue);
    });

    test('wire chunks gate at 0.4.2', () {
      expect(adsmSupportsWireChunks(null), isFalse);
      expect(adsmSupportsWireChunks('0.4.1'), isFalse);
      expect(adsmSupportsWireChunks('0.4.2'), isTrue);
      expect(adsmSupportsWireChunks('1.0.0'), isTrue);
    });

    test('required version matches protocol bump', () {
      expect(kRequiredAdsmVersion, '0.7.3');
    });
  });
}
