import 'package:agent_dock/data/models/remote_path.dart';
import 'package:agent_dock/services/archon_skill_deploy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Archon's first real placement failed here. Its repo path was the literal
/// `$HOME/.agentdock/archon/workspace`, which path normalisation turned into
/// `/$HOME/...` — a directory that can never exist. The agent reported only
/// "could not open FIFO", which says nothing about a missing folder, and the
/// error text blamed the Claude install instead.
void main() {
  test('the workspace path is absolute and survives normalisation', () {
    final path = ArchonSkillDeploy.workspaceIn('/Users/me');
    expect(path, '/Users/me/.agentdock/archon/workspace');
    // Unchanged by the normalisation every repo path goes through.
    expect(normalizeRemotePath(path), path);
  });

  test('a literal home variable would not have survived it', () {
    // The shape of the original bug, kept so it cannot come back unnoticed.
    expect(normalizeRemotePath(r'$HOME/.agentdock/archon/workspace'),
        startsWith('/\$HOME'));
  });

  test('a trailing slash on home does not double up', () {
    expect(
      ArchonSkillDeploy.workspaceIn('/Users/me/'),
      '/Users/me/.agentdock/archon/workspace',
    );
  });

  test('the workspace sits beside Archon state, not inside the skill', () {
    final home = '/Users/me';
    expect(
      ArchonSkillDeploy.workspaceIn(home),
      isNot(startsWith(ArchonSkillDeploy.dirIn(home))),
    );
  });
}
