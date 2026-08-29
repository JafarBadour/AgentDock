import 'package:flutter/foundation.dart';

/// Logging helpers that never emit secrets (PEM, keys, tokens).
abstract final class SafeLog {
  static final _secretPatterns = <RegExp>[
    RegExp(
      '-----BEGIN[^-]*PRIVATE KEY-----[\\s\\S]*?-----END[^-]*PRIVATE KEY-----',
    ),
    RegExp(r'cursor_[A-Za-z0-9_\-]{20,}'),
    RegExp(r'sk-[A-Za-z0-9_\-]{20,}'),
    RegExp(r'(api[_-]?key|password|passphrase|secret)\s*[:=]\s*\S+', caseSensitive: false),
  ];

  static String redact(String input) {
    var out = input;
    for (final pattern in _secretPatterns) {
      out = out.replaceAll(pattern, '[REDACTED]');
    }
    return out;
  }

  static void d(String message, [Object? error, StackTrace? stack]) {
    if (!kDebugMode) return;
    final text = redact(message);
    if (error != null) {
      debugPrint('$text | error=${redact(error.toString())}');
    } else {
      debugPrint(text);
    }
    if (stack != null) {
      debugPrint(stack.toString());
    }
  }
}
