import 'package:agent_dock/data/local/app_database.dart';
import 'package:agent_dock/data/models/mcp_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(overridePath: inMemoryDatabasePath);
  });

  test('dedupeMcpServersByName keeps configured row and drops stubs', () async {
    final raw = await db.database;
    await raw.execute('DROP INDEX IF EXISTS idx_mcp_servers_name_unique');

    Future<void> insert(McpServer m) async {
      await raw.insert('mcp_servers', m.toMap());
    }

    await insert(
      McpServer(
        id: 'cfg',
        name: 'veena-mcp',
        transport: McpTransport.http,
        url: 'https://example.com/mcp',
        createdAt: DateTime.utc(2026, 1, 1),
      ),
    );
    await insert(
      McpServer(
        id: 's1',
        name: 'veena-mcp',
        transport: McpTransport.http,
        createdAt: DateTime.utc(2026, 1, 2),
      ),
    );
    await insert(
      McpServer(
        id: 's2',
        name: 'Veena-MCP',
        transport: McpTransport.http,
        createdAt: DateTime.utc(2026, 1, 3),
      ),
    );

    final removed = await db.dedupeMcpServersByName();
    expect(removed, 2);

    final left = await raw.query('mcp_servers');
    expect(left, hasLength(1));
    expect(left.single['id'], 'cfg');
    expect(left.single['url'], 'https://example.com/mcp');
  });
}
