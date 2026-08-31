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

/// How tool permissions are handled for this chat.
enum PermissionPolicy {
  /// Prompt on the phone for each tool that needs approval.
  ask,
  /// Shift+Tab "full access": host agent runs with --force and auto-approves.
  allowAll;

  String get label => switch (this) {
        PermissionPolicy.ask => 'Ask',
        PermissionPolicy.allowAll => 'Allow all',
      };

  String get subtitle => switch (this) {
        PermissionPolicy.ask => 'Approve each tool on this device',
        PermissionPolicy.allowAll =>
          'Full access on the host — no prompts (works with the app closed)',
      };

  /// Whether the durable host process should start with --force / --yolo.
  bool get fullAccess => this == PermissionPolicy.allowAll;
}
