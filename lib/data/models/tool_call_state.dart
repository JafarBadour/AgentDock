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
  });

  final String toolCallId;
  final String title;
  final String? kind;
  final String status;
  final List<String> locations;
  final String? rawInput;
  final String? rawOutput;

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

  String? get preview {
    if (locations.isNotEmpty) return locations.first;
    final input = rawInput?.trim();
    if (input == null || input.isEmpty) return null;
    final line = input.split('\n').firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => input,
        );
    final compact = line.trim().replaceAll(RegExp(r'\s+'), ' ');
    return compact.length <= 100 ? compact : '${compact.substring(0, 99)}…';
  }

  ToolCallState merge({
    String? title,
    String? kind,
    String? status,
    List<String>? locations,
    String? rawInput,
    String? rawOutput,
  }) =>
      ToolCallState(
        toolCallId: toolCallId,
        title: (title != null && title.isNotEmpty) ? title : this.title,
        kind: kind ?? this.kind,
        status: (status != null && status.isNotEmpty) ? status : this.status,
        locations: locations ?? this.locations,
        rawInput: rawInput ?? this.rawInput,
        rawOutput: rawOutput ?? this.rawOutput,
      );

  Map<String, dynamic> toJson() => {
        'toolCallId': toolCallId,
        'title': title,
        if (kind != null) 'kind': kind,
        'status': status,
        'locations': locations,
        if (rawInput != null) 'rawInput': rawInput,
        if (rawOutput != null) 'rawOutput': rawOutput,
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
