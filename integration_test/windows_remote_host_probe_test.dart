import 'dart:io';

import 'package:agentplantation/data/local/app_database.dart';
import 'package:agentplantation/data/models/host.dart';
import 'package:agentplantation/data/secure/secure_store.dart';
import 'package:agentplantation/services/adsm_client.dart';
import 'package:agentplantation/services/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Connects to this Windows PC the way another device does: over SSH through
/// a bastion, running the steps a chat connect runs, in order.
///
///   flutter test integration_test/windows_remote_host_probe_test.dart -d windows \
///     --dart-define=PROBE_DB=C:/path/to/copy/of/agentic_phone.db \
///     --dart-define=PROBE_JUMP=<jump host id> --dart-define=PROBE_PORT=47613
///
/// Point PROBE_DB at a *copy* of the app database. ADSM is never upgraded
/// here: that restarts the daemon and ends every agent on the PC.
const _db = String.fromEnvironment('PROBE_DB');
const _jump = String.fromEnvironment('PROBE_JUMP');
const _port = int.fromEnvironment('PROBE_PORT', defaultValue: 22);
const _user = String.fromEnvironment('PROBE_USER', defaultValue: 'jafer');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  testWidgets('a Windows host behind a bastion', (tester) async {
    await tester.runAsync(() async {
      final db = AppDatabase(overridePath: _db);
      final host = Host(
        id: 'probe-windows-remote',
        alias: 'Windows via bastion (probe)',
        hostname: 'localhost',
        port: _port,
        username: _user,
        jumpHostId: _jump,
        createdAt: DateTime.now(),
      );
      await db.upsertHost(host);
      final ssh = SshService(SecureStore(), db);
      final failures = <String>[];

      Future<void> step(String name, Future<Object?> Function() run) async {
        try {
          final out = await run().timeout(const Duration(minutes: 2));
          // ignore: avoid_print
          print('PROBE $name: ok ${out ?? ''}');
        } catch (e) {
          failures.add(name);
          // ignore: avoid_print
          print('PROBE $name: FAILED $e');
        }
      }

      await step('windows', () => ssh.isWindowsRemote(host));
      await step('tmux', () => ssh.ensureTmux(host).then((_) => 'skipped'));
      await step('claude', () => ssh.ensureClaudeAcpBinary(host));
      await step(
        'adsm',
        () => ssh.ensureAdsm(host, allowUpgrade: false).then((_) => 'ready'),
      );
      await step('ping', () async {
        final c = await AdsmClient.connect(ssh, host);
        final v = c.protocolVersion;
        await c.close();
        return 'v$v';
      });
      await db.deleteHost(host.id);
      ssh.closeAll();
      expect(failures, isEmpty);
    });
  });
}
