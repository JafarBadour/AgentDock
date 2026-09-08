/// Tail window over a long transcript: mount the latest [pageSize] rows, and
/// only grow toward older history when the user asks (top edge / tap).
///
/// Newer rows are never dropped while reading history — that mid-scroll
/// sliding is what made the list jump. Jump-to-latest resets back to one page.
class TranscriptWindow {
  TranscriptWindow({
    this.pageSize = 30,
    this.edgePx = 72.0,
    this.cooldown = const Duration(milliseconds: 450),
  }) : visibleCount = pageSize;

  final int pageSize;
  final double edgePx;
  final Duration cooldown;

  /// How many trailing rows are currently mounted (grows via [loadOlder]).
  int visibleCount;

  /// True when the viewport should stay glued to the live end.
  bool pinnedToEnd = true;

  DateTime? lastLoadAt;

  /// Absolute index of the first mounted row (derived from [visibleCount]).
  int start = 0;

  int startFor(int total) {
    if (total <= 0) return 0;
    if (visibleCount >= total) return 0;
    return total - visibleCount;
  }

  /// Keep [start] valid for [total]. Following does not shrink an expanded
  /// history window — only [pinToLatest] resets to one page.
  void sync(int total, {required bool followOutput}) {
    if (followOutput) pinnedToEnd = true;
    if (visibleCount < pageSize) visibleCount = pageSize;
    start = startFor(total);
  }

  void pinToLatest(int total) {
    pinnedToEnd = true;
    visibleCount = pageSize;
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
}
