import 'dart:convert';

import 'tool_call_state.dart';

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
      for (final line in blob.split('\n')) {
        if (line.startsWith('+++') || line.startsWith('---')) continue;
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
            // Replace-style edit: count both sides as the hunk size.
            if (oldText != null && newText != null) {
              removed += _lineCount(oldText);
              added += _lineCount(newText);
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
        removed += _lineCount(oldText);
        added += _lineCount(newText);
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
    var n = 0;
    for (final _ in text.split('\n')) {
      n++;
    }
    // Trailing newline alone should not invent an extra empty line for ""
    // after split — Dart split keeps a trailing empty for "a\n".
    if (text.endsWith('\n') && n > 0) n--;
    return n == 0 ? 1 : n;
  }

  static String _shortPath(String path) {
    final norm = path.replaceAll('\\', '/');
    final parts = norm.split('/');
    if (parts.length <= 3) return norm;
    return parts.sublist(parts.length - 3).join('/');
  }
}
