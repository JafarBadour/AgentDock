import 'package:agentplantation/data/models/agent_provider.dart';
import 'package:agentplantation/data/models/chat.dart';
import 'package:agentplantation/data/models/host.dart';
import 'package:agentplantation/data/models/repo.dart';
import 'package:agentplantation/features/agents/agents_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t = DateTime(2026);
  final host = Host(
    id: 'h',
    alias: 'Workstation',
    hostname: 'gpu-box.lan',
    username: 'me',
    createdAt: t,
  );
  final repo = Repo(
    id: 'r',
    hostId: 'h',
    name: 'agentic-phone',
    remotePath: '/home/me/src/agentic-phone',
    createdAt: t,
  );
  final chat = Chat(
    id: 'c',
    repoId: 'r',
    title: 'Fix transcript scrolling',
    provider: AgentProvider.claude,
    createdAt: t,
    updatedAt: t,
  );

  bool m(String q) =>
      agentMatchesSearch(query: q, chat: chat, repo: repo, host: host);

  test('empty or blank query matches everything', () {
    expect(m(''), isTrue);
    expect(m('   '), isTrue);
  });

  test('matches title, folder, host and provider case-insensitively', () {
    expect(m('TRANSCRIPT'), isTrue);
    expect(m('agentic'), isTrue);
    expect(m('src/agentic'), isTrue);
    expect(m('workstation'), isTrue);
    expect(m('gpu-box'), isTrue);
    expect(m('claude'), isTrue);
  });

  test('every term must match, across fields', () {
    expect(m('scroll workstation'), isTrue);
    expect(m('scroll codex'), isFalse);
    expect(m('nothing-here'), isFalse);
  });
}
