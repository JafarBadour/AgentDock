import 'dart:convert';

/// Identity-keyed caches so huge tool JSON is not re-parsed on every rebuild.
final Expando<String> _toolPreviewCache = Expando<String>('toolPreview');

/// Coarse category of a tool call, for icons and group summaries.
enum ToolActionKind { read, edit, search, exec, web, subagent, mcp, other }

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
    this.previewHint,
    this.inputHead,
    this.outputHead,
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

  /// Summary-only fields set by [withoutPayloads]: the one-line preview and
  /// small heads of the raw I/O, computed once from the full payload so the
  /// transcript row can still say *what* the tool did without carrying blobs.
  final String? previewHint;
  final String? inputHead;
  final String? outputHead;

  bool get isActive =>
      status == 'pending' || status == 'in_progress' || status == 'running';

  bool get isFailed => status == 'failed' || status == 'error';

  /// Claude ACP marks Bash non-zero exits as `failed` — exit 1 is often
  /// intentional (`ls missing 2>/dev/null`, checks, etc.), so don't paint the
  /// whole tool group as a hard failure for those.
  bool get isSoftFail {
    if (!isFailed) return false;
    // Cap scan — full tool blobs can be 100KB+.
    final out = rawOutput ?? outputHead ?? '';
    final cont = content ?? '';
    final blob = '${out.length > 2000 ? out.substring(0, 2000) : out} '
            '${cont.length > 2000 ? cont.substring(0, 2000) : cont}'
        .toLowerCase();
    if (blob.contains('permission') ||
        blob.contains('denied') ||
        blob.contains('internal error') ||
        blob.contains('exit code 127') ||
        blob.contains('command not found')) {
      return false;
    }
    return RegExp(r'exit code 1\b').hasMatch(blob) ||
        blob.trim() == 'exit code 1';
  }

  bool get isHardFail => isFailed && !isSoftFail;

  /// Coarse category from ACP `kind` / title (cheap — never scans payloads).
  ToolActionKind get actionKind {
    final k = (kind ?? '').toLowerCase();
    final t = title.toLowerCase();
    final blob = '$k $t';
    if (k.contains('think') ||
        k.contains('task') ||
        k.contains('agent') ||
        blob.contains('subagent')) {
      return ToolActionKind.subagent;
    }
    if (k.contains('mcp') || t.startsWith('mcp__')) return ToolActionKind.mcp;
    if (blob.contains('web') ||
        blob.contains('browser') ||
        k.contains('fetch') ||
        k.contains('http')) {
      return ToolActionKind.web;
    }
    if (k.contains('exec') ||
        k.contains('shell') ||
        k.contains('terminal') ||
        k.contains('bash')) {
      return ToolActionKind.exec;
    }
    if (k.contains('read')) return ToolActionKind.read;
    if (k.contains('edit') || k.contains('write') || k.contains('delete')) {
      return ToolActionKind.edit;
    }
    if (k.contains('search') || k.contains('grep') || k.contains('glob')) {
      return ToolActionKind.search;
    }
    return ToolActionKind.other;
  }

  /// "Read 3 files · Ran 2 commands · Edited 1 file" for a run of tools.
  static String summarizeActions(List<ToolCallState> tools) {
    if (tools.isEmpty) return '';
    final counts = <ToolActionKind, int>{};
    for (final t in tools) {
      counts.update(t.actionKind, (n) => n + 1, ifAbsent: () => 1);
    }
    String noun(String one, String many, int n) => n == 1 ? one : many;
    final parts = <String>[];
    for (final kind in ToolActionKind.values) {
      final n = counts[kind];
      if (n == null) continue;
      parts.add(switch (kind) {
        ToolActionKind.read => 'Read $n ${noun('file', 'files', n)}',
        ToolActionKind.edit => 'Edited $n ${noun('file', 'files', n)}',
        ToolActionKind.search =>
          'Searched $n ${noun('time', 'times', n)}',
        ToolActionKind.exec =>
          'Ran $n ${noun('command', 'commands', n)}',
        ToolActionKind.web => 'Fetched $n ${noun('page', 'pages', n)}',
        ToolActionKind.subagent =>
          '$n ${noun('subagent', 'subagents', n)}',
        ToolActionKind.mcp => '$n MCP ${noun('call', 'calls', n)}',
        ToolActionKind.other => '$n ${noun('tool', 'tools', n)}',
      });
    }
    return parts.join(' · ');
  }

  bool get isCompleted =>
      status == 'completed' || status == 'success' || status == 'done';

  /// True when this looks like a wait/poll loop (until/sleep/while).
  bool get isPollingWait {
    final head = _inputHead.toLowerCase();
    final t = title.toLowerCase();
    return head.contains('until ') ||
        t.startsWith('until ') ||
        RegExp(r'\bsleep\s+\d').hasMatch(head) ||
        head.contains('while ') && head.contains('sleep') ||
        (head.contains('wait') &&
            (head.contains('epoch') ||
                head.contains('for ') ||
                head.contains('until')));
  }

  /// Head of [rawInput] for cheap scans (never the full 100KB blob).
  String get _inputHead {
    final input = rawInput ?? inputHead ?? '';
    return input.length > 400 ? input.substring(0, 400) : input;
  }

  String get statusLabel {
    final s = status.toLowerCase();
    if (isActive && isPollingWait) return 'Polling';
    if (s == 'in_progress' || s == 'running') return 'Running';
    if (s == 'pending') return 'Pending';
    if (s == 'completed' || s == 'success' || s == 'done') return 'Done';
    if (isSoftFail) return 'Exit 1';
    if (s == 'failed' || s == 'error') return 'Failed';
    if (s == 'cancelled' || s == 'canceled') return 'Cancelled';
    return status;
  }

  /// Human label for the row.
  ///
  /// Agents do not always send a title, and the bare fallback rendered as a
  /// row reading just "Tool", which tells the user nothing.
  String get displayTitle {
    if (isPollingWait) {
      final desc = _descriptionFromInput();
      if (desc != null) return desc;
      return isActive ? 'Waiting on remote job' : 'Waited on remote job';
    }
    final given = title.trim();
    final titleUsable = given.isNotEmpty &&
        given.toLowerCase() != 'tool' &&
        !given.startsWith('{') &&
        !given.startsWith('[') &&
        // Shell dumps the whole `until …` / multi-line script as the title.
        !given.toLowerCase().startsWith('until ') &&
        !given.toLowerCase().startsWith('while ') &&
        !_looksLikeShellDump(given);

    if (titleUsable) return given;

    // Task / subagent prompts usually put the useful name in `description`.
    final desc = _descriptionFromInput();
    if (desc != null && desc.isNotEmpty) {
      return desc.length > 72 ? '${desc.substring(0, 71)}…' : desc;
    }

    final k = (kind ?? '').toLowerCase();
    // Never scan full rawInput — Claude tool payloads can be 100KB+ JSON and
    // displayTitle is hit on every list rebuild.
    final head = _inputHead;
    final blob = '$k ${title.toLowerCase()} ${head.toLowerCase()}';
    if (k.contains('think') ||
        k.contains('task') ||
        k.contains('agent') ||
        k.contains('subagent') ||
        blob.contains('"subagent') ||
        blob.contains('task tool')) {
      return isActive ? 'Running subagent' : 'Subagent';
    }
    if (k.contains('mcp') || blob.contains('mcp__') || blob.contains('saisher')) {
      return 'MCP tool';
    }
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
    if (k.contains('exec') ||
        k.contains('shell') ||
        k.contains('terminal') ||
        k.contains('bash')) {
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
    // Last resort: first line of a shell-ish input, clipped.
    final cmd = _commandFromInput();
    if (cmd != null) return cmd;
    return 'Tool call';
  }

  /// True when the agent stuffed a whole shell script into `title`.
  static bool _looksLikeShellDump(String title) {
    if (title.length < 48) return false;
    final low = title.toLowerCase();
    if (title.contains('\n')) return true;
    return low.startsWith('echo ') ||
        low.startsWith('ls ') ||
        low.startsWith('cd ') ||
        low.startsWith('cat ') ||
        low.startsWith('python') ||
        low.startsWith('sudo ') ||
        low.contains(' && ') ||
        low.contains('; echo');
  }

  String? _commandFromInput() {
    final input = (rawInput ?? inputHead)?.trim();
    if (input == null || input.isEmpty) return null;
    final fromJson = _previewFromJson(
      input.length > 8000 ? input.substring(0, 8000) : input,
    );
    if (fromJson != null && fromJson.isNotEmpty) {
      return fromJson.length > 72 ? '${fromJson.substring(0, 71)}…' : fromJson;
    }
    return null;
  }

  String? _descriptionFromInput() {
    final input = (rawInput ?? inputHead)?.trim();
    if (input == null || input.isEmpty) return null;
    final head = input.length > 4000 ? input.substring(0, 4000) : input;
    final match = RegExp(
      '"description"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"',
    ).firstMatch(head);
    final raw = match?.group(1);
    if (raw == null || raw.trim().isEmpty) return null;
    return raw
        .replaceAll(r'\"', '"')
        .replaceAll(r'\n', ' ')
        .trim();
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
    final hint = previewHint;
    if (hint != null) return hint.isEmpty ? null : hint;
    final cached = _toolPreviewCache[this];
    if (cached != null) return cached.isEmpty ? null : cached;
    final computed = _computePreview();
    _toolPreviewCache[this] = computed ?? '';
    return computed;
  }

  String? _computePreview() {
    if (locations.isNotEmpty) return _short(locations.first);
    final input = rawInput?.trim();
    if (input == null || input.isEmpty) return null;
    // Cap decode work — preview only needs the head of huge tool JSON.
    if (input.length > 8000) {
      final head = input.substring(0, 8000);
      // Truncation usually breaks jsonDecode; pull known keys with a light scan.
      for (final key in _previewKeys) {
        final match = RegExp(
          '"$key"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"',
        ).firstMatch(head);
        final value = match?.group(1)?.trim();
        if (value != null && value.isNotEmpty) return _short(value);
      }
      final line = head.split('\n').firstWhere(
            (l) {
              final t = l.trim();
              return t.isNotEmpty &&
                  t != '{' &&
                  t != '}' &&
                  t != '[' &&
                  t != ']';
            },
            orElse: () => '',
          );
      if (line.isEmpty) return null;
      return _short(line);
    }
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
        previewHint: previewHint,
        inputHead: inputHead,
        outputHead: outputHead,
      );

  /// True when input/output/content payloads are present (heavy for the UI).
  bool get hasPayloads =>
      (rawInput?.isNotEmpty ?? false) ||
      (rawOutput?.isNotEmpty ?? false) ||
      (content?.isNotEmpty ?? false);

  /// Metadata-only copy for the transcript list — no raw I/O blobs.
  ///
  /// Keeps a precomputed [preview] plus short heads of the input/output so
  /// the row label, exit-code classification and polling detection still
  /// work on the summary.
  ToolCallState withoutPayloads() {
    if (!hasPayloads) return this;
    return ToolCallState(
      toolCallId: toolCallId,
      title: title,
      kind: kind,
      status: status,
      locations: locations.length > 8 ? locations.take(8).toList() : locations,
      previewHint: preview ?? '',
      inputHead: _head(rawInput ?? inputHead, 600),
      outputHead: _head(rawOutput ?? outputHead, 2000),
    );
  }

  static String? _head(String? value, int max) {
    if (value == null || value.isEmpty) return null;
    return value.length > max ? value.substring(0, max) : value;
  }

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
    if (value is String) {
      // Cap huge tool blobs — pretty-print used to freeze the UI isolate.
      return value.length > 180000 ? value.substring(0, 180000) : value;
    }
    try {
      // Compact JSON only. Indenting 100KB+ tool payloads on every ADSM event
      // was a primary cause of Mac/Android hitching mid-turn.
      final encoded = jsonEncode(value);
      return encoded.length > 180000
          ? encoded.substring(0, 180000)
          : encoded;
    } catch (_) {
      final s = value.toString();
      return s.length > 180000 ? s.substring(0, 180000) : s;
    }
  }
}
