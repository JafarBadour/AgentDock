/// Sliding window over a long transcript.
///
/// Starts with the latest [pageSize] rows. Scrolling into the top edge loads
/// another [pageSize] of older history. Scrolling back toward the live end
/// trims older rows once the mounted window exceeds [softMax], so memory and
/// paint cost stay bounded.
class TranscriptWindow {
  TranscriptWindow({
    this.pageSize = 300,
    this.softMax = 370,
    this.edgePx = 72.0,
    this.cooldown = const Duration(milliseconds: 450),
  }) : visibleCount = pageSize;

  /// How many rows to mount initially / load per page.
  final int pageSize;

  /// Once mounted rows exceed this and the user scrolls toward the live end,
  /// drop one [pageSize] of older rows ("ditch the top").
  final int softMax;

  final double edgePx;
  final Duration cooldown;

  /// How many trailing rows are currently mounted.
  int visibleCount;

  /// True when the viewport should stay glued to the live end.
  bool pinnedToEnd = true;

  DateTime? lastLoadAt;
  DateTime? lastTrimAt;

  /// Absolute index of the first mounted row (derived from [visibleCount]).
  int start = 0;

  int startFor(int total) {
    if (total <= 0) return 0;
    if (visibleCount >= total) return 0;
    return total - visibleCount;
  }

  /// Keep [start] valid for [total]. Following does not auto-shrink an
  /// expanded history window — that happens via [trimOlderTowardEnd].
  void sync(int total, {required bool followOutput}) {
    if (followOutput) pinnedToEnd = true;
    if (visibleCount < pageSize) visibleCount = pageSize;
    if (visibleCount > total && total > 0) visibleCount = total;
    start = startFor(total);
  }

  void pinToLatest(int total) {
    pinnedToEnd = true;
    visibleCount = pageSize;
    if (visibleCount > total && total > 0) visibleCount = total;
    start = startFor(total);
  }

  int maxStartFor(int total) => startFor(total);

  int endExclusive(int total) {
    if (total <= 0) return 0;
    return total;
  }

  int hiddenOlder() => start < 0 ? 0 : start;

  /// Tail window always includes the newest rows.
  int hiddenNewer(int total) => 0;

  List<T> visibleSlice<T>(List<T> all) {
    if (all.isEmpty) return all;
    final from = startFor(all.length);
    return all.sublist(from);
  }

  /// Expand toward older history by up to one [pageSize].
  ///
  /// Returns how many rows were added (0 if none / cooldown).
  int loadOlder(int total, {DateTime? now, bool force = false}) {
    if (total <= visibleCount) return 0;
    final n = now ?? DateTime.now();
    final last = lastLoadAt;
    if (!force && last != null && n.difference(last) < cooldown) return 0;

    final room = total - visibleCount;
    final add = room < pageSize ? room : pageSize;
    visibleCount += add;
    lastLoadAt = n;
    pinnedToEnd = false;
    start = startFor(total);
    return add;
  }

  /// Drop one [pageSize] of older rows when the window grew past [softMax]
  /// and the user is heading back to the live end.
  ///
  /// Returns how many rows were removed (0 if none).
  int trimOlderTowardEnd(int total, {DateTime? now, bool force = false}) {
    if (visibleCount <= softMax) return 0;
    if (visibleCount <= pageSize) return 0;
    final n = now ?? DateTime.now();
    final last = lastTrimAt;
    if (!force && last != null && n.difference(last) < cooldown) return 0;

    final room = visibleCount - pageSize;
    final drop = room < pageSize ? room : pageSize;
    if (drop <= 0) return 0;
    visibleCount -= drop;
    lastTrimAt = n;
    start = startFor(total);
    return drop;
  }

  /// Load older history when the user scrolls into the top edge.
  bool tryLoadOlderAtTop({
    required int total,
    required double pixels,
    required double maxScrollExtent,
    required DateTime now,
    bool busy = false,
  }) {
    if (busy || total <= visibleCount) return false;
    if (pixels > edgePx) return false;
    return loadOlder(total, now: now) > 0;
  }

  /// Trim older pages when the user scrolls toward the bottom / live end.
  bool tryTrimOlderNearBottom({
    required int total,
    required double pixels,
    required double maxScrollExtent,
    required DateTime now,
    bool busy = false,
  }) {
    if (busy || visibleCount <= softMax) return false;
    // Near the live end (or no scroll room) — safe to ditch older pages.
    final fromEnd = maxScrollExtent - pixels;
    if (maxScrollExtent > 0 && fromEnd > edgePx * 3) return false;
    return trimOlderTowardEnd(total, now: now) > 0;
  }

  /// After prepending older rows, keep the same message under the thumb.
  double preserveScrollAfterPrepend({
    required double beforePixels,
    required double beforeMax,
    required double afterMax,
  }) {
    if (afterMax <= 0) return 0;
    final deltaExtent = afterMax - beforeMax;
    return (beforePixels + deltaExtent).clamp(0.0, afterMax);
  }

  /// After dropping older rows from the top, keep the thumb on the same content.
  double preserveScrollAfterTrim({
    required double beforePixels,
    required double beforeMax,
    required double afterMax,
  }) {
    if (afterMax <= 0) return 0;
    final deltaExtent = beforeMax - afterMax;
    return (beforePixels - deltaExtent).clamp(0.0, afterMax);
  }
}
