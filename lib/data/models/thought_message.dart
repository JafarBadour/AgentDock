/// Persisted agent reasoning (ACP thought channel), stored as [MessageRole.system].
abstract final class ThoughtMessage {
  static const marker = '<!--agentdock-thought-->';

  static String encode(String text) => '$marker\n${text.trim()}';

  /// Strip the marker for display. Legacy thoughts (no marker) pass through.
  static String display(String content) {
    final t = content.trimLeft();
    if (t.startsWith(marker)) {
      return t.substring(marker.length).trimLeft();
    }
    return content.trim();
  }
}
