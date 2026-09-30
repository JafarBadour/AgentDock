import 'dart:convert';

import 'package:agent_dock/data/models/host.dart';
import 'package:agent_dock/services/archon_skill_deploy.dart';
import 'package:flutter_test/flutter_test.dart';

final _host = Host(
  id: 'h1',
  alias: 'workstation',
  hostname: 'ws.example',
  username: 'me',
  createdAt: DateTime.utc(2026, 9, 30),
);

const _home = '/home/me';
const _skillPath = '$_home/.claude/skills/archon/SKILL.md';

const _skillV1 = '---\nname: archon\n---\n\n# Archon\n\nYou manage agents.\n';
const _skillV2 = '$_skillV1\n## Goals\n\nCheck the thing the goal names.\n';

/// A host with one file, driven through the same two commands the service
/// sends. Enough shell to answer the probe and apply the write, so the tests
/// assert on what lands on the host rather than on command strings.
class _FakeHost {
  _FakeHost({this.skill});

  /// Current contents of `~/.claude/skills/archon/SKILL.md`, null when absent.
  String? skill;

  final commands = <String>[];

  /// Commands that changed the host — the idempotency assertion.
  final writes = <String>[];

  /// Set to make the next exec throw, standing in for a dropped connection.
  Object? failWith;

  Future<String> exec(
    Host host,
    String command, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    commands.add(command);
    final failure = failWith;
    if (failure != null) {
      failWith = null;
      throw failure;
    }
    if (command.contains('base64 -d')) {
      writes.add(command);
      skill = utf8.decode(base64Decode(_payloadOf(command)));
      return '';
    }
    if (command.contains('cat ')) {
      return '$_home\n${skill ?? ''}';
    }
    fail('unexpected command: $command');
  }

  /// The base64 blob the service pipes into `base64 -d`.
  static String _payloadOf(String command) {
    final match = RegExp(r"printf %s '([A-Za-z0-9+/=]+)'").firstMatch(command);
    expect(match, isNotNull, reason: 'no base64 payload in: $command');
    return match!.group(1)!;
  }
}

void main() {
  test('fresh host gets the skill written under ~/.claude/skills', () async {
    final remote = _FakeHost();
    final deploy = ArchonSkillDeploy(
      exec: remote.exec,
      loadAsset: (key) async {
        expect(key, ArchonSkillDeploy.assetKey);
        return _skillV1;
      },
    );

    final result = await deploy.ensureOn(_host);

    expect(result.wrote, isTrue);
    expect(result.path, _skillPath);
    expect(remote.skill, _skillV1);
    // The folder has to exist first on a host that has never run Archon.
    expect(remote.writes.single, contains('mkdir -p'));
  });

  test('second deploy of the same skill writes nothing', () async {
    final remote = _FakeHost();
    final deploy = ArchonSkillDeploy(
      exec: remote.exec,
      loadAsset: (_) async => _skillV1,
    );

    await deploy.ensureOn(_host);
    remote.writes.clear();
    remote.commands.clear();

    final second = await deploy.ensureOn(_host);

    expect(second.wrote, isFalse);
    expect(second.path, _skillPath);
    expect(remote.writes, isEmpty);
    // And it costs one round trip, since this runs on every placement.
    expect(remote.commands, hasLength(1));
  });

  test('a skill edited on the host is replaced', () async {
    final remote = _FakeHost(skill: _skillV1);
    final deploy = ArchonSkillDeploy(
      exec: remote.exec,
      loadAsset: (_) async => _skillV2,
    );

    final result = await deploy.ensureOn(_host);

    expect(result.wrote, isTrue);
    expect(remote.skill, _skillV2);
  });

  test('a stale skill from an older app version is replaced', () async {
    final remote = _FakeHost(skill: _skillV2);
    final deploy = ArchonSkillDeploy(
      exec: remote.exec,
      loadAsset: (_) async => _skillV1,
    );

    expect((await deploy.ensureOn(_host)).wrote, isTrue);
    expect(remote.skill, _skillV1);
  });

  test('a failed probe throws and names the host and path', () async {
    final remote = _FakeHost()..failWith = Exception('ssh: connect refused');
    final deploy = ArchonSkillDeploy(
      exec: remote.exec,
      loadAsset: (_) async => _skillV1,
    );

    await expectLater(
      deploy.ensureOn(_host),
      throwsA(
        isA<ArchonSkillDeployException>().having(
          (e) => e.toString(),
          'message',
          allOf(
            contains('workstation'),
            contains('.claude/skills/archon/SKILL.md'),
            contains('connect refused'),
          ),
        ),
      ),
    );
    expect(remote.skill, isNull);
  });

  test('a failed write throws rather than reporting success', () async {
    final remote = _FakeHost();

    Future<String> failingExec(
      Host host,
      String command, {
      Duration timeout = const Duration(seconds: 12),
    }) async {
      if (command.contains('base64 -d')) {
        throw Exception('No space left on device');
      }
      return remote.exec(host, command, timeout: timeout);
    }

    await expectLater(
      ArchonSkillDeploy(
        exec: failingExec,
        loadAsset: (_) async => _skillV1,
      ).ensureOn(_host),
      throwsA(
        isA<ArchonSkillDeployException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('write'), contains('No space left on device')),
        ),
      ),
    );
    expect(remote.skill, isNull);
  });

  test(
    'an unreadable asset is reported, not written as an empty skill',
    () async {
      final remote = _FakeHost();
      final deploy = ArchonSkillDeploy(
        exec: remote.exec,
        loadAsset: (_) async => throw Exception('Unable to load asset'),
      );

      await expectLater(
        deploy.ensureOn(_host),
        throwsA(isA<ArchonSkillDeployException>()),
      );
      expect(remote.commands, isEmpty);
    },
  );

  test('an empty asset never reaches the host', () async {
    final remote = _FakeHost(skill: _skillV1);
    final deploy = ArchonSkillDeploy(
      exec: remote.exec,
      loadAsset: (_) async => '   \n',
    );

    await expectLater(
      deploy.ensureOn(_host),
      throwsA(isA<ArchonSkillDeployException>()),
    );
    expect(remote.skill, _skillV1);
  });

  test('an unresolvable home is an error, not a relative install', () async {
    Future<String> exec(
      Host host,
      String command, {
      Duration timeout = const Duration(seconds: 12),
    }) async => '\n';

    await expectLater(
      ArchonSkillDeploy(
        exec: exec,
        loadAsset: (_) async => _skillV1,
      ).ensureOn(_host),
      throwsA(
        isA<ArchonSkillDeployException>().having(
          (e) => e.toString(),
          'message',
          contains(r'$HOME'),
        ),
      ),
    );
  });

  test(
    'the probe reads the Claude skill root and lets the host expand HOME',
    () async {
      final remote = _FakeHost(skill: _skillV1);
      await ArchonSkillDeploy(
        exec: remote.exec,
        loadAsset: (_) async => _skillV1,
      ).ensureOn(_host);

      expect(
        remote.commands.single,
        contains(r'cat "$HOME/.claude/skills/archon/SKILL.md"'),
      );
    },
  );
}
