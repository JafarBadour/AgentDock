import 'package:agentic_phone/data/models/agent_provider.dart';
import 'package:agentic_phone/data/secure/safe_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AgentProvider availability', () {
    expect(AgentProvider.cursor.isAvailable, isTrue);
    expect(AgentProvider.claude.isAvailable, isFalse);
  });

  test('SafeLog redacts private keys', () {
    const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----';
    expect(SafeLog.redact('key=$pem'), contains('[REDACTED]'));
    expect(SafeLog.redact('key=$pem'), isNot(contains('abc')));
  });
}
