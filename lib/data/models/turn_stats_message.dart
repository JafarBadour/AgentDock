import 'dart:convert';

import 'code_change_stats.dart';

/// Per-turn code churn + token usage, stored as [MessageRole.system].
///
/// Shown under the finished assistant turn in chat (`+X -Y · Z φ · N τ`).
abstract final class TurnStatsMessage {
  static const marker = '<!--agentdock-turn-stats-->';

  static String encode({
    int added = 0,
    int removed = 0,
    int files = 0,
    int? tokensUsed,
    int? contextSize,
  }) {
    final map = <String, Object?>{
      'a': added,
      'r': removed,
      'f': files,
      't': ?tokensUsed,
      's': ?contextSize,
    };
    return '$marker${jsonEncode(map)}';
  }

  static TurnStats? tryParse(String content) {
    final t = content.trimLeft();
    if (!t.startsWith(marker)) return null;
    final raw = t.substring(marker.length).trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return TurnStats(
        added: _int(decoded['a']),
        removed: _int(decoded['r']),
        files: _int(decoded['f']),
        tokensUsed: _intOrNull(decoded['t']),
        contextSize: _intOrNull(decoded['s']),
      );
    } catch (_) {
      return null;
    }
  }

  static bool isTurnStats(String content) =>
      content.trimLeft().startsWith(marker);

  static int _int(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static int? _intOrNull(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }
}

/// Code delta and/or context tokens for one finished agent turn.
class TurnStats {
  const TurnStats({
    this.added = 0,
    this.removed = 0,
    this.files = 0,
    this.tokensUsed,
    this.contextSize,
  });

  final int added;
  final int removed;
  final int files;
  final int? tokensUsed;
  final int? contextSize;

  bool get hasCodeDelta => added > 0 || removed > 0 || files > 0;

  bool get hasTokens => tokensUsed != null;

  /// Nothing worth painting (all-zero code and no token reading).
  bool get isEmpty => !hasCodeDelta && !hasTokens;

  bool get isNotEmpty => !isEmpty;

  factory TurnStats.fromCode(CodeChangeStats code, {int? tokensUsed, int? contextSize}) =>
      TurnStats(
        added: code.added,
        removed: code.removed,
        files: code.fileCount,
        tokensUsed: tokensUsed,
        contextSize: contextSize,
      );

  /// Prefer persisted token fields; take the richer code signal.
  TurnStats mergeComputed(CodeChangeStats code) {
    final usePersistedCode = hasCodeDelta;
    return TurnStats(
      added: usePersistedCode ? added : code.added,
      removed: usePersistedCode ? removed : code.removed,
      files: usePersistedCode ? files : code.fileCount,
      tokensUsed: tokensUsed,
      contextSize: contextSize,
    );
  }
}
