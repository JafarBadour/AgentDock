@TestOn('windows')
library;

import 'dart:io';

import 'package:agentplantation/data/secure/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory support;
  late Directory secrets;
  late Directory legacy;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('secure_store_migration');
    support = Directory(p.join(root.path, 'AgentPlantation'));
    secrets = await Directory(p.join(support.path, 'secrets'))
        .create(recursive: true);
    legacy = await Directory(p.join(root.path, 'agent_dock', 'secrets'))
        .create(recursive: true);
  });

  tearDown(() => root.delete(recursive: true));

  String read(String name) =>
      File(p.join(secrets.path, name)).readAsStringSync();

  test('copies secrets from the pre-rename folder', () async {
    File(p.join(legacy.path, 'ssh_private_key')).writeAsStringSync('KEY');
    File(p.join(legacy.path, 'host_password_h1')).writeAsStringSync('pw');

    await SecureStore.migrateLegacyWindowsSecrets(support, secrets);

    expect(read('ssh_private_key'), 'KEY');
    expect(read('host_password_h1'), 'pw');
  });

  test('keeps secrets already saved under the new name', () async {
    File(p.join(legacy.path, 'ssh_private_key')).writeAsStringSync('OLD');
    File(p.join(secrets.path, 'ssh_private_key')).writeAsStringSync('NEW');

    await SecureStore.migrateLegacyWindowsSecrets(support, secrets);

    expect(read('ssh_private_key'), 'NEW');
  });

  test('runs once, so a later delete is not undone', () async {
    File(p.join(legacy.path, 'ssh_private_key')).writeAsStringSync('KEY');
    await SecureStore.migrateLegacyWindowsSecrets(support, secrets);

    File(p.join(secrets.path, 'ssh_private_key')).deleteSync();
    await SecureStore.migrateLegacyWindowsSecrets(support, secrets);

    expect(File(p.join(secrets.path, 'ssh_private_key')).existsSync(), isFalse);
  });
}
