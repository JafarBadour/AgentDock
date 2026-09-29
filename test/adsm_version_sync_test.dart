import 'dart:io';

import 'package:agent_dock/services/adsm_version.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app ships `host/adsm/` as assets and uploads it to a host only when the
/// host reports an older version than [kRequiredAdsmVersion]. So adding an RPC
/// to the daemon without bumping both numbers leaves every already-provisioned
/// host on the old code, answering the new method with -32601. That is exactly
/// how `chats.fork` shipped dead.
void main() {
  test('kRequiredAdsmVersion matches host/adsm/protocol.py', () {
    final source = File('host/adsm/protocol.py').readAsStringSync();
    final match = RegExp(
      r'''^VERSION\s*=\s*["']([^"']+)["']''',
      multiLine: true,
    ).firstMatch(source);
    expect(match, isNotNull, reason: 'no VERSION in host/adsm/protocol.py');
    expect(
      match!.group(1),
      kRequiredAdsmVersion,
      reason:
          'Bump host/adsm/protocol.py VERSION and kRequiredAdsmVersion '
          'together, or hosts never receive the new daemon.',
    );
  });

  test('every daemon RPC method is reachable from a bundled asset', () {
    // The daemon is only as deployable as the file list in pubspec.yaml.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final shipped = RegExp(r'host/adsm/(\w+\.py)')
        .allMatches(pubspec)
        .map((m) => m.group(1))
        .toSet();
    final needed = Directory('host/adsm')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.py') && !n.startsWith('test_'))
        .toSet();
    expect(
      needed.difference(shipped),
      isEmpty,
      reason: 'add the new daemon module to pubspec.yaml assets',
    );
  });
}
