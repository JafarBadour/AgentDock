import 'dart:io';

import 'package:agent_dock/data/local/app_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('upgrade tolerates a schema already ahead of user_version', () async {
    // Seen on a Windows install: the file already carried every v20 column
    // and table, but PRAGMA user_version was left at 15. The plain
    // `ALTER TABLE ... ADD COLUMN targets_json` in the <16 step then threw
    // "duplicate column name" on every launch and the upgrade never landed.
    final dir = await Directory.systemTemp.createTemp('agentdock-migrate');
    final path = p.join(dir.path, 'stale.db');
    addTearDown(() => dir.delete(recursive: true));

    // Build the full current schema, then rewind the version stamp.
    final fresh = await AppDatabase(overridePath: path).database;
    await fresh.execute('PRAGMA user_version = 15');
    await fresh.close();

    final reopened = await AppDatabase(overridePath: path).database;
    final version = await reopened.rawQuery('PRAGMA user_version');
    expect(version.single.values.single, 20);

    final cols = await reopened.rawQuery('PRAGMA table_info(mcp_host_links)');
    expect(cols.where((c) => c['name'] == 'targets_json'), hasLength(1));
    await reopened.close();
  });
}
