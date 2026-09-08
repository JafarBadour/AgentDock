import 'package:agent_dock/features/agents/transcript_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TranscriptWindow.sync', () {
    test('small transcript always starts at 0 and pins to end', () {
      final w = TranscriptWindow(size: 10);
      w.start = 5;
      w.pinnedToEnd = false;
      w.sync(7, followOutput: false);
      expect(w.start, 0);
      expect(w.pinnedToEnd, isTrue);
    });

    test('followOutput pins to the latest window', () {
      final w = TranscriptWindow(size: 10);
      w.pinnedToEnd = false;
      w.start = 0;
      w.sync(100, followOutput: true);
      expect(w.start, 90);
      expect(w.pinnedToEnd, isTrue);
    });

    test('pinnedToEnd without follow still pins', () {
      final w = TranscriptWindow(size: 10)..pinnedToEnd = true;
      w.start = 0;
      w.sync(50, followOutput: false);
      expect(w.start, 40);
      expect(w.pinnedToEnd, isTrue);
    });

    test('unpinned clamps start when total shrinks', () {
      final w = TranscriptWindow(size: 10)
        ..pinnedToEnd = false
        ..start = 80;
      w.sync(50, followOutput: false);
      expect(w.start, 40);
    });

    test('unpinned clamps negative start to 0', () {
      final w = TranscriptWindow(size: 10)
        ..pinnedToEnd = false
        ..start = -3;
      w.sync(50, followOutput: false);
      expect(w.start, 0);
    });

    test('exact size boundary stays at 0', () {
      final w = TranscriptWindow(size: 10);
      w.sync(10, followOutput: true);
      expect(w.start, 0);
      expect(w.pinnedToEnd, isTrue);
    });
  });

  group('TranscriptWindow.pinToLatest', () {
    test('pins empty and small lists to 0', () {
      final w = TranscriptWindow(size: 10);
      w.pinToLatest(0);
      expect(w.start, 0);
      expect(w.pinnedToEnd, isTrue);
      w.pinToLatest(5);
      expect(w.start, 0);
    });

    test('pins large lists to total - size', () {
      final w = TranscriptWindow(size: 10);
      w.pinToLatest(55);
      expect(w.start, 45);
      expect(w.pinnedToEnd, isTrue);
    });
  });

  group('TranscriptWindow.visibleSlice / hidden', () {
    test('returns full list when shorter than window', () {
      final w = TranscriptWindow(size: 10);
      w.sync(4, followOutput: true);
      final all = [1, 2, 3, 4];
      expect(w.visibleSlice(all), [1, 2, 3, 4]);
      expect(w.hiddenOlder(), 0);
      expect(w.hiddenNewer(4), 0);
    });

    test('slices middle when scrolled back', () {
      final w = TranscriptWindow(size: 5)
        ..pinnedToEnd = false
        ..start = 10;
      final all = List.generate(30, (i) => i);
      expect(w.visibleSlice(all), [10, 11, 12, 13, 14]);
      expect(w.hiddenOlder(), 10);
      expect(w.hiddenNewer(30), 15);
    });

    test('empty list stays empty', () {
      final w = TranscriptWindow();
      expect(w.visibleSlice(<int>[]), isEmpty);
      expect(w.endExclusive(0), 0);
      expect(w.hiddenNewer(0), 0);
    });
  });

  group('TranscriptWindow.tryShift', () {
    final now = DateTime(2026, 9, 7, 12);

    TranscriptWindow _window() => TranscriptWindow(
          size: 10,
          shiftStep: 4,
          edgePx: 80,
          cooldown: const Duration(milliseconds: 300),
        );

    test('busy flag blocks shift', () {
      final w = _window()
        ..pinnedToEnd = false
        ..start = 20;
      expect(
        w.tryShift(
          direction: -1,
          total: 50,
          pixels: 0,
          extentAfter: 500,
          maxScrollExtent: 1000,
          now: now,
          busy: true,
        ),
        isFalse,
      );
      expect(w.start, 20);
    });

    test('short content (maxScrollExtent) never shifts', () {
      final w = _window()
        ..pinnedToEnd = false
        ..start = 20;
      expect(
        w.tryShift(
          direction: -1,
          total: 50,
          pixels: 0,
          extentAfter: 10,
          maxScrollExtent: 100, // < edgePx * 2
          now: now,
        ),
        isFalse,
      );
    });

    test('total <= size never shifts', () {
      final w = _window()..start = 0;
      expect(
        w.tryShift(
          direction: -1,
          total: 8,
          pixels: 0,
          extentAfter: 0,
          maxScrollExtent: 1000,
          now: now,
        ),
        isFalse,
      );
    });

    test('shift earlier near top edge', () {
      final w = _window()
        ..pinnedToEnd = false
        ..start = 20;
      expect(
        w.tryShift(
          direction: -1,
          total: 50,
          pixels: 40,
          extentAfter: 900,
          maxScrollExtent: 1000,
          now: now,
        ),
        isTrue,
      );
      expect(w.start, 16);
      expect(w.pinnedToEnd, isFalse);
      expect(w.lastShiftAt, now);
    });

    test('shift earlier clamps at 0', () {
      final w = _window()
        ..pinnedToEnd = false
        ..start = 3;
      expect(
        w.tryShift(
          direction: -1,
          total: 50,
          pixels: 0,
          extentAfter: 900,
          maxScrollExtent: 1000,
          now: now,
        ),
        isTrue,
      );
      expect(w.start, 0);
    });

    test('no earlier shift when already at 0', () {
      final w = _window()
        ..pinnedToEnd = false
        ..start = 0;
      expect(
        w.tryShift(
          direction: -1,
          total: 50,
          pixels: 0,
          extentAfter: 900,
          maxScrollExtent: 1000,
          now: now,
        ),
        isFalse,
      );
    });

    test('no earlier shift when not near top edge', () {
      final w = _window()
        ..pinnedToEnd = false
        ..start = 20;
      expect(
        w.tryShift(
          direction: -1,
          total: 50,
          pixels: 200,
          extentAfter: 700,
          maxScrollExtent: 1000,
          now: now,
        ),
        isFalse,
      );
    });

    test('shift later near bottom edge', () {
      final w = _window()
        ..pinnedToEnd = false
        ..start = 10;
      expect(
        w.tryShift(
          direction: 1,
          total: 50,
          pixels: 900,
          extentAfter: 40,
          maxScrollExtent: 1000,
          now: now,
        ),
        isTrue,
      );
      expect(w.start, 14);
      expect(w.pinnedToEnd, isFalse);
    });

    test('shift later pins when reaching maxStart', () {
      final w = _window()
        ..pinnedToEnd = false
        ..start = 38;
      expect(
        w.tryShift(
          direction: 1,
          total: 50,
          pixels: 900,
          extentAfter: 10,
          maxScrollExtent: 1000,
          now: now,
        ),
        isTrue,
      );
      expect(w.start, 40); // maxStart
      expect(w.pinnedToEnd, isTrue);
    });

    test('no later shift when already at end', () {
      final w = _window()
        ..pinnedToEnd = true
        ..start = 40;
      expect(
        w.tryShift(
          direction: 1,
          total: 50,
          pixels: 900,
          extentAfter: 0,
          maxScrollExtent: 1000,
          now: now,
        ),
        isFalse,
      );
    });

    test('wrong direction near opposite edge does nothing', () {
      final w = _window()
        ..pinnedToEnd = false
        ..start = 20;
      // Near top but scrolling down
      expect(
        w.tryShift(
          direction: 1,
          total: 50,
          pixels: 0,
          extentAfter: 900,
          maxScrollExtent: 1000,
          now: now,
        ),
        isFalse,
      );
    });

    test('cooldown blocks a second shift', () {
      final w = _window()
        ..pinnedToEnd = false
        ..start = 20;
      expect(
        w.tryShift(
          direction: -1,
          total: 50,
          pixels: 0,
          extentAfter: 900,
          maxScrollExtent: 1000,
          now: now,
        ),
        isTrue,
      );
      expect(
        w.tryShift(
          direction: -1,
          total: 50,
          pixels: 0,
          extentAfter: 900,
          maxScrollExtent: 1000,
          now: now.add(const Duration(milliseconds: 100)),
        ),
        isFalse,
      );
      expect(
        w.tryShift(
          direction: -1,
          total: 50,
          pixels: 0,
          extentAfter: 900,
          maxScrollExtent: 1000,
          now: now.add(const Duration(milliseconds: 301)),
        ),
        isTrue,
      );
    });
  });

  group('TranscriptWindow.paddedScrollTarget', () {
    final w = TranscriptWindow(edgePx: 80);

    test('earlier shift parks below the top edge', () {
      final t = w.paddedScrollTarget(
        shiftDelta: -1,
        beforePixels: 0,
        beforeMax: 1000,
        afterMax: 1400,
      );
      // before + (1400-1000) = 400, then +80+24 = 504
      expect(t, 504);
    });

    test('later shift parks above the bottom edge', () {
      final t = w.paddedScrollTarget(
        shiftDelta: 1,
        beforePixels: 900,
        beforeMax: 1000,
        afterMax: 700,
      );
      // before + (700-1000) = 600, then -80-24 = 496
      expect(t, 496);
    });

    test('zero afterMax returns 0', () {
      expect(
        w.paddedScrollTarget(
          shiftDelta: -1,
          beforePixels: 10,
          beforeMax: 0,
          afterMax: 0,
        ),
        0,
      );
    });

    test('clamps into [0, afterMax]', () {
      final t = w.paddedScrollTarget(
        shiftDelta: -1,
        beforePixels: 0,
        beforeMax: 100,
        afterMax: 50,
      );
      expect(t, lessThanOrEqualTo(50));
      expect(t, greaterThanOrEqualTo(0));
    });
  });

  group('TranscriptWindow.shouldResumeFollow', () {
    final w = TranscriptWindow();
    test('only when at end and near bottom', () {
      expect(w.shouldResumeFollow(atEnd: true, nearBottom: true), isTrue);
      expect(w.shouldResumeFollow(atEnd: true, nearBottom: false), isFalse);
      expect(w.shouldResumeFollow(atEnd: false, nearBottom: true), isFalse);
      expect(w.shouldResumeFollow(atEnd: false, nearBottom: false), isFalse);
    });
  });
}
