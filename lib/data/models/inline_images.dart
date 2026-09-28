/// Base64 image bodies (PNG / JPEG / GIF / WebP) embedded in tool payloads.
///
/// An agent `Read` of an image returns the whole picture as base64, twice
/// (rawOutput + content). Capped at 180 KB each it no longer decodes, is never
/// rendered from the tool row, and a few dozen of them made chats tens of MB —
/// all parsed, synced and re-encoded on the UI isolate.
final _inlineImageRe = RegExp(
  r'(?:iVBORw0KGgo|/9j/|R0lGOD|UklGR)[A-Za-z0-9+/]{2000,}={0,2}',
);

const _magics = ['iVBORw0KGgo', '/9j/', 'R0lGOD', 'UklGR'];

/// [value] with long inline base64 images replaced by a short marker.
///
/// Only touches characters inside the base64 run, so JSON (or JSON encoded
/// inside a JSON string) stays well-formed.
String stripInlineImages(String value) {
  if (value.length < 2048) return value;
  if (!_magics.any(value.contains)) return value;
  return value.replaceAllMapped(_inlineImageRe, (m) {
    final kb = (m.end - m.start) * 3 ~/ 4 ~/ 1024;
    return '[image omitted, $kb KB]';
  });
}
