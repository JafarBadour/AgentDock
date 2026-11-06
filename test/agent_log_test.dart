import 'package:agentplantation/services/agent_log.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real lines, copied from a daemon log on This Mac. Older daemons wrote no
/// timestamp at all, which is why the parser treats the time as optional.
const _legacy = '''
ADSM maintenance: stopping idle worker 94b45ad2-c1bc-447d-8e51-79f746850e66 (idle 900s)
ADSM maintenance: stopping idle worker af2d7b83-feb4-4f95-accf-27e6f168ad6a (idle 947s)
Future exception was never retrieved
future: <Future finished exception=RuntimeError('agent FIFO recycled')>
RuntimeError: agent FIFO recycled
ADSM maintenance: stopping idle worker af2d7b83-feb4-4f95-accf-27e6f168ad6a (idle 930s)
''';

/// What 0.7.11 writes.
const _stamped = '''
2026-10-31T00:10:00+00:00 ADSM maintenance: stopping idle worker chat-a (idle 905s)
2026-10-31T00:30:00+00:00 ADSM maintenance: reaped 3 stale claude process(es) for chat-a
2026-10-31T00:40:00+00:00 ADSM idle stop failed chat-a: boom
''';

void main() {
  group('parsing', () {
    test('reads an idle stop, with its chat and how long it was idle', () {
      final lines = parseAgentLog(_stamped);
      final stop = lines.first;
      expect(stop.kind, AgentLogKind.idleStop);
      expect(stop.chatId, 'chat-a');
      expect(stop.idleSeconds, 905);
      expect(stop.at, DateTime.utc(2026, 10, 31, 0, 10));
    });

    test('a log with no timestamps still parses', () {
      // A host that has not been updated yet must not come back empty.
      final lines = parseAgentLog(_legacy);
      expect(lines, isNotEmpty);
      final stops = lines.where((l) => l.kind == AgentLogKind.idleStop);
      expect(stops.length, 3);
      expect(stops.every((l) => l.at == null), isTrue);
      expect(
        stops.map((l) => l.chatId),
        containsAll(<String>[
          '94b45ad2-c1bc-447d-8e51-79f746850e66',
          'af2d7b83-feb4-4f95-accf-27e6f168ad6a',
        ]),
      );
    });

    test('classifies reaps and failures', () {
      final lines = parseAgentLog(_stamped);
      expect(lines[1].kind, AgentLogKind.reaped);
      expect(lines[1].chatId, 'chat-a');
      expect(lines[2].kind, AgentLogKind.failure);
      expect(lines[2].chatId, 'chat-a');
    });

    test('a traceback counts as a failure even with no chat', () {
      final lines = parseAgentLog(_legacy);
      final fail = lines.where((l) => l.kind == AgentLogKind.failure);
      expect(fail, isNotEmpty);
      expect(fail.every((l) => l.chatId == null), isTrue);
    });

    test('the 0.7.12 line shape still reads as an idle stop', () {
      // The host now appends ", limit Ns, watchers N". A parser that
      // required the closing paren would quietly stop recognising these,
      // and "why did my agent stop?" would go back to having no answer.
      final lines = parseAgentLog(
        '2026-11-05T01:00:00+00:00 ADSM maintenance: stopping idle worker '
        'chat-z (idle 905s, limit 900s, watchers 0)',
      );
      expect(lines.single.kind, AgentLogKind.idleStop);
      expect(lines.single.chatId, 'chat-z');
      expect(lines.single.idleSeconds, 905);
    });

    test('blank lines are dropped, order is kept', () {
      final lines = parseAgentLog('a\n\n\nb\n');
      expect(lines.map((l) => l.raw), ['a', 'b']);
    });

    test('the raw line survives for the verbatim view', () {
      final lines = parseAgentLog(_stamped);
      expect(lines.first.raw, startsWith('2026-10-31T00:10:00+00:00'));
      expect(lines.first.message, startsWith('ADSM maintenance'));
    });
  });

  group('explaining a stop', () {
    test('says plainly that the idle reaper did it', () {
      final r = explainLastStop(parseAgentLog(_stamped), chatId: 'chat-a');
      // "chat-a" also has a failure, which wins — check the pure case.
      final onlyStops = parseAgentLog(
        '2026-10-31T00:10:00+00:00 ADSM maintenance: '
        'stopping idle worker chat-b (idle 905s)',
      );
      final s = explainLastStop(onlyStops, chatId: 'chat-b');
      expect(s!.kind, AgentLogKind.idleStop);
      expect(s.headline, 'Stopped after 15 minutes idle');
      // 955s is still a 15-minute policy, not a 16-minute one.
      final late = explainLastStop(
        parseAgentLog('ADSM maintenance: stopping idle worker c (idle 955s)'),
        chatId: 'c',
      );
      expect(late!.headline, 'Stopped after 15 minutes idle');
      expect(s.detail, contains('nothing was lost'));
      expect(r, isNotNull);
    });

    test('a failure outranks a routine idle stop', () {
      // The idle stop is expected; the error is the thing worth reading.
      final r = explainLastStop(parseAgentLog(_stamped), chatId: 'chat-a');
      expect(r!.kind, AgentLogKind.failure);
      expect(r.detail, contains('boom'));
    });

    test('counts repeats so a loop is visible', () {
      final r = explainLastStop(parseAgentLog(_legacy),
          chatId: 'af2d7b83-feb4-4f95-accf-27e6f168ad6a');
      expect(r!.kind, AgentLogKind.idleStop);
      expect(r.occurrences, 2);
    });

    test('says nothing rather than guessing for an unseen chat', () {
      expect(explainLastStop(parseAgentLog(_stamped), chatId: 'nope'), isNull);
      expect(explainLastStop(const [], chatId: 'chat-a'), isNull);
    });

    test('no timestamp means no time claimed', () {
      final r = explainLastStop(parseAgentLog(_legacy),
          chatId: 'af2d7b83-feb4-4f95-accf-27e6f168ad6a');
      expect(r!.at, isNull);
      expect(agoLabel(r.at), isNull);
    });
  });

  group('dating a log the host did not stamp', () {
    // The whole point: an old daemon writes bare lines, and "no idea when"
    // is a worse answer than "the file was last written then".
    const bare =
        'ADSM maintenance: stopping idle worker other (idle 900s)\n'
        'ADSM maintenance: stopping idle worker mine (idle 910s)';
    final written = DateTime.utc(2026, 10, 31, 12);

    test('the last line is dated from the file write', () {
      final r = explainLastStop(
        parseAgentLog(bare),
        chatId: 'mine',
        fileModified: written,
      );
      expect(r!.at, written);
      expect(r.certainty, TimeCertainty.approximate);
    });

    test('an earlier line is only bounded, never claimed', () {
      final r = explainLastStop(
        parseAgentLog(bare),
        chatId: 'other',
        fileModified: written,
      );
      expect(r!.at, written);
      expect(r.certainty, TimeCertainty.atLeast);
    });

    test('a stamped line ignores the file time', () {
      final r = explainLastStop(
        parseAgentLog(
          '2026-10-31T09:00:00+00:00 ADSM maintenance: '
          'stopping idle worker mine (idle 900s)',
        ),
        chatId: 'mine',
        fileModified: written,
      );
      expect(r!.at, DateTime.utc(2026, 10, 31, 9));
      expect(r.certainty, TimeCertainty.exact);
    });

    test('with no file time there is still no guess', () {
      final r = explainLastStop(parseAgentLog(bare), chatId: 'mine');
      expect(r!.at, isNull);
    });

    test('the qualifier says how much the time is worth', () {
      final now = DateTime.utc(2026, 10, 31, 12, 5);
      expect(agoLabel(written, now: now), '5 min ago');
      expect(
        agoLabel(written, now: now, certainty: TimeCertainty.approximate),
        '~5 min ago',
      );
      expect(
        agoLabel(written, now: now, certainty: TimeCertainty.atLeast),
        'over 5 min ago',
      );
    });

    test('"over just now" is never said', () {
      final now = DateTime.utc(2026, 10, 31, 12, 0, 5);
      expect(
        agoLabel(written, now: now, certainty: TimeCertainty.atLeast),
        'just now',
      );
    });
  });

  group('AgentLogSnapshot', () {
    test('splits the mtime header from the log', () {
      final snap = AgentLogSnapshot.parse(
        '#adsm-log-mtime 1793407112\nline one\nline two',
      );
      expect(snap.modified, DateTime.utc(2026, 10, 31, 0, 38, 32));
      expect(snap.text, 'line one\nline two');
    });

    test('a log with no header is still the whole log', () {
      final snap = AgentLogSnapshot.parse('line one\nline two');
      expect(snap.modified, isNull);
      expect(snap.text, 'line one\nline two');
    });

    test('a corrupt header is ignored rather than fatal', () {
      final snap = AgentLogSnapshot.parse('#adsm-log-mtime nonsense\nline');
      expect(snap.modified, isNull);
      expect(snap.text, 'line');
    });
  });

  group('agoLabel', () {
    final now = DateTime.utc(2026, 10, 31, 12);
    test('reads naturally at each scale', () {
      expect(agoLabel(now.subtract(const Duration(seconds: 5)), now: now),
          'just now');
      expect(agoLabel(now.subtract(const Duration(minutes: 7)), now: now),
          '7 min ago');
      expect(agoLabel(now.subtract(const Duration(hours: 1)), now: now),
          '1 hour ago');
      expect(agoLabel(now.subtract(const Duration(hours: 5)), now: now),
          '5 hours ago');
      expect(agoLabel(now.subtract(const Duration(days: 2)), now: now),
          '2 days ago');
    });

    test('a clock skewed into the future reads as just now, not negative', () {
      expect(agoLabel(now.add(const Duration(minutes: 5)), now: now),
          'just now');
    });

    test('null in, null out', () => expect(agoLabel(null), isNull));
  });
}
