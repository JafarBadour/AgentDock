/// Agent provider selected for a chat.
enum AgentProvider {
  cursor,
  claude,
}

extension AgentProviderX on AgentProvider {
  String get id => name;

  String get label => switch (this) {
        AgentProvider.cursor => 'Cursor',
        AgentProvider.claude => 'Claude',
      };

  /// Claude is beta and cannot start sessions yet.
  bool get isAvailable => this == AgentProvider.cursor;

  static AgentProvider fromId(String id) =>
      AgentProvider.values.firstWhere((p) => p.id == id, orElse: () => AgentProvider.cursor);
}
