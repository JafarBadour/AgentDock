import 'package:agent_dock/services/archon_skill_deploy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Archon's skill is installed and kept current by the app. Skill discovery
/// must leave it alone: importing it would put an editable stub in the user's
/// skills list whose body is a placeholder, and saving that over the real one
/// would quietly turn Archon back into an ordinary agent.
void main() {
  test('the excluded name matches what is deployed', () {
    // Two constants drifting apart is how the exclusion would stop working
    // without anything failing.
    expect(ArchonSkillDeploy.skillName, 'archon');
    expect(
      ArchonSkillDeploy.assetKey.toLowerCase(),
      contains(ArchonSkillDeploy.skillName),
    );
  });

  test('the deployed path sits under the skill name', () {
    final dir = ArchonSkillDeploy.dirIn('/home/me');
    expect(dir, endsWith('/${ArchonSkillDeploy.skillName}'));
    expect(ArchonSkillDeploy.pathIn('/home/me'), startsWith(dir));
  });
}
