/// A model the remote agent offers, e.g.
/// `claude-opus-5[thinking=true,context=300k,effort=high,fast=false]`.
///
/// The bracketed attributes are **not** independently selectable. The agent
/// validates `session/set_model` against its exact advertised strings and
/// rejects anything constructed, so thinking / fast / context / effort are
/// properties of a preset rather than knobs. The UI therefore surfaces them as
/// badges and filters over the list.
class AgentModel {
  const AgentModel({
    required this.modelId,
    required this.name,
    this.thinking,
    this.fast,
    this.contextWindow,
    this.effort,
  });

  /// Exact id to send back in `session/set_model`.
  final String modelId;

  /// Human label, e.g. `Auto` or `claude-opus-5`.
  final String name;

  final bool? thinking;
  final bool? fast;

  /// Context window as advertised, e.g. `300k`.
  final String? contextWindow;

  /// Reasoning effort. The agent spells this `effort` for some families and
  /// `reasoning` for others; both mean the same thing to a user.
  final String? effort;

  factory AgentModel.fromJson(Map<String, dynamic> json) {
    final id = (json['modelId'] ?? json['model_id'] ?? '').toString();
    final name = (json['name'] ?? '').toString();
    return AgentModel.parse(id, name.isEmpty ? _baseName(id) : name);
  }

  factory AgentModel.parse(String modelId, [String? displayName]) {
    final attrs = _attributes(modelId);
    return AgentModel(
      modelId: modelId,
      name: displayName ?? _baseName(modelId),
      thinking: _bool(attrs['thinking']),
      fast: _bool(attrs['fast']),
      contextWindow: attrs['context'],
      effort: attrs['effort'] ?? attrs['reasoning'],
    );
  }

  static String _baseName(String modelId) {
    final open = modelId.indexOf('[');
    return open < 0 ? modelId : modelId.substring(0, open);
  }

  static Map<String, String> _attributes(String modelId) {
    final open = modelId.indexOf('[');
    final close = modelId.lastIndexOf(']');
    if (open < 0 || close <= open) return const {};
    final inner = modelId.substring(open + 1, close);
    final out = <String, String>{};
    for (final pair in inner.split(',')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      out[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
    }
    return out;
  }

  static bool? _bool(String? value) => value == null ? null : value == 'true';

  /// Short labels shown under the model name.
  List<String> get badges => [
        if (thinking == true) 'Thinking',
        if (fast == true) 'Fast',
        if (contextWindow != null) '$contextWindow ctx',
        if (effort != null) 'Effort $effort',
      ];

  /// One-line summary for the collapsed toolbar chip.
  String get summary => badges.isEmpty ? name : '$name · ${badges.join(' · ')}';

  bool matchesQuery(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) || modelId.toLowerCase().contains(q);
  }

  @override
  bool operator ==(Object other) =>
      other is AgentModel && other.modelId == modelId;

  @override
  int get hashCode => modelId.hashCode;
}

/// Filters over the preset list, standing in for the toggles the protocol does
/// not allow us to set directly.
enum ModelFilter {
  thinking('Thinking'),
  fast('Fast'),
  largeContext('Large context');

  const ModelFilter(this.label);

  final String label;

  bool matches(AgentModel model) => switch (this) {
        ModelFilter.thinking => model.thinking == true,
        ModelFilter.fast => model.fast == true,
        ModelFilter.largeContext => _contextAtLeast(model, 250),
      };

  static bool _contextAtLeast(AgentModel model, int thousands) {
    final raw = model.contextWindow;
    if (raw == null) return false;
    final digits = RegExp(r'^(\d+)').firstMatch(raw)?.group(1);
    if (digits == null) return false;
    return (int.tryParse(digits) ?? 0) >= thousands;
  }
}
