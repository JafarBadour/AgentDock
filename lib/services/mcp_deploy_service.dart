import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

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

  /// Merge [mcp] into Cursor, Claude, and Codex MCP configs on [host].
  Future<McpHostLink> deployToHost({
    required McpServer mcp,
    required Host host,
  }) async {
    if (mcp.isStub) {
      // Writing this would leave an empty entry in every client config.
      final failed = McpHostLink(
        mcpId: mcp.id,
        hostId: host.id,
        enabled: false,
        installStatus: McpHostInstallStatus.failed,
        installDetail: 'No URL or command — edit the MCP first',
      );
      await _db.upsertMcpHostLink(failed);
      return failed;
    }
    var link = McpHostLink(
      mcpId: mcp.id,
      hostId: host.id,
      enabled: true,
      installStatus: McpHostInstallStatus.installing,
      installDetail: 'Writing MCP configs…',
    );
    await _db.upsertMcpHostLink(link);

    try {
      final homeOut = await _run(host, r'printf %s "$HOME"');
      final home = homeOut.trim().isEmpty ? '.' : homeOut.trim();
      final details = <String>[];

      // Always write all three — HPC non-interactive shells often hide `claude`
      // / `codex` from PATH, so "detect then skip" left only Cursor updated.
      final cursorPath = '$home/.cursor/mcp.json';
      await _run(host, 'mkdir -p ${SshService.shellQuote('$home/.cursor')}');
      await _upsertMcpEntry(
        host,
        path: cursorPath,
        name: mcp.name,
        entry: mcp.toMcpJsonEntry(),
        createRootIfMissing: true,
      );
      details.add('Updated $cursorPath');

      try {
        final enableOut = await _run(
          host,
          'export PATH="\$HOME/.local/bin:\$HOME/.cursor/bin:\$PATH"; '
          '(command -v agent >/dev/null && agent mcp enable ${SshService.shellQuote(mcp.name)}) || '
          '(command -v cursor-agent >/dev/null && cursor-agent mcp enable ${SshService.shellQuote(mcp.name)}) || '
          'true',
          timeout: const Duration(seconds: 45),
        );
        final t = enableOut.trim();
        if (t.isNotEmpty) details.add(t);
      } catch (e) {
        SafeLog.d('agent mcp enable optional step failed', e);
        details.add('(cursor enable skipped: $e)');
      }

      final claudePath = '$home/.claude.json';
      await _upsertMcpEntry(
        host,
        path: claudePath,
        name: mcp.name,
        entry: mcp.toClaudeMcpJsonEntry(),
        createRootIfMissing: true,
      );
      details.add('Updated $claudePath');

      final codexPath = await _upsertCodexMcp(host, mcp: mcp, home: home);
      details.add('Updated $codexPath');

      link = link.copyWith(
        installStatus: McpHostInstallStatus.installed,
        installDetail: details.join('\n'),
        targets: const [
          McpClientTarget.cursor,
          McpClientTarget.claude,
          McpClientTarget.codex,
        ],
      );
      await _db.upsertMcpHostLink(link);
      return link;
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
      installDetail: 'Removing MCP from host configs…',
    );
    await _db.upsertMcpHostLink(link);

    try {
      final homeOut = await _run(host, r'printf %s "$HOME"');
      final home = homeOut.trim().isEmpty ? '.' : homeOut.trim();
      final details = <String>[];

      final cursorPath = '$home/.cursor/mcp.json';
      final cursorRemoved = await _removeMcpEntry(
        host,
        path: cursorPath,
        name: mcp.name,
      );
      if (cursorRemoved) details.add('Removed from $cursorPath');

      try {
        await _run(
          host,
          'export PATH="\$HOME/.local/bin:\$HOME/.cursor/bin:\$PATH"; '
          '(command -v agent >/dev/null && agent mcp disable ${SshService.shellQuote(mcp.name)}) || true',
          timeout: const Duration(seconds: 30),
        );
      } catch (_) {}

      final claudePath = '$home/.claude.json';
      final claudeRemoved = await _removeMcpEntry(
        host,
        path: claudePath,
        name: mcp.name,
      );
      if (claudeRemoved) details.add('Removed from $claudePath');

      final codexPath = await _removeCodexMcp(host, mcp: mcp, home: home);
      if (codexPath != null) details.add('Removed from $codexPath');

      link = link.copyWith(
        enabled: false,
        installStatus: McpHostInstallStatus.removed,
        installDetail: details.isEmpty
            ? 'Removed ${mcp.name} (no remote entries found)'
            : details.join('\n'),
        targets: const [],
      );
      await _db.upsertMcpHostLink(link);
      return link;
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

  /// Merge [mcp] into `~/.codex/config.toml` (TOML), preserving other keys.
  Future<String> _upsertCodexMcp(
    Host host, {
    required McpServer mcp,
    required String home,
  }) async {
    final path = '$home/.codex/config.toml';
    await _run(host, 'mkdir -p ${SshService.shellQuote('$home/.codex')}');
    final fragment = mcp.toCodexTomlFragment();
    final payload = jsonEncode({'name': mcp.name, 'fragment': fragment});
    final b64 = base64Encode(utf8.encode(payload));
    await _run(host, '''
python3 - <<'PY'
import base64, json, pathlib, re, sys
raw = base64.b64decode(${SshService.shellQuote(b64)}).decode("utf-8")
data = json.loads(raw)
name = data["name"]
fragment = data["fragment"].rstrip() + "\\n"
path = pathlib.Path(${SshService.shellQuote(path)})
text = path.read_text(encoding="utf-8") if path.exists() else ""
# Drop existing [mcp_servers.<name>] and nested tables for that server.
pat = re.compile(
    r"(?ms)^\\[mcp_servers\\." + re.escape(name) + r"(?:\\.[^\\]]+)?\\][^\\[]*"
)
text = pat.sub("", text).rstrip()
if text:
    text = text + "\\n\\n" + fragment
else:
    text = fragment
path.write_text(text if text.endswith("\\n") else text + "\\n", encoding="utf-8")
print(path)
PY
''', timeout: const Duration(seconds: 30));
    return path;
  }

  Future<String?> _removeCodexMcp(
    Host host, {
    required McpServer mcp,
    required String home,
  }) async {
    final path = '$home/.codex/config.toml';
    try {
      final out = await _run(host, '''
python3 - <<'PY'
import pathlib, re, sys
name = ${jsonEncode(mcp.name)}
path = pathlib.Path(${SshService.shellQuote(path)})
if not path.exists():
    sys.exit(0)
text = path.read_text(encoding="utf-8")
pat = re.compile(
    r"(?ms)^\\[mcp_servers\\." + re.escape(name) + r"(?:\\.[^\\]]+)?\\][^\\[]*"
)
new = pat.sub("", text).rstrip() + ("\\n" if text.strip() else "")
if new == text:
    sys.exit(0)
path.write_text(new if not new or new.endswith("\\n") else new + "\\n", encoding="utf-8")
print(path)
PY
''', timeout: const Duration(seconds: 30));
      final t = out.trim();
      return t.isEmpty ? null : t;
    } catch (e) {
      SafeLog.d('remove codex mcp failed', e);
      return null;
    }
  }

  Future<void> _upsertMcpEntry(
    Host host, {
    required String path,
    required String name,
    required Map<String, dynamic> entry,
    required bool createRootIfMissing,
  }) async {
    Map<String, dynamic> root = {'mcpServers': <String, dynamic>{}};
    var hadFile = false;
    try {
      final existing = await _run(
        host,
        'test -f ${SshService.shellQuote(path)} && cat ${SshService.shellQuote(path)} || true',
      );
      final trimmed = existing.trim();
      if (trimmed.isNotEmpty) {
        hadFile = true;
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          root = decoded;
        } else if (decoded is Map) {
          root = Map<String, dynamic>.from(decoded);
        }
      }
    } catch (e) {
      SafeLog.d('read remote $path failed; starting fresh', e);
    }

    if (!hadFile && !createRootIfMissing) {
      // Claude: only write mcpServers into an existing ~/.claude.json, or
      // create a minimal one if `claude` exists but the file does not yet.
      root = {'mcpServers': <String, dynamic>{}};
    }

    final servers = <String, dynamic>{};
    final existingServers = root['mcpServers'];
    if (existingServers is Map) {
      existingServers.forEach((k, v) {
        servers[k.toString()] = v;
      });
    }
    servers[name] = entry;
    root['mcpServers'] = servers;

    final payload = const JsonEncoder.withIndent('  ').convert(root);
    final b64 = base64Encode(utf8.encode(payload));
    await _run(
      host,
      'printf %s ${SshService.shellQuote(b64)} | base64 -d > ${SshService.shellQuote(path)}',
    );
  }

  Future<bool> _removeMcpEntry(
    Host host, {
    required String path,
    required String name,
  }) async {
    try {
      final existing = await _run(
        host,
        'test -f ${SshService.shellQuote(path)} && cat ${SshService.shellQuote(path)} || true',
      );
      final trimmed = existing.trim();
      if (trimmed.isEmpty) return false;
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return false;
      final root = Map<String, dynamic>.from(decoded);
      final servers = <String, dynamic>{};
      final existingServers = root['mcpServers'];
      var removed = false;
      if (existingServers is Map) {
        existingServers.forEach((k, v) {
          if (k.toString() != name) {
            servers[k.toString()] = v;
          } else {
            removed = true;
          }
        });
      }
      if (!removed) return false;
      root['mcpServers'] = servers;
      final payload = const JsonEncoder.withIndent('  ').convert(root);
      final b64 = base64Encode(utf8.encode(payload));
      await _run(
        host,
        'printf %s ${SshService.shellQuote(b64)} | base64 -d > ${SshService.shellQuote(path)}',
      );
      return true;
    } catch (e) {
      SafeLog.d('remove mcp entry from $path failed', e);
      return false;
    }
  }

  /// Read Cursor / Claude / Codex MCP names on [host] and refresh local links.
  Future<void>? _syncRemoteInFlight;

  Future<void> syncRemoteMcpState(Host host) async {
    // Serialize probes — concurrent host refreshes used to mint duplicate stubs.
    while (_syncRemoteInFlight != null) {
      try {
        await _syncRemoteInFlight;
      } catch (_) {}
    }
    final done = Completer<void>();
    _syncRemoteInFlight = done.future;
    try {
      await _syncRemoteMcpStateUnlocked(host);
      done.complete();
    } catch (e, st) {
      done.completeError(e, st);
      rethrow;
    } finally {
      if (identical(_syncRemoteInFlight, done.future)) {
        _syncRemoteInFlight = null;
      }
    }
  }

  Future<void> _syncRemoteMcpStateUnlocked(Host host) async {
    try {
      await _db.ensureMcpServersDeduped();
    } catch (_) {}
    final raw = await _run(host, r'''
python3 - <<'PY'
import json, pathlib, re, os
home = pathlib.Path(os.path.expanduser("~"))
# Full entries per client ({name: entry}), so servers found on a host can be
# copied to other hosts — not just listed by name.
out = {"cursor": {}, "claude": {}, "codex": {}}

def entries_from_json(path):
    try:
        if not path.is_file():
            return {}
        data = json.loads(path.read_text(encoding="utf-8"))
        servers = data.get("mcpServers") or data.get("mcp_servers") or {}
        if isinstance(servers, dict):
            return {
                str(k): (v if isinstance(v, dict) else {})
                for k, v in servers.items()
            }
    except Exception:
        pass
    return {}

def toml_value(raw):
    raw = raw.strip()
    try:
        return json.loads(raw)  # "strings", [arrays], numbers, true/false
    except Exception:
        pass
    if raw.startswith("'") and raw.endswith("'"):
        return raw[1:-1]
    return raw

def codex_entries(text):
    try:
        try:
            import tomllib as toml
        except ImportError:
            import tomli as toml  # type: ignore
        servers = toml.loads(text).get("mcp_servers") or {}
        return {str(k): v for k, v in servers.items() if isinstance(v, dict)}
    except Exception:
        pass
    # Python < 3.11 without tomli: flat keys plus env / http_headers tables.
    found = {}
    current = None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^\[mcp_servers\.(?:"([^"]+)"|([^\].]+))(?:\.([A-Za-z_]+))?\]$', line)
        if m:
            name = m.group(1) or m.group(2)
            entry = found.setdefault(name, {})
            current = entry.setdefault(m.group(3), {}) if m.group(3) else entry
            continue
        if line.startswith("["):
            current = None
            continue
        if current is not None and "=" in line:
            key, _, value = line.partition("=")
            current[key.strip().strip('"')] = toml_value(value)
    return found

out["cursor"] = entries_from_json(home / ".cursor" / "mcp.json")
out["claude"] = entries_from_json(home / ".claude.json")
codex = home / ".codex" / "config.toml"
if codex.is_file():
    try:
        out["codex"] = codex_entries(codex.read_text(encoding="utf-8"))
    except Exception:
        pass
print(json.dumps(out, default=str))
PY
''', timeout: const Duration(seconds: 20));

    Map<String, dynamic> decoded = {};
    try {
      final parsed = jsonDecode(raw.trim().split('\n').last);
      if (parsed is Map) decoded = Map<String, dynamic>.from(parsed);
    } catch (e) {
      SafeLog.d('parse remote mcp probe failed', e);
      return;
    }

    /// {name: entry} per client. Older probes sent a bare list of names.
    Map<String, Map<String, dynamic>> entriesFor(String key) {
      final v = decoded[key];
      final out = <String, Map<String, dynamic>>{};
      if (v is Map) {
        v.forEach((k, e) {
          final name = '$k'.trim();
          if (name.isEmpty) return;
          out[name] = e is Map ? Map<String, dynamic>.from(e) : {};
        });
      } else if (v is List) {
        for (final n in v) {
          final name = '$n'.trim();
          if (name.isNotEmpty) out[name] = {};
        }
      }
      return out;
    }

    final cursorEntries = entriesFor('cursor');
    final claudeEntries = entriesFor('claude');
    final codexEntries = entriesFor('codex');
    final cursor = cursorEntries.keys.toSet();
    final claude = claudeEntries.keys.toSet();
    final codex = codexEntries.keys.toSet();
    final allNames = {...cursor, ...claude, ...codex};

    final locals = await _db.listMcpServers();
    final byName = <String, McpServer>{
      for (final m in locals) m.name.trim().toLowerCase(): m,
    };

    String norm(String n) => n.trim().toLowerCase();

    /// The host's definition of [name], trying Claude, Cursor, then Codex.
    McpServer? hostDefinition(
      String name, {
      required String id,
      required String displayName,
      required DateTime createdAt,
    }) {
      for (final entries in [claudeEntries, cursorEntries, codexEntries]) {
        final entry = entries[name];
        if (entry == null) continue;
        final parsed = McpServer.fromHostConfig(
          id: id,
          name: displayName,
          entry: entry,
          createdAt: createdAt,
        );
        if (parsed != null) return parsed;
      }
      return null;
    }

    // Import remotes we have never seen, and fill in name-only stubs left by
    // older probes. Never overwrite a definition that already has a URL or
    // command — that one came from the user.
    for (final name in allNames) {
      final key = norm(name);
      final local = byName[key];
      if (local != null && !local.isStub) continue;
      final imported = hostDefinition(
        name,
        id: local?.id ?? const Uuid().v4(),
        displayName: local?.name ?? name.trim(),
        createdAt: local?.createdAt ?? DateTime.now(),
      );
      if (local != null) {
        if (imported == null) continue;
        await _db.upsertMcpServer(imported);
        byName[key] = imported;
        continue;
      }
      final row =
          imported ??
          McpServer(
            id: const Uuid().v4(),
            name: name.trim(),
            transport: McpTransport.http,
            url: null,
            createdAt: DateTime.now(),
          );
      try {
        await _db.upsertMcpServer(row);
        byName[key] = row;
      } catch (e) {
        // Unique name index: another probe won the race — reuse that row.
        SafeLog.d('mcp stub insert raced for $name', e);
        final existing = await _db.findMcpServerByName(name);
        if (existing != null) byName[key] = existing;
      }
    }

    final cursorKeys = {for (final n in cursor) norm(n)};
    final claudeKeys = {for (final n in claude) norm(n)};
    final codexKeys = {for (final n in codex) norm(n)};

    final localsAfter = byName.values.toList();
    for (final mcp in localsAfter) {
      final key = norm(mcp.name);
      final targets = <McpClientTarget>[
        if (cursorKeys.contains(key)) McpClientTarget.cursor,
        if (claudeKeys.contains(key)) McpClientTarget.claude,
        if (codexKeys.contains(key)) McpClientTarget.codex,
      ];
      final links = await _db.listMcpHostLinks(mcpId: mcp.id, hostId: host.id);
      final existing = links.isEmpty ? null : links.first;

      if (targets.isEmpty) {
        if (existing != null &&
            existing.enabled &&
            existing.installStatus == McpHostInstallStatus.installed) {
          // Was installed via AgentPlantation but vanished from all configs.
          await _db.upsertMcpHostLink(
            existing.copyWith(
              enabled: false,
              installStatus: McpHostInstallStatus.removed,
              installDetail: 'Not found in Cursor/Claude/Codex configs',
              targets: const [],
            ),
          );
        } else if (existing != null && existing.targets.isNotEmpty) {
          await _db.upsertMcpHostLink(existing.copyWith(targets: const []));
        }
        continue;
      }

      final detail = targets.map((t) => t.label).join(' · ');
      await _db.upsertMcpHostLink(
        McpHostLink(
          mcpId: mcp.id,
          hostId: host.id,
          enabled: true,
          installStatus: McpHostInstallStatus.installed,
          installDetail: existing?.installDetail?.contains('Updated') == true
              ? existing!.installDetail
              : 'On host: $detail',
          targets: targets,
        ),
      );
    }
  }

  Future<String> _run(
    Host host,
    String command, {
    Duration timeout = const Duration(seconds: 20),
  }) => _ssh.exec(host, command, timeout: timeout);
}
