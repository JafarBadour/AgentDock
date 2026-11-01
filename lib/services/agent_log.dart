/// Reading `~/.agentdock/adsm.log` well enough to answer "why did my agent
/// disconnect?".
///
/// The daemon writes plain lines. From 0.7.11 each carries a UTC timestamp;
/// older daemons wrote none, so everything here treats the time as optional
/// rather than refusing to parse a log from a host that has not updated yet.
library;

/// A log as read from a host: its text, and when the file was last written.
///
/// The mtime is what lets the app put a time on a log from a daemon too old
/// to stamp its own lines — the last line was written then, and everything
/// above it before that.
class AgentLogSnapshot {
  const AgentLogSnapshot({required this.text, this.modified});

  final String text;
  final DateTime? modified;

  /// Split the header the host's reader script prints from the log itself.
  factory AgentLogSnapshot.parse(String raw) {
    const marker = '#adsm-log-mtime ';
    final lines = raw.split('\n');
    DateTime? modified;
    var start = 0;
    for (var i = 0; i < lines.length && i < 3; i++) {
      final line = lines[i].trim();
      if (!line.startsWith(marker)) continue;
      final epoch = int.tryParse(line.substring(marker.length).trim());
      if (epoch != null) {
        modified = DateTime.fromMillisecondsSinceEpoch(
          epoch * 1000,
          isUtc: true,
        );
      }
      start = i + 1;
      break;
    }
    return AgentLogSnapshot(
      text: lines.skip(start).join('\n'),
      modified: modified,
    );
  }
}

/// How much the app actually knows about when something happened.
enum TimeCertainty {
  /// The daemon stamped the line itself.
  exact,

  /// Not stamped, but it is the last line in the log, so it landed when the
  /// file was last written.
  approximate,

  /// Not stamped and not last, so it happened at least that long ago.
  atLeast,
}

/// What a log line is telling you.
enum AgentLogKind {
  /// The 15-minute reaper stopped an idle worker. The usual answer.
  idleStop,

  /// Leaked agent child processes were cleaned up.
  reaped,

  /// Something went wrong — a failed stop, a traceback, a daemon error.
  failure,

  /// Anything else, kept so the raw log still reads in order.
  other,
}

/// One line of the daemon log.
class AgentLogLine {
  const AgentLogLine({
    required this.raw,
    required this.message,
    required this.kind,
    this.at,
    this.chatId,
    this.idleSeconds,
  });

  /// The line exactly as written, for the raw view.
  final String raw;

  /// The line with any timestamp prefix removed.
  final String message;

  final AgentLogKind kind;

  /// Null on a log from a daemon older than 0.7.11.
  final DateTime? at;

  /// The chat this line is about, when it names one.
  final String? chatId;

  /// How long the worker had been idle, for [AgentLogKind.idleStop].
  final int? idleSeconds;

  bool get isAbout => chatId != null;
}

final _stamp = RegExp(
  r'^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)\s+',
);
final _idleStop = RegExp(
  r'stopping idle worker (\S+)\s+\(idle (\d+)s\)',
  caseSensitive: false,
);
final _idleStopFailed = RegExp(r'idle stop failed (\S+)', caseSensitive: false);
final _reaped = RegExp(
  r'reaped \d+ stale claude process\(es\) for (\S+)',
  caseSensitive: false,
);
final _reapKilled = RegExp(
  r'killed \d+ stale claude child\(ren\) for (\S+)',
  caseSensitive: false,
);
final _failureWords = RegExp(
  r'traceback|error|failed|exception|refused|denied',
  caseSensitive: false,
);

/// Parse the daemon log, newest last — the order the file is written in.
List<AgentLogLine> parseAgentLog(String text) {
  final out = <AgentLogLine>[];
  for (final raw in text.split('\n')) {
    if (raw.trim().isEmpty) continue;
    DateTime? at;
    var message = raw;
    final stamped = _stamp.firstMatch(raw);
    if (stamped != null) {
      at = DateTime.tryParse(stamped.group(1)!.replaceFirst(' ', 'T'))?.toUtc();
      message = raw.substring(stamped.end);
    }

    String? chatId;
    int? idle;
    var kind = AgentLogKind.other;

    final stop = _idleStop.firstMatch(message);
    final stopFailed = _idleStopFailed.firstMatch(message);
    final reap = _reaped.firstMatch(message) ?? _reapKilled.firstMatch(message);
    if (stop != null) {
      kind = AgentLogKind.idleStop;
      chatId = stop.group(1);
      idle = int.tryParse(stop.group(2)!);
    } else if (stopFailed != null) {
      kind = AgentLogKind.failure;
      chatId = stopFailed.group(1)?.replaceAll(RegExp(r':$'), '');
    } else if (reap != null) {
      kind = AgentLogKind.reaped;
      chatId = reap.group(1);
    } else if (_failureWords.hasMatch(message)) {
      kind = AgentLogKind.failure;
    }

    out.add(
      AgentLogLine(
        raw: raw,
        message: message,
        kind: kind,
        at: at,
        chatId: chatId,
        idleSeconds: idle,
      ),
    );
  }
  return out;
}

/// A plain answer to "why did this agent stop?".
class AgentStopReason {
  const AgentStopReason({
    required this.headline,
    required this.detail,
    required this.kind,
    this.at,
    this.certainty = TimeCertainty.exact,
    this.occurrences = 1,
  });

  final String headline;
  final String detail;
  final AgentLogKind kind;

  /// When it last happened. Read [certainty] before presenting it — on an
  /// unstamped log this is derived from the file's last write, not read.
  final DateTime? at;

  /// How much that time is worth.
  final TimeCertainty certainty;

  /// How many times this log holds the same thing, so a loop is visible.
  final int occurrences;
}

/// Why [chatId] last stopped, from [lines], or null if the log never says.
///
/// Prefers a failure over a routine idle stop when both are present for this
/// chat: the idle stop is expected and the failure is the thing worth reading.
AgentStopReason? explainLastStop(
  List<AgentLogLine> lines, {
  required String chatId,
  DateTime? fileModified,
}) {
  final mine = lines.where((l) => l.chatId == chatId).toList();
  if (mine.isEmpty) return null;

  final failures = mine.where((l) => l.kind == AgentLogKind.failure).toList();
  final stops = mine.where((l) => l.kind == AgentLogKind.idleStop).toList();

  /// An unstamped line still has a knowable time: the file's last write dates
  /// the final line, and bounds every line above it.
  (DateTime?, TimeCertainty) dateOf(AgentLogLine line) {
    if (line.at != null) return (line.at, TimeCertainty.exact);
    // `exact` means the line said so. With nothing to date it against there
    // is no time to show, but it is still not an exact reading.
    if (fileModified == null) return (null, TimeCertainty.atLeast);
    final isLast = lines.isNotEmpty && identical(lines.last, line);
    return (
      fileModified,
      isLast ? TimeCertainty.approximate : TimeCertainty.atLeast,
    );
  }

  if (failures.isNotEmpty) {
    final last = failures.last;
    final (at, certainty) = dateOf(last);
    return AgentStopReason(
      headline: 'The host hit an error',
      detail: last.message,
      kind: AgentLogKind.failure,
      at: at,
      certainty: certainty,
      occurrences: failures.length,
    );
  }
  if (stops.isNotEmpty) {
    final last = stops.last;
    final (at, certainty) = dateOf(last);
    // Floor, not round: the reaper fires on a maintenance tick a little
    // after the 15-minute mark, and 955s rounding up to "16 minutes" next to
    // a detail line that says 15 just reads like a contradiction.
    final minutes = (last.idleSeconds ?? 0) ~/ 60;
    return AgentStopReason(
      headline: 'Stopped after $minutes minutes idle',
      detail:
          'The host stops an agent that has been idle for 15 minutes to free '
          'it. Your next message starts it again — nothing was lost.',
      kind: AgentLogKind.idleStop,
      at: at,
      certainty: certainty,
      occurrences: stops.length,
    );
  }
  return null;
}

/// "3 min ago" / "~3 min ago" / "over 3 min ago", or null with no time.
///
/// The qualifier is not decoration: on a host that does not stamp its log the
/// time is inferred from the file's last write, and saying so plainly beats
/// presenting a guess as a reading.
String? agoLabel(
  DateTime? at, {
  DateTime? now,
  TimeCertainty certainty = TimeCertainty.exact,
}) {
  if (at == null) return null;
  final base = _ago(at, now: now);
  return switch (certainty) {
    TimeCertainty.exact => base,
    TimeCertainty.approximate => '~$base',
    TimeCertainty.atLeast => base == 'just now' ? base : 'over $base',
  };
}

String _ago(DateTime at, {DateTime? now}) {
  final delta = (now ?? DateTime.now().toUtc()).difference(at);
  if (delta.isNegative || delta.inSeconds < 45) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) {
    return '${delta.inHours} hour${delta.inHours == 1 ? '' : 's'} ago';
  }
  return '${delta.inDays} day${delta.inDays == 1 ? '' : 's'} ago';
}
