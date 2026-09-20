import 'dart:convert';
import 'dart:io';

import '../data/local/app_database.dart';
import '../data/models/host.dart';
import '../data/models/mcp_server.dart';
import '../data/models/repo.dart';
import '../data/models/skill.dart';
import '../data/secure/safe_log.dart';

/// Portable config backup (`.ag` = JSON). Never includes SSH keys or API keys.
class ConfigBackupService {
  ConfigBackupService(this._db);

  final AppDatabase _db;

  static const formatId = 'agent-dock';
  static const legacyFormatId = 'agentic-phone';
  static const formatVersion = 1;

  Future<Map<String, dynamic>> buildExportMap() async {
    final hosts = await _db.listHosts();
    final repos = await _db.listRepos();
    final mcps = await _db.listMcpServers();
    final links = await _db.listMcpHostLinks();
    final skills = await _db.listSkills();
    final skillLinks = await _db.listSkillHostLinks();

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
      'skills': skills.map((s) => s.toMap()).toList(),
      'skillHostLinks': skillLinks.map((l) {
        return {
          'skill_id': l.skillId,
          'host_id': l.hostId,
          'enabled': l.enabled ? 1 : 0,
          'install_status': SkillHostInstallStatus.pending.name,
          'install_detail': null,
          'targets_json': jsonEncode(
            l.targets.map((t) => t.name).toList(),
          ),
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
    if (format != null && format != formatId && format != legacyFormatId) {
      throw FormatException('Unknown format "$format" (expected $formatId)');
    }

    var hostsN = 0;
    var reposN = 0;
    var mcpsN = 0;
    var linksN = 0;
    var skillsN = 0;
    var skillLinksN = 0;

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
        final existing = await _db.findMcpServerByName(mcp.name);
        if (existing != null && existing.id != mcp.id) {
          // Keep the richer definition under the stable local id.
          final preferIncoming =
              ((mcp.url ?? '').trim().isNotEmpty ||
                  (mcp.command ?? '').trim().isNotEmpty) &&
              ((existing.url ?? '').trim().isEmpty &&
                  (existing.command ?? '').trim().isEmpty);
          await _db.upsertMcpServer(
            preferIncoming
                ? McpServer(
                    id: existing.id,
                    name: mcp.name.trim(),
                    transport: mcp.transport,
                    command: mcp.command,
                    args: mcp.args,
                    url: mcp.url,
                    env: mcp.env,
                    createdAt: existing.createdAt,
                  )
                : existing,
          );
        } else {
          await _db.upsertMcpServer(
            McpServer(
              id: mcp.id,
              name: mcp.name.trim(),
              transport: mcp.transport,
              command: mcp.command,
              args: mcp.args,
              url: mcp.url,
              env: mcp.env,
              createdAt: mcp.createdAt,
            ),
          );
        }
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

    final skillsRaw = root['skills'];
    if (skillsRaw is List) {
      for (final item in skillsRaw) {
        if (item is! Map) continue;
        final skill = AgentSkill.fromMap(Map<String, Object?>.from(item));
        final existing = await _db.findSkillByName(skill.name);
        if (existing != null && existing.id != skill.id) {
          final preferIncoming = skill.bodyMarkdown.trim().length >
              existing.bodyMarkdown.trim().length;
          await _db.upsertSkill(
            preferIncoming
                ? AgentSkill(
                    id: existing.id,
                    name: skill.name.trim(),
                    description: skill.description,
                    bodyMarkdown: skill.bodyMarkdown,
                    disableModelInvocation: skill.disableModelInvocation,
                    createdAt: existing.createdAt,
                  )
                : existing,
          );
        } else {
          await _db.upsertSkill(skill);
        }
        skillsN++;
      }
    }

    final skillLinksRaw = root['skillHostLinks'];
    if (skillLinksRaw is List) {
      for (final item in skillLinksRaw) {
        if (item is! Map) continue;
        final link = SkillHostLink.fromMap(Map<String, Object?>.from(item));
        await _db.upsertSkillHostLink(link);
        skillLinksN++;
      }
    }

    SafeLog.d(
      'Imported .ag hosts=$hostsN repos=$reposN mcps=$mcpsN links=$linksN '
      'skills=$skillsN skillLinks=$skillLinksN',
    );
    return ConfigImportResult(
      hosts: hostsN,
      repos: reposN,
      mcpServers: mcpsN,
      mcpHostLinks: linksN,
      skills: skillsN,
      skillHostLinks: skillLinksN,
    );
  }
}

class ConfigImportResult {
  const ConfigImportResult({
    required this.hosts,
    required this.repos,
    required this.mcpServers,
    required this.mcpHostLinks,
    this.skills = 0,
    this.skillHostLinks = 0,
  });

  final int hosts;
  final int repos;
  final int mcpServers;
  final int mcpHostLinks;
  final int skills;
  final int skillHostLinks;

  String get summary =>
      'Imported $hosts host(s), $repos repo(s), $mcpServers MCP(s), '
      '$mcpHostLinks MCP link(s), $skills skill(s), $skillHostLinks skill link(s). '
      'SSH keys are not included — add them in Settings.';
}
