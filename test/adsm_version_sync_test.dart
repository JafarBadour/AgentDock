import 'dart:io';

import 'package:agentplantation/services/adsm_version.dart';
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

  test('every Archon module is uploaded to the host', () {
    // Being listed in the app's assets only puts a module *in the app*. The
    // upload has its own list, and a module missing from it reaches no host —
    // which is how Archon came to read its skill, run `archon agents` exactly
    // as told, and be answered with "command not found".
    final ssh = File('lib/services/ssh_service.dart').readAsStringSync();
    final block = RegExp(
      r'_bundledArchonFiles = <String>\[(.*?)\]',
      dotAll: true,
    ).firstMatch(ssh);
    expect(block, isNotNull, reason: 'no _bundledArchonFiles list');
    final uploaded = RegExp(r"'(\w+\.py)'")
        .allMatches(block!.group(1)!)
        .map((m) => m.group(1))
        .toSet();
    final onDisk = Directory('host/archon')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.py'))
        .toSet();
    expect(
      onDisk.difference(uploaded),
      isEmpty,
      reason: 'add the new Archon module to _bundledArchonFiles in ssh_service',
    );
  });

  test('every Archon module is shipped too', () {
    // Archon rides the same upload as ADSM; a module left out of the assets
    // reaches no host, and the failure looks like Archon simply not working.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final shipped = RegExp(r'host/archon/(\w+\.py)')
        .allMatches(pubspec)
        .map((m) => m.group(1))
        .toSet();
    final needed = Directory('host/archon')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.py'))
        .toSet();
    expect(
      needed.difference(shipped),
      isEmpty,
      reason: 'add the new Archon module to pubspec.yaml assets',
    );
  });

  /// The method set the daemon answers, recorded against the VERSION that
  /// first answered it. Add a method and this map no longer describes the
  /// daemon, so the only way to make it true again is a new entry under a new
  /// VERSION — which is the bump that makes hosts actually receive the code.
  ///
  /// Keeping the numbers in sync is not enough on its own: `archon.relay`
  /// shipped while both sides read 0.7.2, so every host already at 0.7.2 was
  /// judged up to date and never got the daemon that could answer it. Archon
  /// then reported "no route", which reads as "no app is connected" rather
  /// than "this host is stale".
  const methodsByVersion = <String, List<String>>{
    '0.7.4': [
      'agents.delete',
      'agents.ensure',
      'agents.list',
      'agents.stop',
      'archon.log',
      'archon.relay',
      'archon.reply',
      'archon.routes',
      'chats.fork',
      'chats.notify',
      'daemon.shutdown',
      'daemon.status',
      'ping',
      'schedules.delete',
      'schedules.list',
      'schedules.run_now',
      'schedules.upsert',
      'session.cancel',
      'session.prompt',
      'session.refresh_models',
      'session.respond_permission',
      'session.set_mode',
      'session.set_model',
      'session.subscribe',
      'transcript.pull',
      'transcript.sync',
    ],
  };

  test('the daemon RPC surface is pinned to the declared VERSION', () {
    final daemon = File('host/adsm/daemon.py').readAsStringSync();
    final actual = RegExp(r'''method == ["']([a-z_.]+)["']''')
        .allMatches(daemon)
        .map((m) => m.group(1)!)
        .toSet();
    expect(actual, isNotEmpty, reason: 'no dispatch found in daemon.py');

    final pinned = methodsByVersion[kRequiredAdsmVersion];
    expect(
      pinned,
      isNotNull,
      reason:
          'No method list recorded for v$kRequiredAdsmVersion. The daemon RPC '
          'surface changed, so bump host/adsm/protocol.py VERSION and '
          'kRequiredAdsmVersion and record the new list here — otherwise every '
          'host already on the old version is treated as up to date and never '
          'receives the new daemon.',
    );
    expect(
      actual,
      pinned!.toSet(),
      reason:
          'The daemon answers a different set of methods than v'
          '$kRequiredAdsmVersion records. Bump the version and add a new '
          'entry to methodsByVersion; editing the current entry in place '
          'leaves provisioned hosts on a daemon that answers -32601.',
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
