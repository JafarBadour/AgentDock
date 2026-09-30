/// What Archon has been asked to do about one agent.
///
/// The user switches an agent on and says what done looks like. Archon works
/// toward that, and when it is met it switches the agent back off and leaves a
/// [note] — so [enabled] reads as "Archon is still on this", never as "Archon
/// was once asked about this".
class ArchonBrief {
  const ArchonBrief({
    required this.chatId,
    this.enabled = false,
    this.goal,
    this.note,
    this.doneAt,
    required this.updatedAt,
  });

  final String chatId;
  final bool enabled;

  /// What the user wants; without one there is nothing to call finished.
  final String? goal;

  /// What Archon reported on switching itself off.
  final String? note;

  final DateTime? doneAt;
  final DateTime updatedAt;

  bool get hasGoal => (goal ?? '').trim().isNotEmpty;

  /// Archon is actively working on this.
  bool get isActive => enabled && hasGoal;

  /// Finished, with something to show for it.
  bool get isDone => !enabled && (note ?? '').trim().isNotEmpty;

  Map<String, Object?> toMap() => {
    'chat_id': chatId,
    'enabled': enabled ? 1 : 0,
    'goal': goal,
    'note': note,
    'done_at': doneAt?.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory ArchonBrief.fromMap(Map<String, Object?> map) => ArchonBrief(
    chatId: map['chat_id']! as String,
    enabled: ((map['enabled'] as int?) ?? 0) != 0,
    goal: map['goal'] as String?,
    note: map['note'] as String?,
    doneAt: DateTime.tryParse((map['done_at'] as String?) ?? ''),
    updatedAt:
        DateTime.tryParse((map['updated_at'] as String?) ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  ArchonBrief copyWith({
    bool? enabled,
    String? goal,
    String? note,
    DateTime? doneAt,
    bool clearNote = false,
    DateTime? updatedAt,
  }) => ArchonBrief(
    chatId: chatId,
    enabled: enabled ?? this.enabled,
    goal: goal ?? this.goal,
    note: clearNote ? null : (note ?? this.note),
    doneAt: clearNote ? null : (doneAt ?? this.doneAt),
    updatedAt: updatedAt ?? DateTime.now(),
  );
}
