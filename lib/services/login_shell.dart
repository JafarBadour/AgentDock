import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_pty/flutter_pty.dart';

import '../data/models/host.dart';
import 'local_host_bootstrap.dart';
import 'ssh_service.dart';

/// An interactive PTY shell on a host, for CLI sign-in flows
/// (`claude auth login`, `codex login`). This Mac/PC gets a local PTY, so
/// signing in there needs no Remote Login / OpenSSH Server.
abstract class LoginShell {
  static Future<LoginShell> open(SshService ssh, Host host) async {
    if (ssh.runsLocally(host)) return _LocalLoginShell.start();
    final client = await ssh.connect(host);
    final session = await client.shell(
      pty: const SSHPtyConfig(type: 'xterm-256color', width: 120, height: 40),
    );
    return _SshLoginShell(session);
  }

  /// stdout and stderr, merged.
  Stream<List<int>> get output;

  void write(List<int> bytes);

  void close();
}

class _SshLoginShell implements LoginShell {
  _SshLoginShell(this._session);

  final SSHSession _session;

  @override
  late final Stream<List<int>> output = () {
    final merged = StreamController<List<int>>();
    var open = 2;
    for (final s in [_session.stdout, _session.stderr]) {
      s.listen(
        merged.add,
        onError: merged.addError,
        onDone: () {
          if (--open == 0) merged.close();
        },
      );
    }
    return merged.stream;
  }();

  @override
  void write(List<int> bytes) => _session.stdin.add(Uint8List.fromList(bytes));

  @override
  void close() => _session.close();
}

class _LocalLoginShell implements LoginShell {
  _LocalLoginShell(this._pty);

  factory _LocalLoginShell.start() {
    final env = {...Platform.environment, 'TERM': 'xterm-256color'};
    // Windows: Git Bash, so the sign-in scripts (bash) run as written and the
    // credentials land in %USERPROFILE%, where the native agents read them.
    final pty = Pty.start(
      Platform.isWindows
          ? localBashExecutable()
          : Platform.environment['SHELL'] ?? '/bin/bash',
      arguments: const ['-l'],
      workingDirectory:
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'],
      environment: env,
      columns: 120,
      rows: 40,
    );
    return _LocalLoginShell(pty);
  }

  final Pty _pty;

  @override
  Stream<List<int>> get output => _pty.output;

  @override
  void write(List<int> bytes) => _pty.write(Uint8List.fromList(bytes));

  @override
  void close() => _pty.kill();
}
