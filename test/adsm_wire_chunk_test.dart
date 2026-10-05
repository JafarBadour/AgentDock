import 'package:agentplantation/services/adsm_version.dart';
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
      // 0.7.2 exits when its server fails to start, so 0.7.1 is stale.
      expect(adsmVersionMeets('0.7.1', kRequiredAdsmVersion), isFalse);
      // 0.7.3 is the first daemon that answers `archon.relay`. 0.7.2 shipped
      // on main without it, so a host reporting 0.7.2 must read as stale —
      // treating it as current is what left Archon with no route.
      expect(adsmVersionMeets('0.7.2', kRequiredAdsmVersion), isFalse);
      // 0.7.4 renames the product in the daemon's own user-visible messages,
      // which only reach a host when the version says the host is behind.
      expect(adsmVersionMeets('0.7.3', kRequiredAdsmVersion), isFalse);
      // 0.7.5 replays the user's own turns into a restored session and stops
      // re-imports duplicating the transcript. A host left on 0.7.4 keeps
      // answering its own old output instead of the message just sent.
      expect(adsmVersionMeets('0.7.4', kRequiredAdsmVersion), isFalse);
      // 0.7.6 adds `archon remote read`. The command lives in the archon
      // package on the host, which rides the same version-gated upload, so a
      // host left on 0.7.5 has no way to read a remote agent before driving
      // it — which is the whole point of the command.
      expect(adsmVersionMeets('0.7.5', kRequiredAdsmVersion), isFalse);
      // 0.7.7 makes `archon goals` look past this host. The command and the
      // skill that explains it both live in the archon package, so a host
      // left on 0.7.6 keeps reporting no managed agents however many the
      // user has switched on in the app.
      expect(adsmVersionMeets('0.7.6', kRequiredAdsmVersion), isFalse);
      expect(adsmVersionMeets('0.7.7', kRequiredAdsmVersion), isTrue);
    });

    test('wire chunks gate at 0.4.2', () {
      expect(adsmSupportsWireChunks(null), isFalse);
      expect(adsmSupportsWireChunks('0.4.1'), isFalse);
      expect(adsmSupportsWireChunks('0.4.2'), isTrue);
      expect(adsmSupportsWireChunks('1.0.0'), isTrue);
    });

    test('required version matches protocol bump', () {
      expect(kRequiredAdsmVersion, '0.7.7');
    });
  });
}
