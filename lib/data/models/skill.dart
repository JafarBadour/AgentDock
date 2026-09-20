/// Local Agent Skill definition (Cursor / Claude `SKILL.md`).
///
/// Deployed to hosts as `~/.cursor/skills/<name>/SKILL.md` (and Claude's
/// compatible `~/.claude/skills/<name>/SKILL.md`).
class AgentSkill {
  const AgentSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.bodyMarkdown,
    required this.createdAt,
    this.disableModelInvocation = false,
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

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'description': description,
        'body_markdown': bodyMarkdown,
        'disable_model_invocation': disableModelInvocation ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory AgentSkill.fromMap(Map<String, Object?> map) {
    return AgentSkill(
      id: map['id']! as String,
      name: map['name']! as String,
      description: (map['description'] as String?) ?? '',
      bodyMarkdown: (map['body_markdown'] as String?) ?? '',
      disableModelInvocation: (map['disable_model_invocation'] as int?) == 1,
      createdAt: DateTime.parse(map['created_at']! as String),
    );
  }
}

enum SkillHostInstallStatus {
  pending,
  installing,
  installed,
  failed,
  removed,
}

class SkillHostLink {
  const SkillHostLink({
    required this.skillId,
    required this.hostId,
    this.enabled = true,
    this.installStatus = SkillHostInstallStatus.pending,
    this.installDetail,
  });

  final String skillId;
  final String hostId;
  final bool enabled;
  final SkillHostInstallStatus installStatus;
  final String? installDetail;

  Map<String, Object?> toMap() => {
        'skill_id': skillId,
        'host_id': hostId,
        'enabled': enabled ? 1 : 0,
        'install_status': installStatus.name,
        'install_detail': installDetail,
      };

  factory SkillHostLink.fromMap(Map<String, Object?> map) {
    final statusRaw = (map['install_status'] as String?) ?? 'pending';
    final status = SkillHostInstallStatus.values.firstWhere(
      (s) => s.name == statusRaw,
      orElse: () => SkillHostInstallStatus.pending,
    );
    return SkillHostLink(
      skillId: map['skill_id']! as String,
      hostId: map['host_id']! as String,
      enabled: (map['enabled'] as int?) == 1,
      installStatus: status,
      installDetail: map['install_detail'] as String?,
    );
  }

  SkillHostLink copyWith({
    bool? enabled,
    SkillHostInstallStatus? installStatus,
    String? installDetail,
  }) {
    return SkillHostLink(
      skillId: skillId,
      hostId: hostId,
      enabled: enabled ?? this.enabled,
      installStatus: installStatus ?? this.installStatus,
      installDetail: installDetail ?? this.installDetail,
    );
  }
}
