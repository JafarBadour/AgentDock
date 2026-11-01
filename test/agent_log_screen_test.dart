import 'package:agentplantation/data/models/host.dart';
import 'package:agentplantation/features/agents/agent_log_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _host = Host(
  id: 'h1',
  alias: 'Colibri VDI',
  hostname: 'localhost',
  username: 'jafar',
  port: 2255,
  createdAt: DateTime(2026),
);

const _chat = 'af2d7b83-feb4-4f95-accf-27e6f168ad6a';

Widget _app(String log, {String chatId = _chat}) => ProviderScope(
  child: MaterialApp(
    home: AgentLogScreen(
      host: _host,
      chatId: chatId,
      chatTitle: 'Work[ColibriVDI]',
      fetchOverride: () async => log,
    ),
  ),
);

void main() {
  testWidgets('says why the agent stopped instead of only listing lines', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        '2026-10-31T00:10:00+00:00 ADSM maintenance: '
        'stopping idle worker $_chat (idle 905s)',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stopped after 15 minutes idle'), findsOneWidget);
    expect(find.textContaining('nothing was lost'), findsOneWidget);
  });

  testWidgets('a failure is surfaced over a routine stop', (tester) async {
    await tester.pumpWidget(
      _app(
        '2026-10-31T00:10:00+00:00 ADSM maintenance: '
        'stopping idle worker $_chat (idle 905s)\n'
        '2026-10-31T00:20:00+00:00 ADSM idle stop failed $_chat: boom',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('The host hit an error'), findsOneWidget);
    expect(find.textContaining('boom'), findsWidgets);
  });

  testWidgets('filters to this agent, and can show the whole host', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        'ADSM maintenance: stopping idle worker $_chat (idle 905s)\n'
        'ADSM maintenance: stopping idle worker someone-else (idle 900s)',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 lines'), findsOneWidget);

    await tester.tap(find.text('Whole host'));
    await tester.pumpAndSettle();
    expect(find.text('2 lines'), findsOneWidget);
  });

  testWidgets('an untimestamped host is dated from the file, and says so', (
    tester,
  ) async {
    // Better than "no idea when": the log file's last write dates the last
    // line. The card must show the time *and* admit where it came from.
    final written = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    await tester.pumpWidget(
      _app(
        '#adsm-log-mtime ${written.millisecondsSinceEpoch ~/ 1000}\n'
        'ADSM maintenance: stopping idle worker $_chat (idle 905s)',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('~5 min ago'), findsOneWidget);
    expect(find.textContaining('not the line'), findsOneWidget);
  });

  testWidgets('with no file time at all it still refuses to guess', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app('ADSM maintenance: stopping idle worker $_chat (idle 905s)'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('no time to show'), findsOneWidget);
  });

  testWidgets('a chat the log never mentions gets no invented reason', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        'ADSM maintenance: stopping idle worker other (idle 905s)',
        chatId: 'unseen',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stopped after 15 minutes idle'), findsNothing);
    expect(find.textContaining('Nothing in the log mentions'), findsOneWidget);
  });
}
