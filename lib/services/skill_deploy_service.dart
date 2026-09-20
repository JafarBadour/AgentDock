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
/// Writes the same skill into Cursor and Claude user skill roots so ACP
/// sessions on either stack pick them up:
/// - `~/.cursor/skills/<name>/SKILL.md`
/// - `~/.claude/skills/<name>/SKILL.md`
class SkillDeployService {
  SkillDeployService(this._ssh, this._db);

  final SshService _ssh;
  final AppDatabase _db;

  Future<SkillHostLink> deployToHost({
    required AgentSkill skill,
    required Host host,
  }) async {
    var link = SkillHostLink(
      skillId: skill.id,
      hostId: host.id,
      enabled: true,
      installStatus: SkillHostInstallStatus.installing,
      installDetail: 'Writing SKILL.md…',
    );
    await _db.upsertSkillHostLink(link);

    try {
      final client = await _ssh.connect(host);
      final homeOut = await _run(client, r'printf %s "$HOME"');
      final home = homeOut.trim().isEmpty ? '.' : homeOut.trim();
      final details = <String>[];
      final md = skill.toSkillMd();
      final slug = skill.name;

      for (final root in [
        '$home/.cursor/skills',
        '$home/.claude/skills',
      ]) {
        final dir = '$root/$slug';
        final path = '$dir/SKILL.md';
        await _run(client, 'mkdir -p ${SshService.shellQuote(dir)}');
        await _writeFile(client, path: path, contents: md);
        details.add('Updated $path');
      }

      link = link.copyWith(
        installStatus: SkillHostInstallStatus.installed,
        installDetail: details.join('\n'),
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
    final client = await _ssh.connect(host);
    final raw = await _run(
      client,
      r'''
python3 - <<'PY'
import json, pathlib, os
home = pathlib.Path(os.path.expanduser("~"))
names = set()
for root in (home / ".cursor" / "skills", home / ".claude" / "skills"):
    if not root.is_dir():
        continue
    for child in root.iterdir():
        if child.is_dir() and (child / "SKILL.md").is_file():
            names.add(child.name)
print(json.dumps(sorted(names)))
PY
''',
      timeout: const Duration(seconds: 20),
    );

    Set<String> remoteNames = {};
    try {
      final parsed = jsonDecode(raw.trim().split('\n').last);
      if (parsed is List) {
        remoteNames = {
          for (final n in parsed) '$n'.trim(),
        }.where((s) => s.isNotEmpty).toSet();
      }
    } catch (e) {
      SafeLog.d('parse remote skill probe failed', e);
      return;
    }

    final locals = await _db.listSkills();
    final byName = <String, AgentSkill>{
      for (final s in locals) s.name.trim().toLowerCase(): s,
    };

    for (final name in remoteNames) {
      final key = name.trim().toLowerCase();
      if (byName.containsKey(key)) continue;
      if (!AgentSkill.isValidName(name)) continue;
      final stub = AgentSkill(
        id: const Uuid().v4(),
        name: name,
        description: 'Discovered on ${host.displayLabel}',
        bodyMarkdown:
            '# $name\n\nImported stub — open in Settings to edit the full skill.\n',
        createdAt: DateTime.now(),
      );
      try {
        await _db.upsertSkill(stub);
        byName[key] = stub;
      } catch (e) {
        SafeLog.d('skill stub insert raced for $name', e);
        final existing = await _db.findSkillByName(name);
        if (existing != null) byName[key] = existing;
      }
    }

    for (final skill in byName.values) {
      final onHost = remoteNames.any(
        (n) => n.trim().toLowerCase() == skill.name.trim().toLowerCase(),
      );
      final links = await _db.listSkillHostLinks(
        skillId: skill.id,
        hostId: host.id,
      );
      final existing = links.isEmpty ? null : links.first;
      if (onHost) {
        await _db.upsertSkillHostLink(
          SkillHostLink(
            skillId: skill.id,
            hostId: host.id,
            enabled: true,
            installStatus: SkillHostInstallStatus.installed,
            installDetail: existing?.installDetail?.contains('Updated') == true
                ? existing!.installDetail
                : 'On host: ~/.cursor/skills + ~/.claude/skills',
          ),
        );
      } else if (existing != null &&
          existing.enabled &&
          existing.installStatus == SkillHostInstallStatus.installed) {
        await _db.upsertSkillHostLink(
          existing.copyWith(
            enabled: false,
            installStatus: SkillHostInstallStatus.removed,
            installDetail: 'Not found in ~/.cursor/skills or ~/.claude/skills',
          ),
        );
      }
    }
  }

  Future<void> _writeFile(
    SSHClient client, {
    required String path,
    required String contents,
  }) async {
    final b64 = base64Encode(utf8.encode(contents));
    await _run(
      client,
      'printf %s ${SshService.shellQuote(b64)} | base64 -d > ${SshService.shellQuote(path)}',
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
