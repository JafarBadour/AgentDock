/// Base64 image bodies (PNG / JPEG / GIF / WebP) embedded in tool payloads.
///
/// An agent `Read` of an image returns the whole picture as base64, twice
/// (rawOutput + content). Capped at 180 KB each it no longer decodes, is never
/// rendered from the tool row, and a few dozen of them made chats tens of MB —
/// all parsed, synced and re-encoded on the UI isolate.
const _magics = ['iVBORw0KGgo', '/9j/', 'R0lGOD', 'UklGR'];

/// Base64 characters after the magic prefix before a run counts as an image.
const _minRun = 2000;

/// [value] with long inline base64 images replaced by a short marker.
///
/// Only touches characters inside the base64 run, so JSON (or JSON encoded
/// inside a JSON string) stays well-formed.
String stripInlineImages(String value) {
  if (value.length < _minRun) return value;
  if (!_magics.any(value.contains)) return value;
  // A hand-rolled scan, not a RegExp: `[A-Za-z0-9+/]{2000,}` over a 180 KB
  // run threw StackOverflowError in AOT builds (the regexp interpreter keeps
  // a backtrack entry per character), crashing the v21 cleanup at startup.
  StringBuffer? out;
  var copied = 0;
  var from = 0;
  while (from < value.length) {
    final start = _nextMagic(value, from);
    if (start < 0) break;
    var end = start;
    while (end < value.length && _isBase64(value.codeUnitAt(end))) {
      end++;
    }
    final magicLength = _magics
        .firstWhere((m) => value.startsWith(m, start))
        .length;
    if (end - start - magicLength < _minRun) {
      from = start + 1;
      continue;
    }
    var pad = 0;
    while (pad < 2 && end < value.length && value.codeUnitAt(end) == 0x3D) {
      end++;
      pad++;
    }
    final kb = (end - start) * 3 ~/ 4 ~/ 1024;
    (out ??= StringBuffer())
      ..write(value.substring(copied, start))
      ..write('[image omitted, $kb KB]');
    copied = end;
    from = end;
  }
  if (out == null) return value;
  out.write(value.substring(copied));
  return out.toString();
}

/// Earliest index at or after [from] where any magic prefix starts, or -1.
int _nextMagic(String value, int from) {
  var best = -1;
  for (final m in _magics) {
    final i = value.indexOf(m, from);
    if (i >= 0 && (best < 0 || i < best)) best = i;
  }
  return best;
}

bool _isBase64(int c) =>
    (c >= 0x41 && c <= 0x5A) || // A-Z
    (c >= 0x61 && c <= 0x7A) || // a-z
    (c >= 0x30 && c <= 0x39) || // 0-9
    c == 0x2B || // +
    c == 0x2F; // /
