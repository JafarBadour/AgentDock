/// Helpers for reading text out of a PTY transcript.
///
/// Login CLIs draw with a full-screen UI library, so the byte stream is a
/// series of redrawn frames rather than plain lines. Reading values back out
/// of it needs a little care about where one frame ends and the next begins.
library;

/// A CSI sequence that only changes how text looks — colour, bold, reset.
/// It leaves the cursor where it was, so deleting it joins text correctly.
final _sgrRe = RegExp(r'\x1B\[[0-9;?]*m');

/// An OSC sequence, terminated by BEL or ST. OSC 8 carries a hyperlink
/// target, so its payload is the same URL the visible label already shows.
final _oscRe = RegExp(r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)');

/// Any other CSI sequence: cursor moves, line erases, scroll regions. The
/// text after one of these lands somewhere else on screen, so it is not a
/// continuation of the text before it.
final _csiRe = RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]');

/// Stray control bytes — a lone BEL from a truncated OSC, backspaces from a
/// progress line. Never part of a value worth reading.
final _controlRe = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

final _schemeRe = RegExp(r'https?://');

/// Flatten PTY output to scannable text.
///
/// Styling escapes are dropped, but anything that repositions the cursor —
/// a move, an erase, a hyperlink wrapper — becomes a newline. A redrawn frame
/// erases the old copy of a line with escapes rather than newlines, and an
/// OSC 8 hyperlink puts its target right before the label; deleting either
/// outright glues two copies of a URL into one run, which is how a login link
/// came back doubled, as `linklink`.
String stripAnsi(String text) => text
    .replaceAll(_sgrRe, '')
    .replaceAll(_oscRe, '\n')
    .replaceAll(_csiRe, '\n')
    .replaceAll(_controlRe, '\n');

/// Collapse a URL that still came out of the buffer repeated.
///
/// Only collapses when the repeats are prefixes of one another — a redraw
/// writing the same line again, possibly cut short the first time. Two
/// genuinely different URLs are left alone, since a query string can carry
/// one unencoded.
String dedupeGluedUrl(String token) {
  final starts = [for (final m in _schemeRe.allMatches(token)) m.start];
  if (starts.length < 2 || starts.first != 0) return token;

  var longest = '';
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] : token.length;
    final part = token.substring(starts[i], end);
    if (longest.isEmpty) {
      longest = part;
      continue;
    }
    if (!part.startsWith(longest) && !longest.startsWith(part)) return token;
    if (part.length > longest.length) longest = part;
  }
  return longest;
}
