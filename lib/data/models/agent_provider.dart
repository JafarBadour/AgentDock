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

  /// Both Cursor and Claude run as remote ACP agents.
  bool get isAvailable => true;

  static AgentProvider fromId(String id) =>
      AgentProvider.values.firstWhere((p) => p.id == id, orElse: () => AgentProvider.cursor);
}
