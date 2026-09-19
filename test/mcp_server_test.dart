import 'package:agent_dock/data/models/mcp_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ACP HTTP config uses header name/value arrays', () {
    final mcp = McpServer(
      id: '1',
      name: 'saisher',
      transport: McpTransport.http,
      url: 'https://saisher.com/mcp',
      env: const {'Authorization': 'Bearer x'},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    expect(
      mcp.toAcpConfig(),
      {
        'type': 'http',
        'name': 'saisher',
        'url': 'https://saisher.com/mcp',
        'headers': [
          {'name': 'Authorization', 'value': 'Bearer x'},
        ],
      },
    );
  });

  test('ACP stdio config omits type and uses env name/value arrays', () {
    final mcp = McpServer(
      id: '2',
      name: 'fs',
      transport: McpTransport.stdio,
      command: 'npx',
      args: const ['-y', 'server'],
      env: const {'FOO': 'bar'},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    expect(
      mcp.toAcpConfig(),
      {
        'name': 'fs',
        'command': 'npx',
        'args': ['-y', 'server'],
        'env': [
          {'name': 'FOO', 'value': 'bar'},
        ],
      },
    );
  });

  test('HTTP MCP entries for Cursor and Claude', () {
    final mcp = McpServer(
      id: '1',
      name: 'saisher',
      transport: McpTransport.http,
      url: 'https://saisher.com/mcp',
      env: const {'Authorization': 'Bearer x'},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    expect(
      mcp.toMcpJsonEntry(),
      {
        'url': 'https://saisher.com/mcp',
        'headers': {'Authorization': 'Bearer x'},
      },
    );
    expect(
      mcp.toClaudeMcpJsonEntry(),
      {
        'type': 'http',
        'url': 'https://saisher.com/mcp',
        'headers': {'Authorization': 'Bearer x'},
      },
    );
  });

  test('stdio MCP entries for Claude include type', () {
    final mcp = McpServer(
      id: '2',
      name: 'fs',
      transport: McpTransport.stdio,
      command: 'npx',
      args: const ['-y', 'server'],
      createdAt: DateTime.utc(2026, 1, 1),
    );
    expect(mcp.toClaudeMcpJsonEntry()['type'], 'stdio');
    expect(mcp.toMcpJsonEntry().containsKey('type'), isFalse);
  });

  test('Codex TOML fragment for HTTP includes headers', () {
    final mcp = McpServer(
      id: '1',
      name: 'saisher',
      transport: McpTransport.http,
      url: 'https://saisher.com/mcp',
      env: const {'Authorization': 'Bearer x'},
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final toml = mcp.toCodexTomlFragment();
    expect(toml, contains('[mcp_servers.saisher]'));
    expect(toml, contains('url = "https://saisher.com/mcp"'));
    expect(toml, contains('[mcp_servers.saisher.http_headers]'));
    expect(toml, contains('Authorization = "Bearer x"'));
  });

  test('Codex TOML fragment for stdio', () {
    final mcp = McpServer(
      id: '2',
      name: 'fs',
      transport: McpTransport.stdio,
      command: 'npx',
      args: const ['-y', 'server'],
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final toml = mcp.toCodexTomlFragment();
    expect(toml, contains('command = "npx"'));
    expect(toml, contains('args = ["-y", "server"]'));
  });
}
