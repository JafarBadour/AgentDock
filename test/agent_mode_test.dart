import 'package:agent_dock/data/models/agent_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromId accepts app ids', () {
    expect(AgentSessionMode.fromId('ask'), AgentSessionMode.ask);
    expect(AgentSessionMode.fromId('agent'), AgentSessionMode.agent);
    expect(AgentSessionMode.fromId('plan'), AgentSessionMode.plan);
    expect(AgentSessionMode.fromId(null), AgentSessionMode.agent);
  });

  test('fromId tolerates native ACP ids that leak through', () {
    expect(AgentSessionMode.fromId('read-only'), AgentSessionMode.ask);
    expect(AgentSessionMode.fromId('dontAsk'), AgentSessionMode.ask);
    expect(AgentSessionMode.fromId('agent-full-access'), AgentSessionMode.agent);
    expect(AgentSessionMode.fromId('bypassPermissions'), AgentSessionMode.agent);
  });
}
