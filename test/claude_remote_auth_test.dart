import 'package:agentplantation/services/claude_remote_auth.dart';
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

  test('parseLoginUrl returns one copy of an OSC 8 hyperlink', () {
    const url = 'https://claude.ai/oauth/authorize?client_id=abc&state=xyz';
    expect(
      ClaudeRemoteAuthSession.parseLoginUrl(
        'Browse to \x1b]8;;$url\x07$url\x1b]8;;\x07\nPaste code here:\n',
      ),
      url,
    );
  });

  test('parseLoginUrl returns one copy when the frame is redrawn', () {
    const url = 'https://claude.ai/oauth/authorize?client_id=abc&state=xyz';
    expect(
      ClaudeRemoteAuthSession.parseLoginUrl('$url\x1b[2K\x1b[1A$url\n'),
      url,
    );
  });
}
