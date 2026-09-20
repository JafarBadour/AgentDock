import 'dart:convert';
import 'dart:io';

import 'package:agent_dock/data/models/skill.dart';
import 'package:agent_dock/services/skill_folder_importer.dart';
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

  test('parseSkillMd reads frontmatter', () {
    const raw = '''
---
name: code-review
description: Reviews pull requests.
disable-model-invocation: true
---

# Body

Do the thing.
''';
    final parsed = AgentSkill.parseSkillMd(raw);
    expect(parsed.name, 'code-review');
    expect(parsed.description, 'Reviews pull requests.');
    expect(parsed.disableModelInvocation, isTrue);
    expect(parsed.bodyMarkdown, contains('# Body'));
  });

  test('bundle_json round-trips', () {
    final files = [
      SkillBundleFile(
        relativePath: 'scripts/run.sh',
        bytes: utf8.encode('#!/bin/sh\necho hi\n'),
      ),
    ];
    final encoded = SkillBundleFile.encodeList(files);
    final decoded = SkillBundleFile.decodeList(encoded);
    expect(decoded, hasLength(1));
    expect(decoded.first.relativePath, 'scripts/run.sh');
    expect(utf8.decode(decoded.first.bytes), contains('echo hi'));
  });

  test('SkillFolderImporter loads SKILL.md + extras', () async {
    final dir = await Directory.systemTemp.createTemp('skill-import-');
    addTearDown(() => dir.delete(recursive: true));
    await File('${dir.path}/SKILL.md').writeAsString('''
---
name: demo-skill
description: Demo skill for tests.
---

# Demo
''');
    await Directory('${dir.path}/scripts').create();
    await File('${dir.path}/scripts/hello.sh').writeAsString('echo hello\n');
    await File('${dir.path}/.DS_Store').writeAsBytes([0, 1, 2]);

    final imported = await SkillFolderImporter.load(dir.path);
    expect(imported.name, 'demo-skill');
    expect(imported.description, 'Demo skill for tests.');
    expect(imported.bodyMarkdown, contains('# Demo'));
    expect(imported.bundleFiles, hasLength(1));
    expect(imported.bundleFiles.first.relativePath, 'scripts/hello.sh');
  });

  test('SkillFolderImporter loadAll finds child skills', () async {
    final root = await Directory.systemTemp.createTemp('skills-root-');
    addTearDown(() => root.delete(recursive: true));
    for (final name in ['alpha', 'beta']) {
      final child = Directory('${root.path}/$name')..createSync();
      await File('${child.path}/SKILL.md').writeAsString('''
---
name: $name
description: Skill $name.
---

# $name
''');
    }

    final imports = await SkillFolderImporter.loadAll(root.path);
    expect(imports.map((e) => e.name).toList(), ['alpha', 'beta']);
  });
}
