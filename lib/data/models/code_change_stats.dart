import 'dart:convert';

import 'tool_call_state.dart';

/// Avoid re-walking 100KB diffs on every transcript rebuild.
final Expando<CodeChangeStats> _toolCodeStatsCache =
    Expando<CodeChangeStats>('toolCodeStats');

/// Local calendar day key for daily stat rollovers (`YYYY-MM-DD`).
String codeDeltaLocalDayKey([DateTime? when]) {
  final d = when ?? DateTime.now();
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '$y-$m-$day';
}

/// Aggregate code churn attributed to agent tool calls.
class CodeChangeStats {
  const CodeChangeStats({
    this.added = 0,
    this.removed = 0,
    this.files = const {},
  });

  final int added;
  final int removed;
  final Set<String> files;

  bool get isEmpty => added == 0 && removed == 0 && files.isEmpty;

  bool get isNotEmpty => !isEmpty;

  int get fileCount => files.length;

  /// Prefer live tool totals, but never drop already-persisted session totals.
  /// Persisted values apply only when [persistedDay] matches [todayDay].
  static ({int added, int removed, int files}) mergeDisplay({
    CodeChangeStats? live,
    int persistedAdded = 0,
    int persistedRemoved = 0,
    int persistedFiles = 0,
    String? persistedDay,
    String? todayDay,
  }) {
    final today = todayDay ?? codeDeltaLocalDayKey();
    if (persistedDay != null && persistedDay != today) {
      persistedAdded = 0;
      persistedRemoved = 0;
      persistedFiles = 0;
    }
    final a = live?.added ?? 0;
    final r = live?.removed ?? 0;
    final f = live?.fileCount ?? 0;
    return (
      added: a > persistedAdded ? a : persistedAdded,
      removed: r > persistedRemoved ? r : persistedRemoved,
      files: f > persistedFiles ? f : persistedFiles,
    );
  }

  CodeChangeStats operator +(CodeChangeStats other) => CodeChangeStats(
        added: added + other.added,
        removed: removed + other.removed,
        files: {...files, ...other.files},
      );

  /// `Δ +4356 -265 | 45 φ`
  String get label {
    final parts = <String>['Δ'];
    parts.add('+$added');
    parts.add('-$removed');
    if (fileCount > 0) {
      parts.add('|');
      parts.add('$fileCount φ');
    }
    return parts.join(' ');
  }

  static CodeChangeStats fromTools(Iterable<ToolCallState> tools) {
    var total = const CodeChangeStats();
    for (final tool in tools) {
      total += fromTool(tool);
    }
    return total;
  }

  static CodeChangeStats fromTool(ToolCallState tool) {
    final cached = _toolCodeStatsCache[tool];
    if (cached != null) return cached;
    final computed = _fromToolUncached(tool);
    _toolCodeStatsCache[tool] = computed;
    return computed;
  }

  static CodeChangeStats _fromToolUncached(ToolCallState tool) {
    if (!_looksLikeCodeChange(tool)) {
      if (_isEditKind(tool) && tool.locations.isNotEmpty) {
        return CodeChangeStats(files: _pathsFrom(tool));
      }
      return const CodeChangeStats();
    }

    final files = _pathsFrom(tool);
    final fromContent = _fromAcpContent(tool.content);
    final fromPair = _fromOldNew(_blobs(tool));
    final fromDiff = _fromUnifiedDiff(_blobs(tool));

    // Prefer the richest single signal so the same edit is not triple-counted.
    CodeChangeStats best = fromContent;
    for (final c in [fromPair, fromDiff]) {
      if (c.added + c.removed > best.added + best.removed) best = c;
    }
    files.addAll(fromContent.files);
    files.addAll(fromPair.files);
    files.addAll(fromDiff.files);

    if (best.added == 0 && best.removed == 0 && files.isEmpty) {
      if (tool.locations.isNotEmpty && _isEditKind(tool)) {
        return CodeChangeStats(files: _pathsFrom(tool));
      }
      return const CodeChangeStats();
    }

    return CodeChangeStats(
      added: best.added,
      removed: best.removed,
      files: files,
    );
  }

  static bool _isEditKind(ToolCallState tool) {
    final blob =
        '${tool.kind ?? ''} ${tool.title} ${tool.rawInput ?? ''}'.toLowerCase();
    return blob.contains('edit') ||
        blob.contains('write') ||
        blob.contains('create') ||
        blob.contains('delete') ||
        blob.contains('apply_patch') ||
        blob.contains('applypatch') ||
        blob.contains('strreplace') ||
        blob.contains('search_replace');
  }

  static bool _looksLikeCodeChange(ToolCallState tool) {
    if (_isEditKind(tool)) return true;
    final blobs = _blobs(tool).join('\n');
    if (blobs.contains('old_string') ||
        blobs.contains('oldString') ||
        blobs.contains('new_string') ||
        blobs.contains('newString') ||
        blobs.contains('oldText') ||
        blobs.contains('newText') ||
        blobs.contains('"contents"') ||
        blobs.contains('@@ ') ||
        RegExp(r'^[\+\-]{3} ', multiLine: true).hasMatch(blobs)) {
      return true;
    }
    if (tool.content != null && tool.content!.contains('"diff"')) return true;
    return false;
  }

  static List<String> _blobs(ToolCallState tool) => [
        if (tool.rawInput != null) tool.rawInput!,
        if (tool.rawOutput != null) tool.rawOutput!,
        if (tool.content != null) tool.content!,
      ];

  static Set<String> _pathsFrom(ToolCallState tool) {
    final out = <String>{};
    for (final loc in tool.locations) {
      final path = loc.split(':').first.trim();
      if (path.isNotEmpty) out.add(_shortPath(path));
    }
    for (final blob in _blobs(tool)) {
      out.addAll(_pathsFromJson(blob));
      out.addAll(_pathsFromDiffHeaders(blob));
    }
    return out;
  }

  static Set<String> _pathsFromJson(String blob) {
    final out = <String>{};
    Object? decoded;
    try {
      decoded = jsonDecode(blob);
    } catch (_) {
      return out;
    }
    void walk(Object? node) {
      if (node is Map) {
        for (final key in const [
          'path',
          'file_path',
          'filePath',
          'file',
          'target',
          'uri',
        ]) {
          final v = node[key];
          if (v is String && v.trim().isNotEmpty && !v.contains('\n')) {
            out.add(_shortPath(v.trim()));
          }
        }
        for (final v in node.values) {
          walk(v);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
        }
      }
    }

    walk(decoded);
    return out;
  }

  static Set<String> _pathsFromDiffHeaders(String blob) {
    final out = <String>{};
    for (final line in blob.split('\n')) {
      if (line.startsWith('+++ ') || line.startsWith('--- ')) {
        var rest = line.substring(4).trim();
        if (rest == '/dev/null') continue;
        if (rest.startsWith('a/') || rest.startsWith('b/')) {
          rest = rest.substring(2);
        }
        final path = rest.split('\t').first.trim();
        if (path.isNotEmpty) out.add(_shortPath(path));
      }
    }
    return out;
  }

  static CodeChangeStats _fromUnifiedDiff(List<String> blobs) {
    var added = 0;
    var removed = 0;
    final files = <String>{};
    for (final blob in blobs) {
      files.addAll(_pathsFromDiffHeaders(blob));
      // Only count +/- inside @@ hunks. Scanning whole JSON/tool blobs for
      // leading +/- inflated churn (and beat the real edit via "richest signal").
      var inHunk = false;
      for (final line in blob.split('\n')) {
        if (line.startsWith('@@')) {
          inHunk = true;
          continue;
        }
        if (line.startsWith('diff ') ||
            line.startsWith('---') ||
            line.startsWith('+++')) {
          inHunk = false;
          continue;
        }
        if (!inHunk) continue;
        if (line.startsWith('+')) {
          added++;
        } else if (line.startsWith('-')) {
          removed++;
        }
      }
    }
    return CodeChangeStats(added: added, removed: removed, files: files);
  }

  static CodeChangeStats _fromOldNew(List<String> blobs) {
    var added = 0;
    var removed = 0;
    final files = <String>{};
    for (final blob in blobs) {
      Object? decoded;
      try {
        decoded = jsonDecode(blob);
      } catch (_) {
        continue;
      }
      void walk(Object? node) {
        if (node is Map) {
          final oldText = _stringField(node, const [
            'old_string',
            'oldString',
            'oldText',
            'old_text',
            'before',
          ]);
          final newText = _stringField(node, const [
            'new_string',
            'newString',
            'newText',
            'new_text',
            'after',
            'contents',
            'content',
          ]);
          if (oldText != null || newText != null) {
            // ACP often ships full-file oldText/newText for a tiny edit.
            // Diff the lines — do not treat |old| / |new| as removed / added.
            if (oldText != null && newText != null) {
              final d = _diffLineCounts(oldText, newText);
              removed += d.removed;
              added += d.added;
            } else if (newText != null) {
              added += _lineCount(newText);
            } else if (oldText != null) {
              removed += _lineCount(oldText);
            }
          }
          for (final v in node.values) {
            walk(v);
          }
        } else if (node is List) {
          for (final v in node) {
            walk(v);
          }
        }
      }

      walk(decoded);
      files.addAll(_pathsFromJson(blob));
    }
    return CodeChangeStats(added: added, removed: removed, files: files);
  }

  static CodeChangeStats _fromAcpContent(String? content) {
    if (content == null || content.isEmpty) return const CodeChangeStats();
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } catch (_) {
      return _fromUnifiedDiff([content]);
    }
    var added = 0;
    var removed = 0;
    final files = <String>{};

    void handleDiff(Map map) {
      final path = map['path']?.toString();
      if (path != null && path.isNotEmpty) files.add(_shortPath(path));
      final oldText = map['oldText']?.toString() ?? map['old_text']?.toString();
      final newText = map['newText']?.toString() ?? map['new_text']?.toString();
      if (oldText != null && newText != null) {
        final d = _diffLineCounts(oldText, newText);
        removed += d.removed;
        added += d.added;
        return;
      }
      final diffText = map['diff']?.toString() ?? map['text']?.toString();
      if (diffText != null) {
        final d = _fromUnifiedDiff([diffText]);
        added += d.added;
        removed += d.removed;
        files.addAll(d.files);
      }
    }

    void walk(Object? node) {
      if (node is Map) {
        final type = (node['type'] ?? '').toString().toLowerCase();
        if (type == 'diff') {
          handleDiff(node);
        }
        for (final v in node.values) {
          walk(v);
        }
      } else if (node is List) {
        for (final v in node) {
          walk(v);
        }
      }
    }

    walk(decoded);
    return CodeChangeStats(added: added, removed: removed, files: files);
  }

  static String? _stringField(Map map, List<String> keys) {
    for (final key in keys) {
      final v = map[key];
      if (v is String) return v;
    }
    return null;
  }

  static int _lineCount(String text) {
    if (text.isEmpty) return 0;
    return _lines(text).length;
  }

  /// Split into logical lines; drop the empty segment from a trailing newline.
  static List<String> _lines(String text) {
    if (text.isEmpty) return const [];
    final parts = text.split('\n');
    if (text.endsWith('\n') && parts.isNotEmpty) {
      return parts.sublist(0, parts.length - 1);
    }
    return parts;
  }

  /// Line churn between [oldText] and [newText].
  ///
  /// Trims a shared prefix/suffix (typical of ACP full-file before/after), then
  /// counts the remaining hunks. For large dissimilar middles, falls back to a
  /// bounded LCS so moved blocks are not double-counted as delete+add of the
  /// whole file.
  static ({int added, int removed}) _diffLineCounts(
    String oldText,
    String newText,
  ) {
    if (oldText == newText) return (added: 0, removed: 0);
    if (oldText.isEmpty) return (added: _lineCount(newText), removed: 0);
    if (newText.isEmpty) return (added: 0, removed: _lineCount(oldText));

    final a = _lines(oldText);
    final b = _lines(newText);
    if (a.isEmpty && b.isEmpty) return (added: 0, removed: 0);
    if (a.isEmpty) return (added: b.length, removed: 0);
    if (b.isEmpty) return (added: 0, removed: a.length);

    var start = 0;
    final minLen = a.length < b.length ? a.length : b.length;
    while (start < minLen && a[start] == b[start]) {
      start++;
    }
    var endA = a.length;
    var endB = b.length;
    while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
      endA--;
      endB--;
    }

    final oldMid = endA - start;
    final newMid = endB - start;
    if (oldMid == 0) return (added: newMid, removed: 0);
    if (newMid == 0) return (added: 0, removed: oldMid);

    // Small hunk: exact LCS. Large rewrite: treat as replace of the mid slice
    // (already stripped of unchanged head/tail — the ACP full-file case).
    const lcsCap = 400;
    if (oldMid > lcsCap || newMid > lcsCap) {
      return (added: newMid, removed: oldMid);
    }

    final oldSlice = a.sublist(start, endA);
    final newSlice = b.sublist(start, endB);
    final common = _lcsLength(oldSlice, newSlice);
    return (added: newMid - common, removed: oldMid - common);
  }

  static int _lcsLength(List<String> a, List<String> b) {
    final n = a.length;
    final m = b.length;
    if (n == 0 || m == 0) return 0;
    // Two-row DP to keep memory flat.
    var prev = List<int>.filled(m + 1, 0);
    var cur = List<int>.filled(m + 1, 0);
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        if (a[i - 1] == b[j - 1]) {
          cur[j] = prev[j - 1] + 1;
        } else {
          final up = prev[j];
          final left = cur[j - 1];
          cur[j] = up > left ? up : left;
        }
      }
      final tmp = prev;
      prev = cur;
      cur = tmp;
      cur.fillRange(0, m + 1, 0);
    }
    return prev[m];
  }

  static String _shortPath(String path) {
    final norm = path.replaceAll('\\', '/');
    final parts = norm.split('/');
    if (parts.length <= 3) return norm;
    return parts.sublist(parts.length - 3).join('/');
  }
}
