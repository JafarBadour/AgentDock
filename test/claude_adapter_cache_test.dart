import 'package:agentplantation/services/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lookups used to try `claude-code-acp` first, which on a host with both
/// adapters is the deprecated one with no newer models. A path saved from
/// then must be looked up again rather than trusted.
void main() {
  test('a saved claude-code-acp path is dropped', () {
    expect(
      SshService.isStaleClaudeAdapterPath(
        'claude:colibri',
        '/home/me/.nvm/versions/node/v20.20.2/bin/claude-code-acp',
      ),
      isTrue,
    );
    expect(
      SshService.isStaleClaudeAdapterPath(
        'claude:minipc',
        '/home/me/.local/bin/claude-code-acp',
      ),
      isTrue,
      reason: 'one extra lookup is cheap; telling wrappers apart is not',
    );
  });

  test('current adapters and other tools are kept', () {
    expect(
      SshService.isStaleClaudeAdapterPath(
        'claude:colibri',
        '/home/me/.nvm/versions/node/v20.20.2/bin/claude-agent-acp',
      ),
      isFalse,
    );
    expect(
      SshService.isStaleClaudeAdapterPath(
        'claude:pc',
        r'C:\Users\me\AppData\Roaming\npm\claude-agent-acp.cmd',
      ),
      isFalse,
    );
    expect(
      SshService.isStaleClaudeAdapterPath('codex:x', '/usr/bin/claude-code-acp'),
      isFalse,
    );
  });
}
