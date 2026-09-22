import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:uuid/uuid.dart';

import '../data/local/app_database.dart';
import '../data/models/host.dart';
import '../data/models/skill.dart';
import '../data/secure/safe_log.dart';
import 'ssh_service.dart';

/// Installs / removes Agent Skills (`SKILL.md`) on remotes via SSH.
///
/// Writes the same skill into Cursor, Claude and Codex user skill roots so ACP
/// sessions on either stack pick them up:
/// - `~/.cursor/skills/<name>/SKILL.md`
/// - `~/.claude/skills/<name>/SKILL.md`
/// - `~/.codex/skills/<name>/SKILL.md`
class SkillDeployService {
  SkillDeployService(this._ssh, this._db);

  final SshService _ssh;
  final AppDatabase _db;

  Future<void>? _syncRemoteInFlight;

  Future<SkillHostLink> deployToHost({
    required AgentSkill skill,
    required Host host,
  }) async {
    var link = SkillHostLink(
      skillId: skill.id,
      hostId: host.id,
      enabled: true,
      installStatus: SkillHostInstallStatus.installing,
      installDetail: 'Writing skill folder…',
      targets: const [
        SkillClientTarget.cursor,
        SkillClientTarget.claude,
        SkillClientTarget.codex,
      ],
    );
    await _db.upsertSkillHostLink(link);

    try {
      final client = await _ssh.connect(host);
      final homeOut = await _run(client, r'printf %s "$HOME"');
      final home = homeOut.trim().isEmpty ? '.' : homeOut.trim();
      final details = <String>[];
      final md = skill.toSkillMd();
      final slug = skill.name;
      final extra = skill.bundleFiles;

      for (final root in [
        '$home/.cursor/skills',
        '$home/.claude/skills',
        '$home/.codex/skills',
      ]) {
        final dir = '$root/$slug';
        // Replace the whole skill tree so removed supporting files don't linger.
        await _run(client, 'rm -rf ${SshService.shellQuote(dir)}');
        await _run(client, 'mkdir -p ${SshService.shellQuote(dir)}');
        await _writeBytes(
          client,
          path: '$dir/SKILL.md',
          bytes: utf8.encode(md),
        );
        details.add('Updated $dir/SKILL.md');
        for (final file in extra) {
          final rel = file.relativePath.replaceAll('\\', '/');
          if (rel.isEmpty ||
              rel.contains('..') ||
              rel.startsWith('/') ||
              rel == 'SKILL.md') {
            continue;
          }
          final remotePath = '$dir/$rel';
          final parent = remotePath.contains('/')
              ? remotePath.substring(0, remotePath.lastIndexOf('/'))
              : dir;
          await _run(client, 'mkdir -p ${SshService.shellQuote(parent)}');
          await _writeBytes(client, path: remotePath, bytes: file.bytes);
          details.add('Updated $remotePath');
        }
      }

      link = link.copyWith(
        installStatus: SkillHostInstallStatus.installed,
        installDetail: details.join('\n'),
        targets: const [
        SkillClientTarget.cursor,
        SkillClientTarget.claude,
        SkillClientTarget.codex,
      ],
      );
      await _db.upsertSkillHostLink(link);
      return link;
    } catch (e) {
      SafeLog.d('Skill deploy failed', e);
      link = link.copyWith(
        installStatus: SkillHostInstallStatus.failed,
        installDetail: e.toString(),
      );
      await _db.upsertSkillHostLink(link);
      return link;
    }
  }

  Future<SkillHostLink> removeFromHost({
    required AgentSkill skill,
    required Host host,
  }) async {
    var link = SkillHostLink(
      skillId: skill.id,
      hostId: host.id,
      enabled: false,
      installStatus: SkillHostInstallStatus.installing,
      installDetail: 'Removing skill…',
      targets: const [],
    );
    await _db.upsertSkillHostLink(link);

    try {
      final client = await _ssh.connect(host);
      final homeOut = await _run(client, r'printf %s "$HOME"');
      final home = homeOut.trim().isEmpty ? '.' : homeOut.trim();
      final details = <String>[];
      final slug = skill.name;

      for (final root in [
        '$home/.cursor/skills',
        '$home/.claude/skills',
        '$home/.codex/skills',
      ]) {
        final dir = '$root/$slug';
        await _run(
          client,
          'rm -rf ${SshService.shellQuote(dir)}',
        );
        details.add('Removed $dir');
      }

      link = link.copyWith(
        installStatus: SkillHostInstallStatus.removed,
        installDetail: details.join('\n'),
        targets: const [],
      );
      await _db.upsertSkillHostLink(link);
      return link;
    } catch (e) {
      SafeLog.d('Skill remove failed', e);
      link = link.copyWith(
        installStatus: SkillHostInstallStatus.failed,
        installDetail: e.toString(),
      );
      await _db.upsertSkillHostLink(link);
      return link;
    }
  }

  /// Probe remote skill folders and refresh local links / stubs.
  Future<void> syncRemoteSkillState(Host host) async {
    while (_syncRemoteInFlight != null) {
      try {
        await _syncRemoteInFlight;
      } catch (_) {}
    }
    final done = Completer<void>();
    _syncRemoteInFlight = done.future;
    try {
      await _syncRemoteSkillStateUnlocked(host);
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

  Future<void> _syncRemoteSkillStateUnlocked(Host host) async {
    final client = await _ssh.connect(host);
    final raw = await _run(
      client,
      r'''
python3 - <<'PY'
import json, pathlib, os, re
home = pathlib.Path(os.path.expanduser("~"))
# name -> {cursor, claude, codex, description}
found = {}

def read_desc(skill_md: pathlib.Path) -> str:
    try:
        text = skill_md.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""
    if not text.startswith("---"):
        return ""
    end = text.find("\n---", 3)
    if end < 0:
        return ""
    front = text[3:end]
    m = re.search(r"(?m)^description:\s*(.+)$", front)
    if not m:
        return ""
    val = m.group(1).strip()
    if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
        val = val[1:-1]
    if val in (">", "|"):
        lines = []
        capture = False
        for line in front.splitlines():
            if not capture:
                if re.match(r"^description:\s*[>|]", line.strip()):
                    capture = True
                continue
            if not line.strip():
                lines.append("")
                continue
            if line.startswith(" ") or line.startswith("\t"):
                lines.append(line.strip())
            else:
                break
        val = " ".join(x for x in lines if x).strip()
    return val[:240]

for label, root in (
    ("cursor", home / ".cursor" / "skills"),
    ("claude", home / ".claude" / "skills"),
    ("codex", home / ".codex" / "skills"),
):
    if not root.is_dir():
        continue
    for child in root.iterdir():
        if not child.is_dir():
            continue
        md = child / "SKILL.md"
        if not md.is_file():
            md = child / "skill.md"
        if not md.is_file():
            continue
        name = child.name.strip()
        if not name:
            continue
        entry = found.setdefault(
            name,
            {"name": name, "cursor": False, "claude": False, "codex": False, "description": ""},
        )
        entry[label] = True
        if not entry["description"]:
            entry["description"] = read_desc(md)

print(json.dumps(sorted(found.values(), key=lambda e: e["name"].lower())))
PY
''',
      timeout: const Duration(seconds: 25),
    );

    final remote = <Map<String, dynamic>>[];
    try {
      final parsed = jsonDecode(raw.trim().split('\n').last);
      if (parsed is List) {
        for (final item in parsed) {
          if (item is Map) {
            remote.add(Map<String, dynamic>.from(item));
          } else if (item != null) {
            // Legacy probe returned bare names.
            remote.add({
              'name': '$item'.trim(),
              'cursor': true,
              'claude': true,
              'codex': true,
              'description': '',
            });
          }
        }
      }
    } catch (e) {
      SafeLog.d('parse remote skill probe failed', e);
      return;
    }

    final byRemoteName = <String, Map<String, dynamic>>{
      for (final e in remote)
        if ('${e['name'] ?? ''}'.trim().isNotEmpty)
          '${e['name']}'.trim().toLowerCase(): e,
    };

    final locals = await _db.listSkills();
    final byName = <String, AgentSkill>{
      for (final s in locals) s.name.trim().toLowerCase(): s,
    };

    for (final entry in remote) {
      final name = '${entry['name'] ?? ''}'.trim();
      final key = name.toLowerCase();
      if (key.isEmpty || !AgentSkill.isValidName(name)) continue;
      final desc = '${entry['description'] ?? ''}'.trim();
      final existing = byName[key];
      if (existing == null) {
        final stub = AgentSkill(
          id: const Uuid().v4(),
          name: name,
          description: desc.isEmpty
              ? 'Discovered on ${host.displayLabel}'
              : desc,
          bodyMarkdown:
              '# $name\n\nImported stub — open in Settings to edit the full skill.\n',
          createdAt: DateTime.now(),
        );
        try {
          await _db.upsertSkill(stub);
          byName[key] = stub;
        } catch (e) {
          SafeLog.d('skill stub insert raced for $name', e);
          final raced = await _db.findSkillByName(name);
          if (raced != null) byName[key] = raced;
        }
      } else if (desc.isNotEmpty &&
          (existing.description.startsWith('Discovered on ') ||
              existing.description.trim().isEmpty)) {
        final updated = existing.copyWith(description: desc);
        await _db.upsertSkill(updated);
        byName[key] = updated;
      }
    }

    for (final skill in byName.values) {
      final key = skill.name.trim().toLowerCase();
      final remoteEntry = byRemoteName[key];
      final links = await _db.listSkillHostLinks(
        skillId: skill.id,
        hostId: host.id,
      );
      final existing = links.isEmpty ? null : links.first;

      if (remoteEntry != null) {
        final targets = <SkillClientTarget>[
          if (remoteEntry['cursor'] == true) SkillClientTarget.cursor,
          if (remoteEntry['claude'] == true) SkillClientTarget.claude,
          if (remoteEntry['codex'] == true) SkillClientTarget.codex,
        ];
        // If probe lacked root flags, assume both (legacy).
        final effective = targets.isEmpty
            ? const [
        SkillClientTarget.cursor,
        SkillClientTarget.claude,
        SkillClientTarget.codex,
      ]
            : targets;
        final detail = effective.map((t) => t.label).join(' · ');
        await _db.upsertSkillHostLink(
          SkillHostLink(
            skillId: skill.id,
            hostId: host.id,
            enabled: true,
            installStatus: SkillHostInstallStatus.installed,
            installDetail: existing?.installDetail?.contains('Updated') == true
                ? existing!.installDetail
                : 'On host: $detail',
            targets: effective,
          ),
        );
      } else {
        // Probed this host and skill is absent — record that so Settings
        // can show host status after refresh.
        await _db.upsertSkillHostLink(
          SkillHostLink(
            skillId: skill.id,
            hostId: host.id,
            enabled: false,
            installStatus: SkillHostInstallStatus.removed,
            installDetail: 'Not on ${host.displayLabel} '
                '(~/.cursor/skills / ~/.claude/skills / ~/.codex/skills)',
            targets: const [],
          ),
        );
      }
    }
  }

  Future<void> _writeBytes(
    SSHClient client, {
    required String path,
    required List<int> bytes,
  }) async {
    final b64 = base64Encode(bytes);
    await _run(
      client,
      'printf %s ${SshService.shellQuote(b64)} | base64 -d > ${SshService.shellQuote(path)}',
      timeout: const Duration(seconds: 60),
    );
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
