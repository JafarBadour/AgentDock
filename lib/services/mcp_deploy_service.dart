import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../data/local/app_database.dart';
import '../data/models/host.dart';
import '../data/models/mcp_server.dart';
import '../data/secure/safe_log.dart';
import 'ssh_service.dart';

/// Installs / removes MCP definitions on remotes via SSH (background-friendly).
class McpDeployService {
  McpDeployService(this._ssh, this._db);

  final SshService _ssh;
  final AppDatabase _db;

  /// Merge [mcp] into `~/.cursor/mcp.json` on [host] and try `agent mcp enable`.
  Future<McpHostLink> deployToHost({
    required McpServer mcp,
    required Host host,
  }) async {
    var link = McpHostLink(
      mcpId: mcp.id,
      hostId: host.id,
      enabled: true,
      installStatus: McpHostInstallStatus.installing,
      installDetail: 'Writing ~/.cursor/mcp.json…',
    );
    await _db.upsertMcpHostLink(link);

    try {
      final client = await _ssh.connect(host);
      try {
        final homeOut = await _run(client, r'printf %s "$HOME"');
        final home = homeOut.trim().isEmpty ? '.' : homeOut.trim();
        final dir = '$home/.cursor';
        final path = '$dir/mcp.json';

        await _run(client, 'mkdir -p ${SshService.shellQuote(dir)}');

        Map<String, dynamic> root = {'mcpServers': <String, dynamic>{}};
        try {
          final existing = await _run(
            client,
            'test -f ${SshService.shellQuote(path)} && cat ${SshService.shellQuote(path)} || true',
          );
          final trimmed = existing.trim();
          if (trimmed.isNotEmpty) {
            final decoded = jsonDecode(trimmed);
            if (decoded is Map<String, dynamic>) {
              root = decoded;
            } else if (decoded is Map) {
              root = Map<String, dynamic>.from(decoded);
            }
          }
        } catch (e) {
          SafeLog.d('read remote mcp.json failed; starting fresh', e);
        }

        final servers = <String, dynamic>{};
        final existingServers = root['mcpServers'];
        if (existingServers is Map) {
          existingServers.forEach((k, v) {
            servers[k.toString()] = v;
          });
        }
        servers[mcp.name] = mcp.toMcpJsonEntry();
        root['mcpServers'] = servers;

        final payload = const JsonEncoder.withIndent('  ').convert(root);
        final b64 = base64Encode(utf8.encode(payload));
        await _run(
          client,
          'printf %s ${SshService.shellQuote(b64)} | base64 -d > ${SshService.shellQuote(path)}',
        );

        var detail = 'Updated $path';
        try {
          final enableOut = await _run(
            client,
            'export PATH="\$HOME/.local/bin:\$HOME/.cursor/bin:\$PATH"; '
            '(command -v agent >/dev/null && agent mcp enable ${SshService.shellQuote(mcp.name)}) || '
            '(command -v cursor-agent >/dev/null && cursor-agent mcp enable ${SshService.shellQuote(mcp.name)}) || '
            'true',
            timeout: const Duration(seconds: 45),
          );
          final t = enableOut.trim();
          if (t.isNotEmpty) detail = '$detail\n$t';
        } catch (e) {
          SafeLog.d('agent mcp enable optional step failed', e);
          detail = '$detail\n(enable step skipped: $e)';
        }

        link = link.copyWith(
          installStatus: McpHostInstallStatus.installed,
          installDetail: detail,
        );
        await _db.upsertMcpHostLink(link);
        return link;
      } finally {
        client.close();
      }
    } catch (e) {
      SafeLog.d('MCP deploy failed', e);
      link = link.copyWith(
        installStatus: McpHostInstallStatus.failed,
        installDetail: e.toString(),
      );
      await _db.upsertMcpHostLink(link);
      return link;
    }
  }

  Future<McpHostLink> removeFromHost({
    required McpServer mcp,
    required Host host,
  }) async {
    var link = McpHostLink(
      mcpId: mcp.id,
      hostId: host.id,
      enabled: false,
      installStatus: McpHostInstallStatus.installing,
      installDetail: 'Removing from ~/.cursor/mcp.json…',
    );
    await _db.upsertMcpHostLink(link);

    try {
      final client = await _ssh.connect(host);
      try {
        final homeOut = await _run(client, r'printf %s "$HOME"');
        final home = homeOut.trim().isEmpty ? '.' : homeOut.trim();
        final path = '$home/.cursor/mcp.json';

        try {
          final existing = await _run(
            client,
            'test -f ${SshService.shellQuote(path)} && cat ${SshService.shellQuote(path)} || true',
          );
          final trimmed = existing.trim();
          if (trimmed.isNotEmpty) {
            final decoded = jsonDecode(trimmed);
            if (decoded is Map) {
              final root = Map<String, dynamic>.from(decoded);
              final servers = <String, dynamic>{};
              final existingServers = root['mcpServers'];
              if (existingServers is Map) {
                existingServers.forEach((k, v) {
                  if (k.toString() != mcp.name) servers[k.toString()] = v;
                });
              }
              root['mcpServers'] = servers;
              final payload = const JsonEncoder.withIndent('  ').convert(root);
              final b64 = base64Encode(utf8.encode(payload));
              await _run(
                client,
                'printf %s ${SshService.shellQuote(b64)} | base64 -d > ${SshService.shellQuote(path)}',
              );
            }
          }
        } catch (e) {
          SafeLog.d('remove mcp.json entry failed', e);
        }

        try {
          await _run(
            client,
            'export PATH="\$HOME/.local/bin:\$HOME/.cursor/bin:\$PATH"; '
            '(command -v agent >/dev/null && agent mcp disable ${SshService.shellQuote(mcp.name)}) || true',
            timeout: const Duration(seconds: 30),
          );
        } catch (_) {}

        link = link.copyWith(
          enabled: false,
          installStatus: McpHostInstallStatus.removed,
          installDetail: 'Removed ${mcp.name} from remote mcp.json',
        );
        await _db.upsertMcpHostLink(link);
        return link;
      } finally {
        client.close();
      }
    } catch (e) {
      link = link.copyWith(
        enabled: false,
        installStatus: McpHostInstallStatus.failed,
        installDetail: e.toString(),
      );
      await _db.upsertMcpHostLink(link);
      return link;
    }
  }

  Future<String> _run(
    SSHClient client,
    String command, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final session = await client.execute(command);
    final chunks = await Future.wait<Uint8List>([
      _readAll(session.stdout),
      _readAll(session.stderr),
    ]).timeout(timeout);
    await session.done.timeout(const Duration(seconds: 5));
    final code = session.exitCode ?? 0;
    if (code != 0) {
      final err = utf8.decode(chunks[1]).trim();
      throw Exception(err.isEmpty ? 'Remote command failed (exit $code)' : err);
    }
    return utf8.decode(chunks[0]);
  }

  Future<Uint8List> _readAll(Stream<Uint8List> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
