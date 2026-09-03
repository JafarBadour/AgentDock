import 'package:agent_dock/services/claude_remote_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stripAnsi removes terminal color codes', () {
    expect(
      ClaudeRemoteAuthSession.stripAnsi('\x1b[31mhello\x1b[0m'),
      'hello',
    );
  });

  test('parseLoginUrl finds Claude OAuth link in PTY output', () {
    const sample = '''
Browse to: https://claude.ai/oauth/authorize?client_id=abc&state=xyz
Paste code here if prompted:
''';
    expect(
      ClaudeRemoteAuthSession.parseLoginUrl(sample),
      'https://claude.ai/oauth/authorize?client_id=abc&state=xyz',
    );
  });
}
