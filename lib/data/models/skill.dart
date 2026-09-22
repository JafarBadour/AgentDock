import 'dart:convert';

/// Local Agent Skill definition (Cursor / Claude `SKILL.md`).
///
/// Deployed to hosts as `~/.cursor/skills/<name>/` (and Claude's compatible
/// `~/.claude/skills/<name>/`), including optional supporting files
/// (`scripts/`, `references/`, `assets/`, …).
class AgentSkill {
  const AgentSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.bodyMarkdown,
    required this.createdAt,
    this.disableModelInvocation = false,
    this.bundleFiles = const [],
  });

  final String id;

  /// Folder / frontmatter name: lowercase letters, digits, hyphens.
  final String name;

  /// Shown to the agent for discovery (WHAT + WHEN).
  final String description;

  /// Markdown body below the YAML frontmatter (instructions, examples, …).
  final String bodyMarkdown;

  final DateTime createdAt;

  /// When true, skill is slash-invoked only (`/name`), not auto-applied.
  final bool disableModelInvocation;

  /// Extra files under the skill folder (not including `SKILL.md`).
  final List<SkillBundleFile> bundleFiles;

  /// Full `SKILL.md` contents written to the host.
  String toSkillMd() {
    final desc = description.trim().isEmpty
        ? 'Agent skill: $name'
        : description.trim();
    final buf = StringBuffer()
      ..writeln('---')
      ..writeln('name: $name')
      ..writeln('description: ${_yamlScalar(desc)}');
    if (disableModelInvocation) {
      buf.writeln('disable-model-invocation: true');
    }
    buf
      ..writeln('---')
      ..writeln()
      ..write(bodyMarkdown.trimRight());
    if (!bodyMarkdown.trimRight().endsWith('\n')) {
      buf.writeln();
    }
    return buf.toString();
  }

  /// Prefer block scalar when description has newlines or special YAML chars.
  static String _yamlScalar(String value) {
    if (value.contains('\n') ||
        value.contains(':') ||
        value.contains('#') ||
        value.contains('"') ||
        value.contains("'") ||
        value.startsWith(' ') ||
        value.endsWith(' ')) {
      final indented = value.split('\n').map((l) => '  $l').join('\n');
      return '>\n$indented';
    }
    return value;
  }

  static final _nameRe = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

  static bool isValidName(String name) =>
      name.length <= 64 && _nameRe.hasMatch(name);

  /// Slugify a display title into a valid skill name.
  static String slugify(String raw) {
    final lower = raw.trim().toLowerCase();
    final dashed = lower
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (dashed.isEmpty) return 'skill';
    return dashed.length <= 64 ? dashed : dashed.substring(0, 64);
  }

  /// Parse a `SKILL.md` document into name / description / body / flags.
  ///
  /// [fallbackName] is used when frontmatter omits `name` (e.g. folder name).
  static ParsedSkillMd parseSkillMd(
    String raw, {
    String? fallbackName,
  }) {
    final normalized = raw.replaceAll('\r\n', '\n');
    var name = fallbackName ?? '';
    var description = '';
    var disableModelInvocation = false;
    var body = normalized;

    if (normalized.startsWith('---')) {
      final end = normalized.indexOf('\n---', 3);
      if (end >= 0) {
        final front = normalized.substring(3, end).trim();
        body = normalized.substring(end + 4).replaceFirst(RegExp(r'^\n'), '');
        for (final line in front.split('\n')) {
          final trimmed = line.trimRight();
          if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
          final colon = trimmed.indexOf(':');
          if (colon <= 0) continue;
          final key = trimmed.substring(0, colon).trim().toLowerCase();
          var value = trimmed.substring(colon + 1).trim();
          if ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'"))) {
            value = value.substring(1, value.length - 1);
          }
          switch (key) {
            case 'name':
              if (value.isNotEmpty) name = value;
            case 'description':
              description = value;
            case 'disable-model-invocation':
              disableModelInvocation =
                  value.toLowerCase() == 'true' || value == '1';
          }
        }
        // Folded block scalar for description: description: >\n  line…
        if (description == '>' || description == '|') {
          final lines = <String>[];
          var capture = false;
          for (final line in front.split('\n')) {
            final t = line.trimRight();
            if (!capture) {
              if (RegExp(r'^description:\s*[>|]').hasMatch(t.trim())) {
                capture = true;
              }
              continue;
            }
            if (t.isEmpty) {
              lines.add('');
              continue;
            }
            if (t.startsWith(' ') || t.startsWith('\t')) {
              lines.add(t.trimLeft());
            } else {
              break;
            }
          }
          description = lines.join('\n').trim();
        }
      }
    }

    name = name.trim().toLowerCase();
    if (!isValidName(name) && fallbackName != null) {
      name = slugify(fallbackName);
    }
    return ParsedSkillMd(
      name: name,
      description: description.trim(),
      bodyMarkdown: body.trimRight(),
      disableModelInvocation: disableModelInvocation,
    );
  }

  AgentSkill copyWith({
    String? name,
    String? description,
    String? bodyMarkdown,
    bool? disableModelInvocation,
    List<SkillBundleFile>? bundleFiles,
  }) {
    return AgentSkill(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      bodyMarkdown: bodyMarkdown ?? this.bodyMarkdown,
      disableModelInvocation:
          disableModelInvocation ?? this.disableModelInvocation,
      createdAt: createdAt,
      bundleFiles: bundleFiles ?? this.bundleFiles,
    );
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        'body_markdown': bodyMarkdown,
        'disable_model_invocation': disableModelInvocation ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'bundle_json': SkillBundleFile.encodeList(bundleFiles),
      };

  factory AgentSkill.fromMap(Map<String, Object?> map) {
    return AgentSkill(
      id: map['id']! as String,
      name: map['name']! as String,
      description: (map['description'] as String?) ?? '',
      bodyMarkdown: (map['body_markdown'] as String?) ?? '',
      disableModelInvocation: (map['disable_model_invocation'] as int?) == 1,
      createdAt: DateTime.parse(map['created_at']! as String),
      bundleFiles: SkillBundleFile.decodeList(map['bundle_json'] as String?),
    );
  }
}

class ParsedSkillMd {
  const ParsedSkillMd({
    required this.name,
    required this.description,
    required this.bodyMarkdown,
    required this.disableModelInvocation,
  });

  final String name;
  final String description;
  final String bodyMarkdown;
  final bool disableModelInvocation;
}

/// Extra file shipped beside `SKILL.md` in the skill folder.
class SkillBundleFile {
  const SkillBundleFile({
    required this.relativePath,
    required this.bytes,
  });

  /// Posix-style path relative to the skill root (`scripts/foo.sh`).
  final String relativePath;
  final List<int> bytes;

  int get sizeBytes => bytes.length;

  Map<String, Object?> toJson() => {
        'path': relativePath,
        'b64': base64Encode(bytes),
      };

  factory SkillBundleFile.fromJson(Map<String, Object?> json) {
    final path = (json['path'] as String?)?.trim() ?? '';
    final b64 = (json['b64'] as String?) ?? '';
    return SkillBundleFile(
      relativePath: path,
      bytes: b64.isEmpty ? const [] : base64Decode(b64),
    );
  }

  static String encodeList(List<SkillBundleFile> files) {
    if (files.isEmpty) return '[]';
    return jsonEncode(files.map((f) => f.toJson()).toList());
  }

  static List<SkillBundleFile> decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map)
            SkillBundleFile.fromJson(Map<String, Object?>.from(item)),
      ].where((f) => f.relativePath.isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }
}

enum SkillHostInstallStatus {
  pending,
  installing,
  installed,
  failed,
  removed,
}

/// Where a skill was found / should be written on a host.
enum SkillClientTarget {
  cursor,
  claude,
  codex;

  String get label => switch (this) {
        cursor => 'Cursor',
        claude => 'Claude',
        codex => 'Codex',
      };

  static SkillClientTarget? tryParse(String raw) {
    final t = raw.trim().toLowerCase();
    for (final v in values) {
      if (v.name == t) return v;
    }
    return null;
  }
}

class SkillHostLink {
  const SkillHostLink({
    required this.skillId,
    required this.hostId,
    this.enabled = true,
    this.installStatus = SkillHostInstallStatus.pending,
    this.installDetail,
    this.targets = const [],
  });

  final String skillId;
  final String hostId;
  final bool enabled;
  final SkillHostInstallStatus installStatus;
  final String? installDetail;

  /// Present when the skill was probed/installed for Cursor and/or Claude.
  final List<SkillClientTarget> targets;

  String get targetsLabel => targets.map((t) => t.label).join(' · ');

  Map<String, Object?> toMap() => {
        'skill_id': skillId,
        'host_id': hostId,
        'enabled': enabled ? 1 : 0,
        'install_status': installStatus.name,
        'install_detail': installDetail,
        'targets_json': jsonEncode(targets.map((t) => t.name).toList()),
      };

  factory SkillHostLink.fromMap(Map<String, Object?> map) {
    final statusRaw = (map['install_status'] as String?) ?? 'pending';
    final status = SkillHostInstallStatus.values.firstWhere(
      (s) => s.name == statusRaw,
      orElse: () => SkillHostInstallStatus.pending,
    );
    final targets = <SkillClientTarget>[];
    final rawTargets = map['targets_json'] as String?;
    if (rawTargets != null && rawTargets.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawTargets);
        if (decoded is List) {
          for (final item in decoded) {
            final t = SkillClientTarget.tryParse('$item');
            if (t != null) targets.add(t);
          }
        }
      } catch (_) {}
    }
    return SkillHostLink(
      skillId: map['skill_id']! as String,
      hostId: map['host_id']! as String,
      enabled: (map['enabled'] as int?) == 1,
      installStatus: status,
      installDetail: map['install_detail'] as String?,
      targets: targets,
    );
  }

  SkillHostLink copyWith({
    bool? enabled,
    SkillHostInstallStatus? installStatus,
    String? installDetail,
    List<SkillClientTarget>? targets,
  }) {
    return SkillHostLink(
      skillId: skillId,
      hostId: hostId,
      enabled: enabled ?? this.enabled,
      installStatus: installStatus ?? this.installStatus,
      installDetail: installDetail ?? this.installDetail,
      targets: targets ?? this.targets,
    );
  }
}
