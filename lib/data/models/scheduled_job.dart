/// How often a scheduled agent prompt should fire.
enum ScheduleKind {
  once,
  interval,
  daily,
  weekly;

  String get label => switch (this) {
        ScheduleKind.once => 'Once',
        ScheduleKind.interval => 'Every…',
        ScheduleKind.daily => 'Daily',
        ScheduleKind.weekly => 'Weekly',
      };

  static ScheduleKind fromId(String? id) {
    return ScheduleKind.values.firstWhere(
      (k) => k.name == id,
      orElse: () => ScheduleKind.once,
    );
  }
}

/// Prefixes automated prompts so chats / Agents list can show `#N`.
abstract final class AutoRunTag {
  static final RegExp prefixRe = RegExp(r'^\[Auto #(\d+)\]\s*');

  static String wrap(int number, String prompt) => '[Auto #$number]\n$prompt';

  static int? parseNumber(String text) {
    final m = prefixRe.firstMatch(text.trimLeft());
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }

  static String displayBody(String text) {
    final trimmed = text.trimLeft();
    final m = prefixRe.firstMatch(trimmed);
    if (m == null) return text;
    return trimmed.substring(m.end);
  }
}

/// A prompt that Agent Dock should deliver to an existing chat on a schedule.
///
/// Execution lives on the host ADSM scheduler; the phone keeps a SQLite cache
/// and syncs via `schedules.*` RPCs.
class ScheduledJob {
  const ScheduledJob({
    required this.id,
    required this.number,
    required this.title,
    required this.chatId,
    required this.prompt,
    required this.kind,
    this.enabled = true,
    this.intervalMinutes,
    this.hour,
    this.minute,
    this.weekdays = const [],
    required this.nextRunAt,
    this.lastRunAt,
    this.lastError,
    this.donePrompt,
    this.contextSummary,
    this.repeatUntilDone = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;

  /// Stable user-facing id (`#1`, `#2`, …). Never reused after delete.
  final int number;

  final String title;
  final String chatId;
  final String prompt;
  final ScheduleKind kind;
  final bool enabled;

  /// For [ScheduleKind.interval] — repeat every N minutes.
  final int? intervalMinutes;

  /// Local wall-clock hour for daily / weekly (0–23).
  final int? hour;

  /// Local wall-clock minute for daily / weekly (0–59).
  final int? minute;

  /// [DateTime.weekday] values (Mon=1 … Sun=7) for weekly schedules.
  final List<int> weekdays;

  final DateTime nextRunAt;
  final DateTime? lastRunAt;
  final String? lastError;

  /// Optional follow-up criteria; host asks the agent `DONE: yes/no`.
  final String? donePrompt;

  /// Optional compressed conversation blob prepended to each run.
  final String? contextSummary;

  /// When true (and [donePrompt] set), keep repeating until DONE: yes.
  final bool repeatUntilDone;

  final DateTime createdAt;
  final DateTime updatedAt;

  String get numberLabel => '#$number';

  Map<String, Object?> toMap() => {
        'id': id,
        'number': number,
        'title': title,
        'chat_id': chatId,
        'prompt': prompt,
        'kind': kind.name,
        'enabled': enabled ? 1 : 0,
        'interval_minutes': intervalMinutes,
        'hour': hour,
        'minute': minute,
        'weekdays': weekdays.isEmpty ? null : weekdays.join(','),
        'next_run_at': nextRunAt.toIso8601String(),
        'last_run_at': lastRunAt?.toIso8601String(),
        'last_error': lastError,
        'done_prompt': donePrompt,
        'context_summary': contextSummary,
        'repeat_until_done': repeatUntilDone ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  /// Payload for ADSM `schedules.upsert` (camelCase + host ensure fields).
  Map<String, dynamic> toHostJson({
    String? cwd,
    String? binary,
    String? provider,
    String? modelId,
    String? resumeSessionId,
    bool fullAccess = true,
    bool permissionAsk = false,
  }) {
    return {
      'id': id,
      'number': number,
      'title': title,
      'chatId': chatId,
      'prompt': prompt,
      'kind': kind.name,
      'enabled': enabled,
      'intervalMinutes': intervalMinutes,
      'hour': hour,
      'minute': minute,
      'weekdays': weekdays,
      'nextRunAt': nextRunAt.toUtc().toIso8601String(),
      'lastRunAt': lastRunAt?.toUtc().toIso8601String(),
      'lastError': lastError,
      'donePrompt': donePrompt,
      'contextSummary': contextSummary,
      'repeatUntilDone': repeatUntilDone,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'updatedAt': updatedAt.toUtc().toIso8601String(),
      if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
      if (binary != null && binary.isNotEmpty) 'binary': binary,
      if (provider != null && provider.isNotEmpty) 'provider': provider,
      if (modelId != null && modelId.isNotEmpty) 'modelId': modelId,
      if (resumeSessionId != null && resumeSessionId.isNotEmpty)
        'resumeSessionId': resumeSessionId,
      'fullAccess': fullAccess,
      'permissionAsk': permissionAsk,
    };
  }

  factory ScheduledJob.fromMap(Map<String, Object?> map) {
    final rawDays = map['weekdays'] as String?;
    final days = <int>[];
    if (rawDays != null && rawDays.isNotEmpty) {
      for (final part in rawDays.split(',')) {
        final n = int.tryParse(part.trim());
        if (n != null && n >= 1 && n <= 7) days.add(n);
      }
    }
    return ScheduledJob(
      id: map['id']! as String,
      number: (map['number'] as int?) ?? 0,
      title: map['title']! as String,
      chatId: map['chat_id']! as String,
      prompt: map['prompt']! as String,
      kind: ScheduleKind.fromId(map['kind'] as String?),
      enabled: (map['enabled'] as int? ?? 0) == 1,
      intervalMinutes: map['interval_minutes'] as int?,
      hour: map['hour'] as int?,
      minute: map['minute'] as int?,
      weekdays: days,
      nextRunAt: DateTime.parse(map['next_run_at']! as String),
      lastRunAt: DateTime.tryParse((map['last_run_at'] as String?) ?? ''),
      lastError: map['last_error'] as String?,
      donePrompt: map['done_prompt'] as String?,
      contextSummary: map['context_summary'] as String?,
      repeatUntilDone: (map['repeat_until_done'] as int? ?? 0) == 1,
      createdAt: DateTime.parse(map['created_at']! as String),
      updatedAt: DateTime.parse(map['updated_at']! as String),
    );
  }

  factory ScheduledJob.fromHostJson(Map<String, dynamic> json) {
    final daysRaw = json['weekdays'];
    final days = <int>[];
    if (daysRaw is List) {
      for (final d in daysRaw) {
        final n = d is int ? d : int.tryParse('$d');
        if (n != null && n >= 1 && n <= 7) days.add(n);
      }
    }
    DateTime parseRequired(String key, {DateTime? fallback}) {
      final raw = json[key];
      if (raw is String && raw.isNotEmpty) {
        return DateTime.parse(raw);
      }
      return fallback ?? DateTime.now().toUtc();
    }

    DateTime? parseOpt(String key) {
      final raw = json[key];
      if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
      return null;
    }

    return ScheduledJob(
      id: '${json['id']}',
      number: (json['number'] as num?)?.toInt() ?? 0,
      title: '${json['title'] ?? ''}',
      chatId: '${json['chatId'] ?? ''}',
      prompt: '${json['prompt'] ?? ''}',
      kind: ScheduleKind.fromId(json['kind']?.toString()),
      enabled: json['enabled'] != false,
      intervalMinutes: (json['intervalMinutes'] as num?)?.toInt(),
      hour: (json['hour'] as num?)?.toInt(),
      minute: (json['minute'] as num?)?.toInt(),
      weekdays: days,
      nextRunAt: parseRequired('nextRunAt'),
      lastRunAt: parseOpt('lastRunAt'),
      lastError: json['lastError']?.toString(),
      donePrompt: (json['donePrompt'] as String?)?.trim().isEmpty == true
          ? null
          : json['donePrompt']?.toString(),
      contextSummary:
          (json['contextSummary'] as String?)?.trim().isEmpty == true
              ? null
              : json['contextSummary']?.toString(),
      repeatUntilDone: json['repeatUntilDone'] == true,
      createdAt: parseRequired('createdAt'),
      updatedAt: parseRequired('updatedAt'),
    );
  }

  ScheduledJob copyWith({
    int? number,
    String? title,
    String? chatId,
    String? prompt,
    ScheduleKind? kind,
    bool? enabled,
    int? intervalMinutes,
    int? hour,
    int? minute,
    List<int>? weekdays,
    DateTime? nextRunAt,
    DateTime? lastRunAt,
    String? lastError,
    bool clearError = false,
    String? donePrompt,
    bool clearDonePrompt = false,
    String? contextSummary,
    bool clearContextSummary = false,
    bool? repeatUntilDone,
    DateTime? updatedAt,
  }) =>
      ScheduledJob(
        id: id,
        number: number ?? this.number,
        title: title ?? this.title,
        chatId: chatId ?? this.chatId,
        prompt: prompt ?? this.prompt,
        kind: kind ?? this.kind,
        enabled: enabled ?? this.enabled,
        intervalMinutes: intervalMinutes ?? this.intervalMinutes,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        weekdays: weekdays ?? this.weekdays,
        nextRunAt: nextRunAt ?? this.nextRunAt,
        lastRunAt: lastRunAt ?? this.lastRunAt,
        lastError: clearError ? null : (lastError ?? this.lastError),
        donePrompt:
            clearDonePrompt ? null : (donePrompt ?? this.donePrompt),
        contextSummary: clearContextSummary
            ? null
            : (contextSummary ?? this.contextSummary),
        repeatUntilDone: repeatUntilDone ?? this.repeatUntilDone,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// Human-readable cadence for list tiles.
  String get scheduleSummary {
    switch (kind) {
      case ScheduleKind.once:
        return 'Once · ${_fmt(nextRunAt)}';
      case ScheduleKind.interval:
        final m = intervalMinutes ?? 60;
        if (m < 60) return 'Every $m min';
        if (m % 60 == 0) {
          final h = m ~/ 60;
          return h == 1 ? 'Every hour' : 'Every $h hours';
        }
        return 'Every $m min';
      case ScheduleKind.daily:
        return 'Daily at ${_pad(hour ?? 9)}:${_pad(minute ?? 0)}';
      case ScheduleKind.weekly:
        final names = weekdays.map(_weekdayName).join(', ');
        return 'Weekly · $names · ${_pad(hour ?? 9)}:${_pad(minute ?? 0)}';
    }
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');

  static String _fmt(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-'
        '${_pad(local.month)}-'
        '${_pad(local.day)} '
        '${_pad(local.hour)}:${_pad(local.minute)}';
  }

  static String _weekdayName(int d) => switch (d) {
        1 => 'Mon',
        2 => 'Tue',
        3 => 'Wed',
        4 => 'Thu',
        5 => 'Fri',
        6 => 'Sat',
        7 => 'Sun',
        _ => '?',
      };

  /// Next fire time strictly after [from], or null when a one-shot is done.
  static DateTime? computeNextRun(ScheduledJob job, DateTime from) {
    switch (job.kind) {
      case ScheduleKind.once:
        return null;
      case ScheduleKind.interval:
        final mins = (job.intervalMinutes ?? 60).clamp(1, 60 * 24 * 30);
        return from.add(Duration(minutes: mins));
      case ScheduleKind.daily:
        final h = job.hour ?? 9;
        final m = job.minute ?? 0;
        var next = DateTime(from.year, from.month, from.day, h, m);
        if (!next.isAfter(from)) {
          next = next.add(const Duration(days: 1));
        }
        return next;
      case ScheduleKind.weekly:
        final h = job.hour ?? 9;
        final m = job.minute ?? 0;
        final days = job.weekdays.isEmpty ? [from.weekday] : [...job.weekdays]
          ..sort();
        for (var offset = 0; offset <= 7; offset++) {
          final candidateDay = from.add(Duration(days: offset));
          if (!days.contains(candidateDay.weekday)) continue;
          final next = DateTime(
            candidateDay.year,
            candidateDay.month,
            candidateDay.day,
            h,
            m,
          );
          if (next.isAfter(from)) return next;
        }
        // Fallback: one week later same slot.
        return DateTime(from.year, from.month, from.day, h, m)
            .add(const Duration(days: 7));
    }
  }

  /// First fire time when creating/editing a schedule, using [preferred] if set.
  static DateTime initialNextRun({
    required ScheduleKind kind,
    required DateTime now,
    DateTime? preferred,
    int? intervalMinutes,
    int? hour,
    int? minute,
    List<int> weekdays = const [],
  }) {
    if (preferred != null && preferred.isAfter(now)) return preferred;
    final draft = ScheduledJob(
      id: '',
      number: 0,
      title: '',
      chatId: '',
      prompt: '',
      kind: kind,
      intervalMinutes: intervalMinutes,
      hour: hour,
      minute: minute,
      weekdays: weekdays,
      nextRunAt: now,
      createdAt: now,
      updatedAt: now,
    );
    if (kind == ScheduleKind.once) {
      return preferred ?? now.add(const Duration(minutes: 5));
    }
    if (kind == ScheduleKind.interval) {
      final mins = (intervalMinutes ?? 60).clamp(1, 60 * 24 * 30);
      return now.add(Duration(minutes: mins));
    }
    return computeNextRun(draft, now.subtract(const Duration(seconds: 1))) ??
        now.add(const Duration(minutes: 5));
  }
}
