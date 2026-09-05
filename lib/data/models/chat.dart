import 'agent_provider.dart';

enum ChatStatus { idle, running, error, dead }

class Chat {
  const Chat({
    required this.id,
    required this.repoId,
    required this.title,
    required this.provider,
    this.tmuxSession,
    this.acpSessionId,
    this.journalOffset = 0,
    this.modelId,
    this.lastReadAt,
    this.lastAutoNumber,
    this.linesAdded = 0,
    this.linesRemoved = 0,
    this.filesChanged = 0,
    this.codeDeltaDay,
    this.status = ChatStatus.idle,
    this.sortOrder = 0,
    this.titleUpdatedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String repoId;
  final String title;
  final AgentProvider provider;
  final String? tmuxSession;
  final String? acpSessionId;

  /// Bytes of the remote ACP journal already consumed, so a reconnect resumes
  /// instead of replaying the whole session.
  final int journalOffset;

  /// Exact `session/set_model` id last chosen for this chat, re-applied on
  /// every reconnect so the choice survives the agent restarting.
  final String? modelId;

  /// When the transcript was last looked at. Anything the agent said after this
  /// is what the unread badge counts. Synced to the host so the badge follows
  /// you between devices.
  ///
  /// Only ever moves forward — see [AppDatabase.markChatRead].
  final DateTime? lastReadAt;

  /// Last automated schedule number (`#N`) that delivered a prompt into this
  /// chat. Local-only — used for the Agents list badge.
  final int? lastAutoNumber;

  /// Session code churn from agent edit/write tools (`+` lines).
  final int linesAdded;

  /// Session code churn from agent edit/write tools (`-` lines).
  final int linesRemoved;

  /// Distinct files touched by agent edits this session.
  final int filesChanged;

  /// Local calendar day (`YYYY-MM-DD`) for [linesAdded]/[linesRemoved]/[filesChanged].
  /// Stats reset when this is not today.
  final String? codeDeltaDay;

  final ChatStatus status;
  final int sortOrder;

  /// When [title] was last set by the user (or an accepted ACP suggestion).
  /// Synced separately from [updatedAt] so ADSM status bumps cannot roll back
  /// a rename on another device.
  final DateTime? titleUpdatedAt;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// True when the title is still a create-time placeholder ACP may replace.
  bool get isPlaceholderTitle {
    final t = title.trim().toLowerCase();
    return t.isEmpty || t == 'new agent' || t == 'agent';
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'repo_id': repoId,
        'title': title,
        'provider': provider.id,
        'tmux_session': tmuxSession,
        'acp_session_id': acpSessionId,
        'journal_offset': journalOffset,
        'model_id': modelId,
        'last_read_at': lastReadAt?.toIso8601String(),
        'last_auto_number': lastAutoNumber,
        'lines_added': linesAdded,
        'lines_removed': linesRemoved,
        'files_changed': filesChanged,
        'code_delta_day': codeDeltaDay,
        'status': status.name,
        'sort_order': sortOrder,
        'title_updated_at': titleUpdatedAt?.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  factory Chat.fromMap(Map<String, Object?> map) => Chat(
        id: map['id']! as String,
        repoId: map['repo_id']! as String,
        title: map['title']! as String,
        provider: AgentProviderX.fromId(map['provider']! as String),
        tmuxSession: map['tmux_session'] as String?,
        acpSessionId: map['acp_session_id'] as String?,
        journalOffset: (map['journal_offset'] as int?) ?? 0,
        modelId: map['model_id'] as String?,
        lastReadAt: DateTime.tryParse((map['last_read_at'] as String?) ?? ''),
        lastAutoNumber: map['last_auto_number'] as int?,
        linesAdded: (map['lines_added'] as int?) ?? 0,
        linesRemoved: (map['lines_removed'] as int?) ?? 0,
        filesChanged: (map['files_changed'] as int?) ?? 0,
        codeDeltaDay: map['code_delta_day'] as String?,
        status: ChatStatus.values.firstWhere(
          (s) => s.name == map['status'],
          orElse: () => ChatStatus.idle,
        ),
        sortOrder: (map['sort_order'] as int?) ?? 0,
        titleUpdatedAt:
            DateTime.tryParse((map['title_updated_at'] as String?) ?? ''),
        createdAt: DateTime.parse(map['created_at']! as String),
        updatedAt: DateTime.parse(map['updated_at']! as String),
      );

  Chat copyWith({
    String? title,
    String? tmuxSession,
    String? acpSessionId,
    bool clearTmuxSession = false,
    bool clearAcpSessionId = false,
    int? journalOffset,
    String? modelId,
    DateTime? lastReadAt,
    int? lastAutoNumber,
    bool clearLastAutoNumber = false,
    int? linesAdded,
    int? linesRemoved,
    int? filesChanged,
    String? codeDeltaDay,
    bool clearCodeDelta = false,
    ChatStatus? status,
    int? sortOrder,
    DateTime? titleUpdatedAt,
    DateTime? updatedAt,
  }) =>
      Chat(
        id: id,
        repoId: repoId,
        title: title ?? this.title,
        provider: provider,
        tmuxSession:
            clearTmuxSession ? null : (tmuxSession ?? this.tmuxSession),
        acpSessionId:
            clearAcpSessionId ? null : (acpSessionId ?? this.acpSessionId),
        journalOffset: journalOffset ?? this.journalOffset,
        modelId: modelId ?? this.modelId,
        lastReadAt: lastReadAt ?? this.lastReadAt,
        lastAutoNumber: clearLastAutoNumber
            ? null
            : (lastAutoNumber ?? this.lastAutoNumber),
        linesAdded: clearCodeDelta ? 0 : (linesAdded ?? this.linesAdded),
        linesRemoved: clearCodeDelta ? 0 : (linesRemoved ?? this.linesRemoved),
        filesChanged: clearCodeDelta ? 0 : (filesChanged ?? this.filesChanged),
        codeDeltaDay:
            clearCodeDelta ? null : (codeDeltaDay ?? this.codeDeltaDay),
        status: status ?? this.status,
        sortOrder: sortOrder ?? this.sortOrder,
        titleUpdatedAt: titleUpdatedAt ?? this.titleUpdatedAt,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
