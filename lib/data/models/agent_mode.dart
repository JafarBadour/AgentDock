/// Agent session mode (ACP `session/set_mode`).
enum AgentSessionMode {
  ask,
  agent,
  plan;

  String get id => name;

  String get label => switch (this) {
        AgentSessionMode.ask => 'Ask',
        AgentSessionMode.agent => 'Agent',
        AgentSessionMode.plan => 'Plan',
      };

  String get subtitle => switch (this) {
        AgentSessionMode.ask => 'Answers only — no edits or shell',
        AgentSessionMode.agent => 'Full agent: edit, tools, shell',
        AgentSessionMode.plan => 'Plan first — read-only analysis',
      };

  static AgentSessionMode fromId(String? id) {
    if (id == null || id.isEmpty) return AgentSessionMode.agent;
    return AgentSessionMode.values.firstWhere(
      (m) => m.id == id || m.name == id,
      orElse: () => AgentSessionMode.agent,
    );
  }
}

/// How the client answers `session/request_permission`.
enum PermissionPolicy {
  /// Prompt / allow once (default).
  ask,
  /// Auto-approve with allow-always.
  allowAll;

  String get label => switch (this) {
        PermissionPolicy.ask => 'Ask',
        PermissionPolicy.allowAll => 'Allow all',
      };
}
