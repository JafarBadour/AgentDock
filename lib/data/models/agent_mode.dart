import 'agent_provider.dart';

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

  /// Provider-specific wording where the native mode differs from the
  /// generic app semantics.
  String subtitleFor(AgentProvider provider) {
    if (provider == AgentProvider.codex) {
      return switch (this) {
        // codex-acp `read-only` preset: workspace edits/commands still run;
        // approval is asked for anything outside the workspace or network.
        AgentSessionMode.ask =>
          'Ask for approval outside the workspace or network',
        AgentSessionMode.agent => 'Full agent: edit, tools, shell',
        AgentSessionMode.plan => 'Plan before making changes',
      };
    }
    return subtitle;
  }

  static AgentSessionMode fromId(String? id) {
    if (id == null || id.isEmpty) return AgentSessionMode.agent;
    for (final m in AgentSessionMode.values) {
      if (m.id == id || m.name == id) return m;
    }
    // ADSM normally reports app ids, but native ACP ids can leak through
    // (Claude `dontAsk`, Codex `read-only` / `agent-full-access`).
    switch (id.toLowerCase()) {
      case 'dontask':
      case 'read-only':
      case 'readonly':
        return AgentSessionMode.ask;
      default:
        return AgentSessionMode.agent;
    }
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
