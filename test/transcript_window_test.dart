import 'package:agent_dock/features/agents/transcript_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TranscriptWindow.sync', () {
    test('small transcript starts at 0', () {
      final w = TranscriptWindow(pageSize: 10, softMax: 14);
      w.visibleCount = 10;
      w.start = 5;
      w.sync(7, followOutput: false);
      expect(w.start, 0);
      expect(w.hiddenOlder(), 0);
    });

    test('followOutput pins flag and keeps tail window', () {
      final w = TranscriptWindow(pageSize: 10, softMax: 14);
      w.pinnedToEnd = false;
      w.visibleCount = 10;
      w.sync(100, followOutput: true);
      expect(w.start, 90);
      expect(w.pinnedToEnd, isTrue);
      expect(w.hiddenNewer(100), 0);
    });

    test('expanded history is not shrunk on sync', () {
      final w = TranscriptWindow(pageSize: 10, softMax: 14)
        ..visibleCount = 40
        ..pinnedToEnd = false;
      w.sync(100, followOutput: false);
      expect(w.visibleCount, 40);
      expect(w.start, 60);
    });

    test('exact pageSize boundary stays at 0', () {
      final w = TranscriptWindow(pageSize: 10, softMax: 14);
      w.sync(10, followOutput: true);
      expect(w.start, 0);
      expect(w.pinnedToEnd, isTrue);
    });
  });

  group('TranscriptWindow.pinToLatest', () {
    test('resets to one page at the end', () {
      final w = TranscriptWindow(pageSize: 10, softMax: 14)
        ..visibleCount = 50
        ..pinnedToEnd = false
        ..start = 0;
      w.pinToLatest(55);
      expect(w.visibleCount, 10);
      expect(w.start, 45);
      expect(w.pinnedToEnd, isTrue);
    });

    test('small lists start at 0', () {
      final w = TranscriptWindow(pageSize: 10, softMax: 14)..visibleCount = 40;
      w.pinToLatest(5);
      expect(w.start, 0);
      expect(w.visibleCount, 5);
    });
  });

  group('TranscriptWindow.visibleSlice / hidden', () {
    test('returns full list when shorter than window', () {
      final w = TranscriptWindow(pageSize: 10, softMax: 14);
      w.sync(4, followOutput: true);
      final all = [1, 2, 3, 4];
      expect(w.visibleSlice(all), [1, 2, 3, 4]);
      expect(w.hiddenOlder(), 0);
      expect(w.hiddenNewer(4), 0);
    });

    test('tail slice never hides newer rows', () {
      final w = TranscriptWindow(pageSize: 5, softMax: 7)
        ..visibleCount = 5
        ..pinnedToEnd = false;
      w.sync(30, followOutput: false);
      final all = List.generate(30, (i) => i);
      expect(w.visibleSlice(all), [25, 26, 27, 28, 29]);
      expect(w.hiddenOlder(), 25);
      expect(w.hiddenNewer(30), 0);
    });

    test('empty list stays empty', () {
      final w = TranscriptWindow();
      expect(w.visibleSlice(<int>[]), isEmpty);
      expect(w.endExclusive(0), 0);
      expect(w.hiddenNewer(0), 0);
    });
  });

  group('TranscriptWindow.loadOlder', () {
    final now = DateTime(2026, 9, 8, 4);

    test('loads one page and reports count', () {
      final w = TranscriptWindow(
        pageSize: 10,
        softMax: 14,
        cooldown: Duration.zero,
      );
      w.sync(50, followOutput: true);
      expect(w.loadOlder(50, now: now), 10);
      expect(w.visibleCount, 20);
      expect(w.start, 30);
      expect(w.pinnedToEnd, isFalse);
    });

    test('clamps at full transcript', () {
      final w = TranscriptWindow(
        pageSize: 10,
        softMax: 14,
        cooldown: Duration.zero,
      );
      w.sync(15, followOutput: true);
      expect(w.loadOlder(15, now: now), 5);
      expect(w.visibleCount, 15);
      expect(w.start, 0);
      expect(w.loadOlder(15, now: now.add(const Duration(seconds: 1))), 0);
    });

    test('loads with force ignoring cooldown', () {
      final w = TranscriptWindow(
        pageSize: 10,
        softMax: 14,
        cooldown: const Duration(minutes: 1),
      );
      w.sync(50, followOutput: true);
      expect(w.loadOlder(50, now: now), 10);
      expect(w.loadOlder(50, now: now, force: true), 10);
      expect(w.visibleCount, 30);
    });
  });

  group('TranscriptWindow.trimOlderTowardEnd', () {
    final now = DateTime(2026, 9, 8, 4);

    test('does nothing at or below softMax', () {
      final w = TranscriptWindow(
        pageSize: 300,
        softMax: 370,
        cooldown: Duration.zero,
      )..visibleCount = 370;
      expect(w.trimOlderTowardEnd(1000, now: now), 0);
      expect(w.visibleCount, 370);
    });

    test('ditches one pageSize when above softMax', () {
      final w = TranscriptWindow(
        pageSize: 300,
        softMax: 370,
        cooldown: Duration.zero,
      )
        ..visibleCount = 600
        ..pinnedToEnd = false;
      w.sync(1000, followOutput: false);
      expect(w.trimOlderTowardEnd(1000, now: now), 300);
      expect(w.visibleCount, 300);
      expect(w.start, 700);
    });

    test('tryTrimOlderNearBottom only near live end', () {
      final w = TranscriptWindow(
        pageSize: 10,
        softMax: 14,
        edgePx: 80,
        cooldown: Duration.zero,
      )..visibleCount = 30;
      w.sync(100, followOutput: false);
      expect(
        w.tryTrimOlderNearBottom(
          total: 100,
          pixels: 100,
          maxScrollExtent: 2000,
          now: now,
        ),
        isFalse,
      );
      expect(
        w.tryTrimOlderNearBottom(
          total: 100,
          pixels: 1950,
          maxScrollExtent: 2000,
          now: now,
        ),
        isTrue,
      );
      expect(w.visibleCount, 20);
    });
  });

  group('TranscriptWindow.tryLoadOlderAtTop', () {
    final now = DateTime(2026, 9, 8, 4);

    TranscriptWindow window() => TranscriptWindow(
          pageSize: 10,
          softMax: 14,
          edgePx: 80,
          cooldown: Duration.zero,
        );

    test('busy flag blocks load', () {
      final w = window()..sync(50, followOutput: true);
      expect(
        w.tryLoadOlderAtTop(
          total: 50,
          pixels: 0,
          maxScrollExtent: 1000,
          now: now,
          busy: true,
        ),
        isFalse,
      );
    });

    test('loads near top edge', () {
      final w = window()..sync(50, followOutput: true);
      expect(
        w.tryLoadOlderAtTop(
          total: 50,
          pixels: 40,
          maxScrollExtent: 1000,
          now: now,
        ),
        isTrue,
      );
      expect(w.visibleCount, 20);
    });

    test('does not load when scrolled away from top', () {
      final w = window()..sync(50, followOutput: true);
      expect(
        w.tryLoadOlderAtTop(
          total: 50,
          pixels: 200,
          maxScrollExtent: 1000,
          now: now,
        ),
        isFalse,
      );
    });
  });

  group('TranscriptWindow.preserveScroll', () {
    final w = TranscriptWindow();

    test('prepend keeps thumb on the same content', () {
      final t = w.preserveScrollAfterPrepend(
        beforePixels: 100,
        beforeMax: 1000,
        afterMax: 1400,
      );
      expect(t, 500);
    });

    test('trim keeps thumb on the same content', () {
      final t = w.preserveScrollAfterTrim(
        beforePixels: 500,
        beforeMax: 1400,
        afterMax: 1000,
      );
      expect(t, 100);
    });

    test('zero afterMax returns 0', () {
      expect(
        w.preserveScrollAfterPrepend(
          beforePixels: 10,
          beforeMax: 0,
          afterMax: 0,
        ),
        0,
      );
    });
  });
}
