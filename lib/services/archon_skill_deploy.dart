import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../data/models/host.dart';
import 'ssh_service.dart';

/// Runs [command] on [host] and returns its stdout.
///
/// Shaped to accept `SshService.exec` as a tear-off, which is what production
/// passes. Tests pass a fake, so nothing here needs SSH, a device, or
/// SecureStore.
typedef HostExec =
    Future<String> Function(Host host, String command, {Duration timeout});

/// Reads an app-bundle asset as text — `rootBundle.loadString` in production.
typedef AssetTextLoader = Future<String> Function(String key);

/// Installs Archon's own skill on the host Archon runs on.
///
/// Archon is a plain Claude agent until this lands: the skill is what tells it
/// to manage agents rather than do their work. So this runs on every
/// placement, not once at setup — a host that was reimaged, or whose skill was
/// edited by hand, is silently repaired the next time the user picks it.
///
/// Only the Claude root is written, unlike [SkillDeployService] which fans a
/// user skill out to Cursor and Codex too: Archon is pinned to
/// `AgentProvider.claude` by `ArchonService`, and a copy under the other roots
/// would offer every unrelated agent on the host a manager persona it has no
/// tools for.
class ArchonSkillDeploy {
  ArchonSkillDeploy({required HostExec exec, AssetTextLoader? loadAsset})
    : _exec = exec,
      _loadAsset = loadAsset ?? rootBundle.loadString;

  final HostExec _exec;
  final AssetTextLoader _loadAsset;

  /// Where the skill is authored in this repo; listed in `pubspec.yaml` assets.
  static const assetKey = 'host/archon/skill/SKILL.md';

  /// Archon's package, installed with the skill.
  ///
  /// Deliberately not left to the ADSM upload. That only runs when the host
  /// reports an older ADSM than the app wants, so a host already on the
  /// current version never receives Archon — and the skill would tell it to
  /// run `archon`, which would not be there. Placement is the moment Archon
  /// is meant to work on a host, so placement installs everything it needs.
  static const packageAssets = <String>[
    '__init__.py',
    '__main__.py',
    'paths.py',
    'store.py',
    'triggers.py',
    'directory.py',
    'cli.py',
    'daemon.py',
  ];

  /// `archon` on PATH. `python3 -m archon`, found the same way the ADSM
  /// wrapper finds an interpreter new enough to run it.
  static const wrapper = r'''
#!/usr/bin/env bash
export PYTHONPATH="$HOME/.local/share/agentdock/host${PYTHONPATH:+:$PYTHONPATH}"
export PATH="$HOME/.local/bin:$PATH"
for py in python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
    exec "$py" -m archon "$@"
  fi
done
exec python3 -m archon "$@"
''';

  /// Must match the `name:` in the skill's front matter — Claude keys a skill
  /// by its folder, and a mismatch loads nothing.
  static const skillName = 'archon';

  /// The skill folder under a host's home directory.
  /// Archon's working directory on the host, absolute.
  ///
  /// Absolute because the value is stored as a repo path and normalised, and
  /// a literal `\$HOME` survives that as `/\$HOME/...` — a directory that can
  /// never exist, which the agent reports only as a failure to open its FIFO.
  static String workspaceIn(String home) =>
      '${home.endsWith('/') ? home.substring(0, home.length - 1) : home}'
      '/.agentdock/archon/workspace';

  static String dirIn(String home) => '$home/.claude/skills/$skillName';

  /// The skill file under a host's home directory.
  static String pathIn(String home) => '${dirIn(home)}/SKILL.md';

  /// The same path as a shell expression the *host* expands.
  ///
  /// Double quotes rather than [SshService.shellQuote] precisely so `$HOME`
  /// resolves remotely; safe because every character of it is a literal from
  /// this file and none of it is user input.
  static final String _remotePathExpr = '"${pathIn(r'$HOME')}"';

  /// Put Archon's skill on [host], writing only when it is not already there.
  ///
  /// Throws [ArchonSkillDeployException] on failure. Callers must not swallow
  /// it: an agent that looks placed but has no skill answers as itself, which
  /// is far more confusing than an error at placement time.
  Future<ArchonSkillInstall> ensureOn(Host host) async {
    final desired = await _desiredContent();
    final probe = await _probe(host);

    // Always, even when the skill is unchanged: the package is what makes the
    // skill's instructions runnable, and the two can be out of step.
    await _installPackage(host, probe.home);

    if (probe.content == desired) {
      return ArchonSkillInstall(
        path: pathIn(probe.home),
        workspace: workspaceIn(probe.home),
        wrote: false,
      );
    }

    final path = pathIn(probe.home);
    // base64 rather than a heredoc: the skill is Markdown full of backticks,
    // `$`, and quotes, and none of it should reach the remote shell.
    final b64 = base64Encode(utf8.encode(desired));
    await _run(
      host,
      'mkdir -p ${SshService.shellQuote(dirIn(probe.home))} && '
      'printf %s ${SshService.shellQuote(b64)} | base64 -d '
      '> ${SshService.shellQuote(path)}',
      timeout: const Duration(seconds: 30),
      what: 'write ${pathIn('~')}',
    );
    return ArchonSkillInstall(
      path: path,
      workspace: workspaceIn(probe.home),
      wrote: true,
    );
  }

  Future<String> _desiredContent() async {
    final String text;
    try {
      text = await _loadAsset(assetKey);
    } catch (e) {
      throw ArchonSkillDeployException(
        "Archon's skill is missing from the app bundle ($assetKey)",
        cause: e,
      );
    }
    if (text.trim().isEmpty) {
      // An empty write would leave a skill folder Claude loads as nothing,
      // which reads on the host exactly like a successful install.
      throw ArchonSkillDeployException("Archon's skill asset is empty");
    }
    return text;
  }

  /// One round trip for both the home directory and the installed skill.
  ///
  /// Nothing changes on most placements, so the common case stays at a single
  /// command. `$HOME` is printed on its own line ahead of the file because the
  /// file is multi-line and the home path is not.
  Future<_Probe> _probe(Host host) async {
    const homeLine = r'''printf '%s\n' "$HOME"''';
    // Archon's working directory is made here rather than in a call of its
    // own: a chat whose cwd does not exist cannot start, and the agent's
    // failure ("could not open FIFO") says nothing about the missing folder.
    const makeWorkspace = r'''mkdir -p "$HOME/.agentdock/archon/workspace"''';
    final out = await _run(
      host,
      '$homeLine; $makeWorkspace; cat $_remotePathExpr 2>/dev/null || true',
      timeout: const Duration(seconds: 20),
      what: 'read ${pathIn('~')}',
    );
    final split = out.indexOf('\n');
    final home = (split < 0 ? out : out.substring(0, split)).trim();
    if (home.isEmpty) {
      // Falling back to a relative path would drop the skill somewhere Claude
      // never looks, and the deploy would report success.
      throw ArchonSkillDeployException(
        'Could not resolve \$HOME on ${host.displayLabel}',
      );
    }
    return _Probe(home, split < 0 ? '' : out.substring(split + 1));
  }

  /// Put Archon's package on the host and `archon` on PATH.
  ///
  /// One script: a per-file round trip to a bastion is slow enough to be felt
  /// during placement, and a half-written package is worse than none.
  Future<void> _installPackage(Host host, String home) async {
    final buf = StringBuffer()
      ..writeln('set -e')
      ..writeln('mkdir -p "\$HOME/.local/share/agentdock/host/archon" '
          '"\$HOME/.local/bin"');
    for (final name in packageAssets) {
      final String source;
      try {
        source = await _loadAsset('host/archon/$name');
      } catch (e) {
        throw ArchonSkillDeployException(
          "Archon's package is missing from the app bundle (host/archon/$name)",
          cause: e,
        );
      }
      final b64 = base64Encode(utf8.encode(source));
      buf.writeln(
        'printf %s ${SshService.shellQuote(b64)} | base64 -d > '
        '"\$HOME/.local/share/agentdock/host/archon/$name"',
      );
    }
    buf
      ..writeln(
        'printf %s ${SshService.shellQuote(base64Encode(utf8.encode(wrapper)))}'
        ' | base64 -d > "\$HOME/.local/bin/archon"',
      )
      ..writeln('chmod +x "\$HOME/.local/bin/archon"');

    await _run(
      host,
      buf.toString(),
      timeout: const Duration(seconds: 90),
      what: 'install the archon command',
    );
  }

  Future<String> _run(
    Host host,
    String command, {
    required Duration timeout,
    required String what,
  }) async {
    try {
      return await _exec(host, command, timeout: timeout);
    } catch (e) {
      throw ArchonSkillDeployException(
        'Could not $what on ${host.displayLabel}',
        cause: e,
      );
    }
  }
}

/// What [ArchonSkillDeploy.ensureOn] did.
class ArchonSkillInstall {
  const ArchonSkillInstall({
    required this.path,
    required this.workspace,
    required this.wrote,
  });

  /// Archon's working directory, created alongside the skill.
  final String workspace;

  /// Absolute path of the skill on the host.
  final String path;

  /// False when the host already had this exact skill and nothing was written.
  final bool wrote;

  @override
  String toString() =>
      'ArchonSkillInstall(${wrote ? 'wrote' : 'unchanged'} $path)';
}

/// A placement that could not install Archon's skill.
class ArchonSkillDeployException implements Exception {
  ArchonSkillDeployException(this.message, {this.cause});

  final String message;

  /// The underlying exec / bundle failure, kept so the reason reaches the user
  /// instead of just the step that failed.
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message: $cause';
}

class _Probe {
  const _Probe(this.home, this.content);

  final String home;

  /// The skill already on the host, or empty when it has none.
  final String content;
}
