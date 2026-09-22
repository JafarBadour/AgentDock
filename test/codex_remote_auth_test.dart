import 'package:agent_dock/services/codex_remote_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Captured from `codex login --device-auth` (codex-cli 0.155.1).
  const sample = '\x1b[1mWelcome to Codex [v0.155.1]\x1b[0m\r\n'
      "OpenAI's command-line coding agent\r\n"
      '\r\n'
      'Follow these steps to sign in with ChatGPT using device code authorization:\r\n'
      '\r\n'
      '1. Open this link in your browser and sign in to your account\r\n'
      '   \x1b[4mhttps://auth.openai.com/codex/device\x1b[0m\r\n'
      '\r\n'
      '2. Enter this one-time code (expires in 15 minutes)\r\n'
      '   \x1b[1mQXGT-9ANR6\x1b[0m\r\n'
      '\r\n'
      'Continue only if you started this login in Codex.\r\n';

  test('parseLoginUrl finds the OpenAI device URL', () {
    expect(
      CodexRemoteAuthSession.parseLoginUrl(sample),
      'https://auth.openai.com/codex/device',
    );
  });

  test('parseUserCode finds the one-time code after the URL', () {
    expect(CodexRemoteAuthSession.parseUserCode(sample), 'QXGT-9ANR6');
  });

  test('parseUserCode ignores version-like tokens before the URL', () {
    const noisy = 'codex-cli 0.155.1 build ABCD-12345 ok\n$sample';
    expect(CodexRemoteAuthSession.parseUserCode(noisy), 'QXGT-9ANR6');
  });

  test('parseLoginUrl ignores unrelated links', () {
    expect(
      CodexRemoteAuthSession.parseLoginUrl(
        'see https://example.com/docs for help',
      ),
      isNull,
    );
  });

  test('device-auth disabled message is recognised', () {
    const out = 'Enable device code authorization for Codex in ChatGPT '
        'Security Settings, then run "codex login --device-auth" again.';
    expect(CodexRemoteAuthSession.isDeviceAuthDisabledOutput(out), isTrue);
    expect(CodexRemoteAuthSession.isDeviceAuthDisabledOutput(sample), isFalse);
    expect(CodexRemoteAuthSession.deviceAuthDisabledHint, contains('Security'));
  });

  test('startup failures are recognised before any URL', () {
    expect(
      CodexRemoteAuthSession.isStartupFailureOutput(
        'bash: codex: command not found',
      ),
      isTrue,
    );
    expect(
      CodexRemoteAuthSession.isStartupFailureOutput(
        "error: unexpected argument '--device-auth' found",
      ),
      isTrue,
    );
    expect(CodexRemoteAuthSession.isStartupFailureOutput(sample), isFalse);
  });
}
