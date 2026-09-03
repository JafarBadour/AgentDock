import 'dart:convert';

/// In-memory tool call assembled from ACP tool_call / tool_call_update.
class ToolCallState {
  const ToolCallState({
    required this.toolCallId,
    required this.title,
    this.kind,
    this.status = 'pending',
    this.locations = const [],
    this.rawInput,
    this.rawOutput,
    this.content,
  });

  final String toolCallId;
  final String title;
  final String? kind;
  final String status;
  final List<String> locations;
  final String? rawInput;
  final String? rawOutput;

  /// ACP `content` blocks (often includes `type: diff` with old/new text).
  final String? content;

  bool get isActive =>
      status == 'pending' || status == 'in_progress' || status == 'running';

  bool get isFailed => status == 'failed' || status == 'error';

  bool get isCompleted =>
      status == 'completed' || status == 'success' || status == 'done';

  String get statusLabel {
    final s = status.toLowerCase();
    if (s == 'in_progress' || s == 'running') return 'Running';
    if (s == 'pending') return 'Pending';
    if (s == 'completed' || s == 'success' || s == 'done') return 'Done';
    if (s == 'failed' || s == 'error') return 'Failed';
    if (s == 'cancelled' || s == 'canceled') return 'Cancelled';
    return status;
  }

  /// Human label for the row.
  ///
  /// Agents do not always send a title, and the bare fallback rendered as a
  /// row reading just "Tool", which tells the user nothing.
  String get displayTitle {
    final given = title.trim();
    // Agents sometimes dump a JSON fragment as the title; treat that as missing.
    if (given.isNotEmpty &&
        given.toLowerCase() != 'tool' &&
        !given.startsWith('{') &&
        !given.startsWith('[')) {
      return given;
    }
    final k = (kind ?? '').toLowerCase();
    final blob = '$k ${title.toLowerCase()} ${rawInput ?? ''}'.toLowerCase();
    if (blob.contains('websearch') ||
        blob.contains('web_search') ||
        blob.contains('web search') ||
        (k.contains('web') && k.contains('search')) ||
        k.contains('browser')) {
      return 'Web search';
    }
    if (blob.contains('webfetch') ||
        blob.contains('web_fetch') ||
        k.contains('fetch') ||
        k.contains('http') ||
        k.contains('url')) {
      return 'Fetched a URL';
    }
    if (k.contains('exec') || k.contains('shell') || k.contains('terminal')) {
      return 'Ran a command';
    }
    if (k.contains('read')) return 'Read a file';
    if (k.contains('edit') || k.contains('write')) return 'Edited a file';
    if (k.contains('grep') ||
        k.contains('glob') ||
        (k.contains('search') && !k.contains('web'))) {
      return 'Searched the code';
    }
    if (k.contains('delete')) return 'Deleted a file';
    return 'Tool call';
  }

  /// Keys worth surfacing, most specific first.
  static const _previewKeys = [
    'command',
    'cmd',
    'query',
    'search_term',
    'searchTerm',
    'pattern',
    'path',
    'file_path',
    'filePath',
    'url',
    'uri',
    'name',
    'description',
  ];

  static String? _previewFromJson(String input) {
    if (!input.startsWith('{') && !input.startsWith('[')) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(input);
    } catch (_) {
      return null;
    }
    if (decoded is List) decoded = decoded.isEmpty ? null : decoded.first;
    if (decoded is! Map) return null;
    for (final key in _previewKeys) {
      final value = decoded[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is List && value.isNotEmpty) return value.join(' ');
    }
    // Parsed JSON with nothing useful — don't fall through to a brace line.
    return '';
  }

  /// One-line detail shown next to the title.
  String? get preview {
    if (locations.isNotEmpty) return _short(locations.first);
    final input = rawInput?.trim();
    if (input == null || input.isEmpty) return null;
    // Tool input is usually pretty-printed JSON, whose first line is just "{".
    final fromJson = _previewFromJson(input);
    if (fromJson != null) {
      return fromJson.isEmpty ? null : _short(fromJson);
    }
    final line = input.split('\n').firstWhere(
          (l) {
            final t = l.trim();
            return t.isNotEmpty && t != '{' && t != '}' && t != '[' && t != ']';
          },
          orElse: () => '',
        );
    if (line.isEmpty) return null;
    return _short(line);
  }

  static String _short(String value) {
    final compact = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    return compact.length <= 100 ? compact : '${compact.substring(0, 99)}…';
  }

  ToolCallState merge({
    String? title,
    String? kind,
    String? status,
    List<String>? locations,
    String? rawInput,
    String? rawOutput,
    String? content,
  }) =>
      ToolCallState(
        toolCallId: toolCallId,
        title: (title != null && title.isNotEmpty) ? title : this.title,
        kind: kind ?? this.kind,
        status: (status != null && status.isNotEmpty) ? status : this.status,
        locations: locations ?? this.locations,
        rawInput: rawInput ?? this.rawInput,
        rawOutput: rawOutput ?? this.rawOutput,
        content: content ?? this.content,
      );

  Map<String, dynamic> toJson() => {
        'toolCallId': toolCallId,
        'title': title,
        if (kind != null) 'kind': kind,
        'status': status,
        'locations': locations,
        if (rawInput != null) 'rawInput': rawInput,
        if (rawOutput != null) 'rawOutput': rawOutput,
        if (content != null) 'content': content,
      };

  factory ToolCallState.fromJson(Map<String, dynamic> json) => ToolCallState(
        toolCallId: (json['toolCallId'] ?? json['id'] ?? '').toString(),
        title: (json['title'] ?? 'Tool').toString(),
        kind: json['kind']?.toString(),
        status: (json['status'] ?? 'pending').toString(),
        locations: (json['locations'] is List)
            ? (json['locations'] as List).map((e) => e.toString()).toList()
            : const [],
        rawInput: json['rawInput']?.toString(),
        rawOutput: json['rawOutput']?.toString(),
        content: ToolCallState.formatOpaque(json['content']),
      );

  static ToolCallState? tryParseContent(String content) {
    final trimmed = content.trim();
    if (!trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) return ToolCallState.fromJson(decoded);
      if (decoded is Map) {
        return ToolCallState.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return null;
  }

  static String? formatOpaque(Object? value) {
    if (value == null) return null;
    if (value is String) return value;
    try {
      return const JsonEncoder.withIndent('  ').convert(value);
    } catch (_) {
      return value.toString();
    }
  }
}
