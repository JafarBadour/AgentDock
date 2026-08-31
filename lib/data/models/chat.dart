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
    this.status = ChatStatus.idle,
    this.sortOrder = 0,
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
  final ChatStatus status;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

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
        'status': status.name,
        'sort_order': sortOrder,
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
        status: ChatStatus.values.firstWhere(
          (s) => s.name == map['status'],
          orElse: () => ChatStatus.idle,
        ),
        sortOrder: (map['sort_order'] as int?) ?? 0,
        createdAt: DateTime.parse(map['created_at']! as String),
        updatedAt: DateTime.parse(map['updated_at']! as String),
      );

  Chat copyWith({
    String? title,
    String? tmuxSession,
    String? acpSessionId,
    int? journalOffset,
    String? modelId,
    DateTime? lastReadAt,
    ChatStatus? status,
    int? sortOrder,
    DateTime? updatedAt,
  }) =>
      Chat(
        id: id,
        repoId: repoId,
        title: title ?? this.title,
        provider: provider,
        tmuxSession: tmuxSession ?? this.tmuxSession,
        acpSessionId: acpSessionId ?? this.acpSessionId,
        journalOffset: journalOffset ?? this.journalOffset,
        modelId: modelId ?? this.modelId,
        lastReadAt: lastReadAt ?? this.lastReadAt,
        status: status ?? this.status,
        sortOrder: sortOrder ?? this.sortOrder,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
