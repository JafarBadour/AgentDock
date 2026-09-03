import 'dart:convert';

import 'tool_call_state.dart';

/// Live explore activity for the current agent turn (reads + searches).
class ExploreStats {
  const ExploreStats({
    this.files = const {},
    this.searchCount = 0,
  });

  /// Distinct files the agent has opened/read this turn.
  final Set<String> files;

  /// Number of search/grep/glob tool calls this turn.
  final int searchCount;

  int get fileCount => files.length;

  bool get isEmpty => fileCount == 0 && searchCount == 0;

  bool get isNotEmpty => !isEmpty;

  /// `Exploring 8 φ, 7 🔍`
  String get label {
    final bits = <String>[];
    if (fileCount > 0) bits.add('$fileCount φ');
    if (searchCount > 0) bits.add('$searchCount 🔍');
    if (bits.isEmpty) return 'Exploring…';
    return 'Exploring ${bits.join(', ')}';
  }

  static ExploreStats fromTools(Iterable<ToolCallState> tools) {
    final files = <String>{};
    var searches = 0;
    for (final tool in tools) {
      if (_isSearch(tool)) {
        searches++;
        // Globs sometimes name a path; still count as search primarily.
        continue;
      }
      if (_isRead(tool)) {
        files.addAll(_pathsFrom(tool));
        if (files.isEmpty) {
          // Read without a resolvable path still counts as one file touch.
          files.add('file:${tool.toolCallId}');
        }
      }
    }
    // Drop synthetic ids from the displayed set size? We use them only when
    // no path was found — fileCount includes them which is fine.
    return ExploreStats(files: files, searchCount: searches);
  }

  static bool _isSearch(ToolCallState tool) {
    final blob =
        '${tool.kind ?? ''} ${tool.title} ${tool.rawInput ?? ''}'.toLowerCase();
    if (blob.contains('websearch') ||
        blob.contains('web_search') ||
        blob.contains('web search') ||
        blob.contains('webfetch') ||
        blob.contains('web_fetch')) {
      // Web browse is not a code search — skip for explore chip.
      return false;
    }
    return blob.contains('grep') ||
        blob.contains('glob') ||
        blob.contains('ripgrep') ||
        blob.contains('rg ') ||
        blob.contains('codebase_search') ||
        blob.contains('semantic_search') ||
        blob.contains('file_search') ||
        (blob.contains('search') && !blob.contains('search_replace')) ||
        blob.contains('find_by_name') ||
        blob.contains('find files');
  }

  static bool _isRead(ToolCallState tool) {
    if (_isSearch(tool)) return false;
    final blob =
        '${tool.kind ?? ''} ${tool.title} ${tool.rawInput ?? ''}'.toLowerCase();
    if (blob.contains('edit') ||
        blob.contains('write') ||
        blob.contains('delete') ||
        blob.contains('strreplace') ||
        blob.contains('apply_patch') ||
        blob.contains('shell') ||
        blob.contains('exec') ||
        blob.contains('terminal')) {
      return false;
    }
    return blob.contains('read') ||
        blob.contains('open') ||
        blob.contains('cat ') ||
        blob.contains('view') ||
        blob.contains('list_dir') ||
        blob.contains('list directory') ||
        blob.contains('get_file') ||
        (tool.locations.isNotEmpty &&
            (blob.contains('file') || (tool.kind ?? '').isEmpty));
  }

  static Set<String> _pathsFrom(ToolCallState tool) {
    final out = <String>{};
    for (final loc in tool.locations) {
      final path = loc.split(':').first.trim();
      if (path.isNotEmpty) out.add(_shortPath(path));
    }
    for (final blob in [
      if (tool.rawInput != null) tool.rawInput!,
      if (tool.rawOutput != null) tool.rawOutput!,
    ]) {
      Object? decoded;
      try {
        decoded = jsonDecode(blob);
      } catch (_) {
        continue;
      }
      void walk(Object? node) {
        if (node is Map) {
          for (final key in const [
            'path',
            'file_path',
            'filePath',
            'file',
            'target',
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
    }
    return out;
  }

  static String _shortPath(String path) {
    final norm = path.replaceAll('\\', '/');
    final parts = norm.split('/');
    if (parts.length <= 3) return norm;
    return parts.sublist(parts.length - 3).join('/');
  }
}
