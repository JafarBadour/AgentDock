import 'dart:io';

import 'package:agent_dock/services/agent_runtime_host.dart';
import 'package:flutter_test/flutter_test.dart';

RemoteAgentSession _session({int journalSize = 0}) => RemoteAgentSession(
      dir: '/home/me/.agentdock/sessions/abc',
      tmuxSession: 'ad-abc',
      freshlyStarted: false,
      journalSize: journalSize,
    );

void main() {
  group('session naming', () {
    test('strips characters tmux cannot take in a session name', () {
      final name = AgentRuntimeHost.sessionNameForChat('a.b:c/d e');
      expect(name, 'ad-abcde');
    });

    test('truncates long chat ids', () {
      final name = AgentRuntimeHost.sessionNameForChat('x' * 100);
      expect(name.length, 'ad-'.length + 24);
    });

    test('directory is namespaced per chat', () {
      expect(
        AgentRuntimeHost.dirForChat('/home/me', 'chat-1'),
        '/home/me/.agentdock/sessions/chat-1',
      );
    });
  });

  group('bridge command', () {
    test('resumes one byte past what was already consumed', () {
      final cmd = AgentRuntimeHost.bridgeCommand(_session(), 100);
      expect(cmd, contains('tail -c +101 -f'));
    });

    test('starts at the beginning for a fresh journal', () {
      final cmd = AgentRuntimeHost.bridgeCommand(_session(), 0);
      expect(cmd, contains('tail -c +1 -f'));
    });

    test('never emits a zero or negative offset', () {
      final cmd = AgentRuntimeHost.bridgeCommand(_session(), -5);
      expect(cmd, contains('tail -c +1 -f'));
    });

    test('feeds channel stdin into the agent fifo', () {
      final cmd = AgentRuntimeHost.bridgeCommand(_session(), 0);
      // The inner script is quoted for `sh -c`, so match the surviving parts.
      expect(cmd, startsWith('sh -c '));
      expect(cmd, contains('cat > '));
      expect(cmd, contains('sessions/abc/in'));
      expect(cmd, contains('sessions/abc/out.jsonl'));
    });

    test('kills the tail follower when the channel goes away', () {
      final cmd = AgentRuntimeHost.bridgeCommand(_session(), 0);
      expect(cmd, contains('trap'));
      expect(cmd, contains('EXIT INT TERM HUP'));
    });
  });

  group('generated shell is syntactically valid', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('agentdock-test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    /// Hands the script to a real `sh -n`, which is the only honest check that
    /// several layers of nested quoting still parse.
    void expectParses(String script, String name) {
      final file = File('${tmp.path}/$name')..writeAsStringSync(script);
      final result = Process.runSync('sh', ['-n', file.path]);
      expect(
        result.exitCode,
        0,
        reason: 'sh -n rejected $name:\n${result.stderr}\n\n$script',
      );
    }

    test('run script parses, including with awkward paths', () {
      expectParses(
        AgentRuntimeHost.runScript(
          dir: '/home/me/.agentdock/sessions/abc',
          cwd: "/home/me/it's a repo",
          binary: '/home/me/.local/bin/cursor-agent',
        ),
        'run.sh',
      );
    });

    test('bootstrap script parses with a secret present', () {
      expectParses(
        AgentRuntimeHost.ensureScript(
          dir: '/home/me/.agentdock/sessions/abc',
          tmuxSession: 'ad-abc',
          cwd: "/home/me/it's a repo",
          binary: '/home/me/.local/bin/cursor-agent',
          cursorApiKey: "key-with-'quote",
        ),
        'ensure-with-key.sh',
      );
    });

    test('bootstrap script parses without a secret', () {
      expectParses(
        AgentRuntimeHost.ensureScript(
          dir: '/home/me/.agentdock/sessions/abc',
          tmuxSession: 'ad-abc',
          cwd: '/home/me/proj',
          binary: '/home/me/.local/bin/cursor-agent',
        ),
        'ensure.sh',
      );
    });

    test('bridge command parses as a single sh invocation', () {
      // Strip the `sh -c ` prefix and unwrap one layer of quoting.
      final cmd = AgentRuntimeHost.bridgeCommand(_session(), 42);
      final inner = cmd.substring('sh -c '.length);
      final unwrapped =
          inner.substring(1, inner.length - 1).replaceAll(r"'\''", "'");
      expectParses(unwrapped, 'bridge.sh');
    });

    test('the secret never reaches a process argument list', () {
      const secret = 'sk-super-secret';
      final script = AgentRuntimeHost.ensureScript(
        dir: '/home/me/.agentdock/sessions/abc',
        tmuxSession: 'ad-abc',
        cwd: '/home/me/proj',
        binary: '/home/me/.local/bin/cursor-agent',
        cursorApiKey: secret,
      );
      final tmuxLine = script
          .split('\n')
          .firstWhere((l) => l.contains('tmux new-session'));
      expect(tmuxLine, isNot(contains(secret)));
      expect(script, contains('rm -f'));
    });
  });
}
