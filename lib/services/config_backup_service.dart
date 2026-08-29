import 'dart:convert';
import 'dart:io';

import '../data/local/app_database.dart';
import '../data/models/host.dart';
import '../data/models/mcp_server.dart';
import '../data/models/repo.dart';
import '../data/secure/safe_log.dart';

/// Portable config backup (`.ag` = JSON). Never includes SSH keys or API keys.
class ConfigBackupService {
  ConfigBackupService(this._db);

  final AppDatabase _db;

  static const formatId = 'agentic-phone';
  static const formatVersion = 1;

  Future<Map<String, dynamic>> buildExportMap() async {
    final hosts = await _db.listHosts();
    final repos = await _db.listRepos();
    final mcps = await _db.listMcpServers();
    final links = await _db.listMcpHostLinks();

    return {
      'format': formatId,
      'version': formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'hosts': hosts.map((h) => h.toMap()).toList(),
      'repos': repos.map((r) => r.toMap()).toList(),
      'mcpServers': mcps.map((m) {
        final map = Map<String, Object?>.from(m.toMap());
        // Never export env secrets — keep keys as empty placeholders if any.
        if (m.env.isNotEmpty) {
          map['env_json'] = jsonEncode(
            m.env.map((k, _) => MapEntry(k, '')),
          );
        }
        return map;
      }).toList(),
      'mcpHostLinks': links.map((l) {
        // Reset install status on other devices.
        return {
          'mcp_id': l.mcpId,
          'host_id': l.hostId,
          'enabled': l.enabled ? 1 : 0,
          'install_status': McpHostInstallStatus.pending.name,
          'install_detail': null,
        };
      }).toList(),
    };
  }

  Future<String> exportToFile(String path) async {
    final map = await buildExportMap();
    final json = const JsonEncoder.withIndent('  ').convert(map);
    final file = File(path.endsWith('.ag') ? path : '$path.ag');
    await file.writeAsString(json, flush: true);
    return file.path;
  }

  /// Merge config from a `.ag` / JSON file. Does not touch secrets.
  Future<ConfigImportResult> importFromFile(String path) async {
    final raw = await File(path).readAsString();
    return importFromJson(raw);
  }

  Future<ConfigImportResult> importFromJson(String raw) async {
    late final Map<String, dynamic> root;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Root must be a JSON object');
      }
      root = Map<String, dynamic>.from(decoded);
    } catch (e) {
      throw FormatException('Invalid .ag file: $e');
    }

    final format = root['format']?.toString();
    if (format != null && format != formatId) {
      throw FormatException('Unknown format "$format" (expected $formatId)');
    }

    var hostsN = 0;
    var reposN = 0;
    var mcpsN = 0;
    var linksN = 0;

    final hostsRaw = root['hosts'];
    if (hostsRaw is List) {
      // Upsert jump hosts first: sort so parents (no jump) come first, then dependents.
      final parsed = <Host>[];
      for (final item in hostsRaw) {
        if (item is! Map) continue;
        parsed.add(Host.fromMap(Map<String, Object?>.from(item)));
      }
      parsed.sort((a, b) {
        final aj = a.jumpHostId == null ? 0 : 1;
        final bj = b.jumpHostId == null ? 0 : 1;
        return aj.compareTo(bj);
      });
      for (final host in parsed) {
        await _db.upsertHost(host);
        hostsN++;
      }
    }

    final reposRaw = root['repos'];
    if (reposRaw is List) {
      for (final item in reposRaw) {
        if (item is! Map) continue;
        final repo = Repo.fromMap(Map<String, Object?>.from(item));
        await _db.upsertRepo(repo);
        reposN++;
      }
    }

    final mcpsRaw = root['mcpServers'];
    if (mcpsRaw is List) {
      for (final item in mcpsRaw) {
        if (item is! Map) continue;
        final mcp = McpServer.fromMap(Map<String, Object?>.from(item));
        await _db.upsertMcpServer(mcp);
        mcpsN++;
      }
    }

    final linksRaw = root['mcpHostLinks'];
    if (linksRaw is List) {
      for (final item in linksRaw) {
        if (item is! Map) continue;
        final link = McpHostLink.fromMap(Map<String, Object?>.from(item));
        await _db.upsertMcpHostLink(link);
        linksN++;
      }
    }

    SafeLog.d('Imported .ag hosts=$hostsN repos=$reposN mcps=$mcpsN links=$linksN');
    return ConfigImportResult(
      hosts: hostsN,
      repos: reposN,
      mcpServers: mcpsN,
      mcpHostLinks: linksN,
    );
  }
}

class ConfigImportResult {
  const ConfigImportResult({
    required this.hosts,
    required this.repos,
    required this.mcpServers,
    required this.mcpHostLinks,
  });

  final int hosts;
  final int repos;
  final int mcpServers;
  final int mcpHostLinks;

  String get summary =>
      'Imported $hosts host(s), $repos repo(s), $mcpServers MCP(s), $mcpHostLinks link(s). '
      'SSH keys are not included — add them in Connect.';
}
