import 'package:agent_dock/data/models/skill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('slugify and isValidName', () {
    expect(AgentSkill.slugify('Code Review!'), 'code-review');
    expect(AgentSkill.isValidName('code-review'), isTrue);
    expect(AgentSkill.isValidName('Code'), isFalse);
    expect(AgentSkill.isValidName('-bad'), isFalse);
  });

  test('toSkillMd writes frontmatter + body', () {
    final skill = AgentSkill(
      id: '1',
      name: 'code-review',
      description: 'Reviews pull requests against team standards.',
      bodyMarkdown: '# Code review\n\n1. Read the diff.\n',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final md = skill.toSkillMd();
    expect(md, contains('name: code-review'));
    expect(md, contains('description: Reviews pull requests'));
    expect(md, contains('# Code review'));
    expect(md, isNot(contains('disable-model-invocation')));
  });

  test('toSkillMd includes slash-only flag', () {
    final skill = AgentSkill(
      id: '1',
      name: 'dangerous',
      description: 'Does something careful.',
      bodyMarkdown: 'Be careful.\n',
      disableModelInvocation: true,
      createdAt: DateTime.utc(2026, 1, 1),
    );
    expect(skill.toSkillMd(), contains('disable-model-invocation: true'));
  });
}
