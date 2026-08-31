import 'dart:async';
import 'dart:io';

import 'package:agent_dock/data/models/agent_provider.dart';
import 'package:agent_dock/data/secure/safe_log.dart';
import 'package:agent_dock/services/cursor_acp_service.dart';
import 'package:agent_dock/services/ssh_service.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('prompt idle timeout', () {
    test('a turn that keeps streaming is not cancelled', () async {
      var lastActivity = DateTime.now();
      final completer = Completer<String>();

      // Output every 40ms for ~400ms: far longer than the 100ms silence budget,
      // but never silent for 100ms at a stretch.
      final chatter = Timer.periodic(const Duration(milliseconds: 40), (t) {
        lastActivity = DateTime.now();
        if (t.tick >= 10) {
          t.cancel();
          completer.complete('done');
        }
      });
      addTearDown(chatter.cancel);

      final result = await awaitWithIdleTimeout(
        future: completer.future,
        idle: const Duration(milliseconds: 100),
        lastActivity: () => lastActivity,
        onTimeout: () => TimeoutException('stuck'),
      );

      expect(result, 'done');
    });

    test('a genuinely silent agent still times out', () async {
      final lastActivity = DateTime.now();
      await expectLater(
        awaitWithIdleTimeout(
          future: Completer<String>().future,
          idle: const Duration(milliseconds: 80),
          lastActivity: () => lastActivity,
          onTimeout: () => TimeoutException('stuck'),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('output already older than the budget fails immediately', () async {
      final stale = DateTime.now().subtract(const Duration(minutes: 10));
      await expectLater(
        awaitWithIdleTimeout(
          future: Completer<String>().future,
          idle: const Duration(minutes: 5),
          lastActivity: () => stale,
          onTimeout: () => TimeoutException('stuck'),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('turn complete parsing', () {
    test('state_update idle ends the turn', () {
      final update = AcpUpdate.fromParams({
        'sessionUpdate': 'state_update',
        'state': 'idle',
        'stopReason': 'end_turn',
      });
      expect(update.kind, AcpUpdateKind.turnComplete);
      expect(update.text, 'end_turn');
    });

    test('bare stopReason ends the turn', () {
      final update = AcpUpdate.fromParams({'stopReason': 'max_tokens'});
      expect(update.kind, AcpUpdateKind.turnComplete);
      expect(update.text, 'max_tokens');
    });

    test('running state_update is ignored', () {
      final update = AcpUpdate.fromParams({
        'sessionUpdate': 'state_update',
        'state': 'running',
      });
      expect(update.kind, AcpUpdateKind.ignored);
    });
  });

  group('plan mode updates', () {
    test('plan_update renders as assistant markdown', () {
      final update = AcpUpdate.fromParams({
        'sessionUpdate': 'plan_update',
        'plan': {
          'type': 'items',
          'planId': 'plan-1',
          'entries': [
            {'content': 'Inspect files', 'status': 'completed'},
            {'content': 'Write summary', 'status': 'pending'},
          ],
        },
      });
      expect(update.kind, AcpUpdateKind.delta);
      expect(update.text, contains('Inspect files'));
      expect(update.text, contains('[x]'));
      expect(update.text, contains('[ ] Write summary'));
    });
  });

  test('AgentProvider availability', () {
    expect(AgentProvider.cursor.isAvailable, isTrue);
    expect(AgentProvider.claude.isAvailable, isFalse);
  });

  test('SafeLog redacts private keys', () {
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----';
    expect(SafeLog.redact('key=$pem'), contains('[REDACTED]'));
    expect(SafeLog.redact('key=$pem'), isNot(contains('abc')));
  });

  group('SSH failure classification', () {
    test('credential problems are fatal and never auto-retried', () {
      expect(
        classifySshFailure(SSHAuthFailError('bad creds')).isFatal,
        isTrue,
      );
      expect(
        classifySshFailure(SSHKeyDecodeError('bad key')).isFatal,
        isTrue,
      );
      expect(
        classifySshFailure(SSHHostkeyError('unknown host')).isFatal,
        isTrue,
      );
      expect(
        classifySshFailure(StateError('No SSH private key in secure storage'))
            .isFatal,
        isTrue,
      );
    });

    test('missing remote tooling is fatal', () {
      expect(
        classifySshFailure(MissingToolException('tmux', 'install it')).isFatal,
        isTrue,
      );
    });

    test('a dead pooled socket is network, not missing tooling', () {
      expect(
        classifySshFailure(
          StateError('SSHStateError(Transport is closed)'),
        ),
        SshFailureKind.network,
      );
      expect(
        classifySshFailure(
          StateError('Connection closed while waiting for channel open'),
        ).isFatal,
        isFalse,
      );
    });

    test('transport problems are transient and safe to retry', () {
      expect(
        classifySshFailure(const SocketException('connection reset')).isFatal,
        isFalse,
      );
      expect(
        classifySshFailure(TimeoutException('slow')).isFatal,
        isFalse,
      );
      expect(
        classifySshFailure(SSHAuthAbortError('socket died mid-handshake'))
            .isFatal,
        isFalse,
      );
      expect(
        classifySshFailure(SSHSocketError('reset')).isFatal,
        isFalse,
      );
    });
  });

  group('ACP capabilities', () {
    test('reads loadSession when the agent advertises it', () {
      final caps = AcpAgentCapabilities.fromInitializeResult({
        'agentCapabilities': {'loadSession': true},
      });
      expect(caps.loadSession, isTrue);
    });

    test('accepts the snake_case spelling', () {
      final caps = AcpAgentCapabilities.fromInitializeResult({
        'agent_capabilities': {'load_session': true},
      });
      expect(caps.loadSession, isTrue);
    });

    test('defaults to unsupported when absent', () {
      expect(
        AcpAgentCapabilities.fromInitializeResult({}).loadSession,
        isFalse,
      );
      expect(
        AcpAgentCapabilities.fromInitializeResult({
          'agentCapabilities': {'loadSession': false},
        }).loadSession,
        isFalse,
      );
    });
  });

  group('shell quoting', () {
    test('escapes embedded single quotes', () {
      expect(SshService.shellQuote("it's"), r"'it'\''s'");
    });

    test('quotes paths containing spaces', () {
      expect(SshService.shellQuote('/a b/c'), "'/a b/c'");
    });
  });
}
