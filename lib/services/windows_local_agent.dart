import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../data/secure/safe_log.dart';

/// Agents on This PC (Windows) without SSH, tmux or bash.
///
/// ADSM runs as `python -m adsm` straight from its install dir; the daemon
/// owns each agent process (see `host/adsm/winproc.py`) and listens on a
/// token-protected loopback port.
class WindowsLocalAgent {
  WindowsLocalAgent._();

  static String get _home =>
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';

  /// Where `adsm/*.py` is installed (same layout as `~/.local/share` on POSIX).
  static String get adsmHostDir =>
      p.join(_home, '.local', 'share', 'agentdock', 'host');

  static List<String>? _python;

  /// `python -m adsm …` environment.
  static Map<String, String> adsmEnvironment() {
    final existing = Platform.environment['PYTHONPATH'];
    return {
      ...Platform.environment,
      'PYTHONPATH': existing == null || existing.isEmpty
          ? adsmHostDir
          : '$adsmHostDir;$existing',
      // Python writes status lines to a pipe; keep them UTF-8.
      'PYTHONIOENCODING': 'utf-8',
    };
  }

  /// Command (and leading args) of a Python ≥ 3.9 on PATH.
  static Future<List<String>> python() async {
    final cached = _python;
    if (cached != null) return cached;
    const candidates = [
      ['python'],
      ['py', '-3'],
      ['python3'],
    ];
    for (final c in candidates) {
      try {
        final r = await Process.run(c.first, [
          ...c.skip(1),
          '-c',
          'import sys; print(sys.version_info >= (3, 9))',
        ]).timeout(const Duration(seconds: 15));
        if (r.exitCode == 0 && (r.stdout as String).trim() == 'True') {
          return _python = c;
        }
      } catch (_) {
        // Not on PATH (or the Microsoft Store stub) — try the next one.
      }
    }
    throw StateError(
      'Python 3.9+ was not found on This PC. Install it from python.org '
      '(or `winget install Python.Python.3.12`), then reconnect.',
    );
  }

  /// Run `python -m adsm <args>`.
  static Future<ProcessResult> runAdsm(
    List<String> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final py = await python();
    return Process.run(
      py.first,
      [...py.skip(1), '-m', 'adsm', ...args],
      environment: adsmEnvironment(),
      workingDirectory: _home.isEmpty ? null : _home,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);
  }

  /// Start `python -m adsm client` — the stdio NDJSON bridge to the daemon.
  static Future<Process> startClient() async {
    final py = await python();
    return Process.start(
      py.first,
      [...py.skip(1), '-m', 'adsm', 'client'],
      environment: adsmEnvironment(),
      workingDirectory: _home.isEmpty ? null : _home,
    );
  }

  /// Version of the running daemon, or null when it is not running.
  static Future<String?> runningVersion() async {
    try {
      final r = await runAdsm(['status'], timeout: const Duration(seconds: 15));
      if (r.exitCode != 0) return null;
      for (final line in (r.stdout as String).split('\n')) {
        final t = line.trim();
        if (!t.startsWith('{')) continue;
        final msg = jsonDecode(t);
        if (msg is! Map) continue;
        final result = msg['result'];
        if (result is Map && result['version'] != null) {
          return result['version'].toString();
        }
      }
    } catch (e) {
      SafeLog.d('local ADSM status failed', e);
    }
    return null;
  }

  /// Install [payloads] (`adsm/<name>` → bytes), then restart the daemon.
  static Future<void> installAndRestart(Map<String, Uint8List> payloads) async {
    final dir = Directory(p.join(adsmHostDir, 'adsm'));
    await dir.create(recursive: true);
    // Stop first: the running daemon holds these modules open.
    await runAdsm(['stop']).catchError((Object e) {
      SafeLog.d('local ADSM stop failed', e);
      return ProcessResult(0, 1, '', '$e');
    });
    for (final entry in payloads.entries) {
      await File(p.join(dir.path, entry.key)).writeAsBytes(entry.value);
    }
    final started = await runAdsm(['ensure-running']);
    if (started.exitCode != 0) {
      throw StateError(
        'ADSM did not start on This PC: '
                '${(started.stderr as String).trim()} '
                '${(started.stdout as String).trim()}'
            .trim(),
      );
    }
  }

  /// Find an npm-installed agent (`<name>.cmd` in the npm global dir or on
  /// PATH). Returns an absolute Windows path, or null.
  static Future<String?> findNpmAgent(List<String> names) async {
    final appData = Platform.environment['APPDATA'];
    for (final name in names) {
      if (appData != null) {
        final shim = File(p.join(appData, 'npm', '$name.cmd'));
        if (await shim.exists()) return shim.path;
      }
      try {
        final r = await Process.run('where', [name]);
        if (r.exitCode == 0) {
          for (final line in (r.stdout as String).split('\n')) {
            final t = line.trim();
            if (t.isNotEmpty &&
                RegExp(r'\.(cmd|exe|bat)$', caseSensitive: false).hasMatch(t)) {
              return t;
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// `npm install -g <package>`. Throws with guidance when Node is missing.
  static Future<void> npmInstallGlobal(String package) async {
    ProcessResult r;
    try {
      // npm is `npm.cmd`; runInShell lets Windows resolve it.
      r = await Process.run('npm', [
        'install',
        '-g',
        package,
      ], runInShell: true).timeout(const Duration(minutes: 8));
    } catch (e) {
      throw StateError(_nodeHint(package));
    }
    if (r.exitCode != 0) {
      final err = '${r.stderr}'.trim();
      if (err.contains('is not recognized')) {
        throw StateError(_nodeHint(package));
      }
      throw StateError('npm install -g $package failed: $err');
    }
  }

  static String _nodeHint(String package) =>
      'Node.js is not installed on This PC. Install it '
      '(`winget install OpenJS.NodeJS.LTS`), then run '
      '`npm install -g $package` and reconnect.';
}
