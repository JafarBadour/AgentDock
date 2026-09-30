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

  /// What Archon does for an agent switched on without a goal of its own.
  /// Kept in step with `DEFAULT_GOAL` in host/archon/directory.py.
  static const defaultGoal =
      "Answer this agent's chat the way the user would, keeping its work "
      'moving. Only bring something to the user when it genuinely needs them.';

  /// What Archon actually works toward — the user's words, or the default.
  String get effectiveGoal => hasGoal ? goal!.trim() : defaultGoal;

  final DateTime? doneAt;
  final DateTime updatedAt;

  bool get hasGoal => (goal ?? '').trim().isNotEmpty;

  /// Archon is working on this. A goal is optional — most agents only need
  /// their chat kept moving, and requiring a brief made switching one on into
  /// paperwork.
  bool get isActive => enabled;

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
