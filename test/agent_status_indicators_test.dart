import 'package:agent_dock/features/agents/agent_status_indicators.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shortTimeAgo', () {
    final now = DateTime(2026, 6, 1, 12);

    test('collapses anything very recent to "now"', () {
      expect(shortTimeAgo(now, now: now), 'now');
      expect(
        shortTimeAgo(now.subtract(const Duration(seconds: 20)), now: now),
        'now',
      );
    });

    test('steps through minutes, hours, days, weeks, years', () {
      expect(
        shortTimeAgo(now.subtract(const Duration(minutes: 7)), now: now),
        '7m',
      );
      expect(
        shortTimeAgo(now.subtract(const Duration(hours: 3)), now: now),
        '3h',
      );
      expect(
        shortTimeAgo(now.subtract(const Duration(days: 4)), now: now),
        '4d',
      );
      expect(
        shortTimeAgo(now.subtract(const Duration(days: 20)), now: now),
        '2w',
      );
      expect(
        shortTimeAgo(now.subtract(const Duration(days: 800)), now: now),
        '2y',
      );
    });

    test('a clock skewed into the future does not print a negative age', () {
      expect(
        shortTimeAgo(now.add(const Duration(minutes: 5)), now: now),
        'now',
      );
    });
  });

  testWidgets('unread badge hides at zero and caps at 99+', (tester) async {
    Future<void> pump(int count) => tester.pumpWidget(
          MaterialApp(home: Scaffold(body: UnreadBadge(count: count))),
        );

    await pump(0);
    expect(find.byType(Text), findsNothing);

    await pump(3);
    expect(find.text('3'), findsOneWidget);

    await pump(1200);
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('working dots animate and dispose cleanly', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WorkingDots())),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(WorkingDots), findsOneWidget);

    // A repeating controller must not keep ticking once the row scrolls away.
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pumpAndSettle();
    expect(find.byType(WorkingDots), findsNothing);
  });
}
