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

  /// Must match the `name:` in the skill's front matter — Claude keys a skill
  /// by its folder, and a mismatch loads nothing.
  static const skillName = 'archon';

  /// The skill folder under a host's home directory.
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

    if (probe.content == desired) {
      return ArchonSkillInstall(path: pathIn(probe.home), wrote: false);
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
    return ArchonSkillInstall(path: path, wrote: true);
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
    final out = await _run(
      host,
      '$homeLine; cat $_remotePathExpr 2>/dev/null || true',
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
  const ArchonSkillInstall({required this.path, required this.wrote});

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
