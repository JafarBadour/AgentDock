/// Sliding viewport over a long transcript: only [size] rows stay mounted.
///
/// Scrolling toward older content decreases [start] and drops newer rows;
/// scrolling toward newer content increases [start] and drops older ones.
/// Pure math — no Flutter dependencies — so every branch is unit-testable.
class TranscriptWindow {
  TranscriptWindow({
    this.size = 100,
    this.shiftStep = 24,
    this.edgePx = 80.0,
    this.cooldown = const Duration(milliseconds: 280),
  });

  final int size;
  final int shiftStep;
  final double edgePx;
  final Duration cooldown;

  int start = 0;
  bool pinnedToEnd = true;
  DateTime? lastShiftAt;

  /// Keep [start] valid for [total] and optionally pin to the latest window.
  void sync(int total, {required bool followOutput}) {
    if (total <= size) {
      start = 0;
      pinnedToEnd = true;
      return;
    }
    if (followOutput || pinnedToEnd) {
      start = total - size;
      pinnedToEnd = true;
      return;
    }
    final maxStart = total - size;
    if (start > maxStart) start = maxStart;
    if (start < 0) start = 0;
  }

  void pinToLatest(int total) {
    pinnedToEnd = true;
    start = total > size ? total - size : 0;
  }

  int maxStartFor(int total) => total <= size ? 0 : total - size;

  int endExclusive(int total) {
    if (total <= 0) return 0;
    final end = start + size;
    return end > total ? total : end;
  }

  int hiddenOlder() => start < 0 ? 0 : start;

  int hiddenNewer(int total) {
    final end = endExclusive(total);
    final n = total - end;
    return n < 0 ? 0 : n;
  }

  List<T> visibleSlice<T>(List<T> all) {
    if (all.isEmpty) return all;
    final end = endExclusive(all.length);
    final from = start.clamp(0, end);
    return all.sublist(from, end);
  }

  /// Attempt a window shift.
  ///
  /// [direction]: `-1` toward older (up), `+1` toward newer (down).
  /// Returns `true` when [start] changed.
  bool tryShift({
    required int direction,
    required int total,
    required double pixels,
    required double extentAfter,
    required double maxScrollExtent,
    required DateTime now,
    bool busy = false,
  }) {
    if (busy || total <= size) return false;
    final last = lastShiftAt;
    if (last != null && now.difference(last) < cooldown) return false;
    // Short content: edge checks would both fire and thrash.
    if (maxScrollExtent < edgePx * 2) return false;

    final maxStart = total - size;
    if (direction < 0 && pixels <= edgePx && start > 0) {
      final next = start - shiftStep;
      start = next < 0 ? 0 : (next > maxStart ? maxStart : next);
      lastShiftAt = now;
      pinnedToEnd = start >= maxStart;
      return true;
    }
    if (direction > 0 && extentAfter <= edgePx && start < maxStart) {
      final next = start + shiftStep;
      start = next > maxStart ? maxStart : next;
      lastShiftAt = now;
      pinnedToEnd = start >= maxStart;
      return true;
    }
    return false;
  }

  /// After a shift, park slightly off the edge so we do not re-trigger.
  double paddedScrollTarget({
    required int shiftDelta,
    required double beforePixels,
    required double beforeMax,
    required double afterMax,
  }) {
    if (afterMax <= 0) return 0;
    final deltaExtent = afterMax - beforeMax;
    final target = (beforePixels + deltaExtent).clamp(0.0, afterMax);
    if (shiftDelta < 0) {
      return (target + edgePx + 24).clamp(0.0, afterMax);
    }
    return (target - edgePx - 24).clamp(0.0, afterMax);
  }

  /// Resume live follow only when the window reached the end *and* the
  /// viewport is already near the bottom (do not yank mid-scroll).
  bool shouldResumeFollow({
    required bool atEnd,
    required bool nearBottom,
  }) =>
      atEnd && nearBottom;
}
