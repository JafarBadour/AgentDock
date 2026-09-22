/// Agent provider selected for a chat.
enum AgentProvider {
  cursor,
  claude,
  codex,
}

extension AgentProviderX on AgentProvider {
  String get id => name;

  String get label => switch (this) {
        AgentProvider.cursor => 'Cursor',
        AgentProvider.claude => 'Claude',
        AgentProvider.codex => 'Codex',
      };

  /// Cursor, Claude and Codex all run as remote ACP agents.
  bool get isAvailable => true;

  /// CLI login command on the host (shown in setup / re-auth hints).
  String get hostLoginCommand => switch (this) {
        AgentProvider.cursor => 'agent login',
        AgentProvider.claude => 'claude login',
        AgentProvider.codex => 'codex login --device-auth',
      };

  /// Env var the host worker reads when a phone-stored API key is injected.
  String get apiKeyEnvVar => switch (this) {
        AgentProvider.cursor => 'CURSOR_API_KEY',
        AgentProvider.claude => 'ANTHROPIC_API_KEY',
        AgentProvider.codex => 'OPENAI_API_KEY',
      };

  static AgentProvider fromId(String id) =>
      AgentProvider.values.firstWhere((p) => p.id == id, orElse: () => AgentProvider.cursor);
}
