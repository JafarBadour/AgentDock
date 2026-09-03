import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import 'ssh_service.dart';

enum ClaudeLoginPhase {
  starting,
  waitingForUrl,
  enterCode,
  verifying,
  success,
  error,
}

/// Drives `claude auth login` on a remote host over SSH PTY.
class ClaudeRemoteAuthSession {
  ClaudeRemoteAuthSession._({
    required this.host,
    required SSHSession session,
  })  : _session = session,
        phase = ClaudeLoginPhase.starting;

  final Host host;
  ClaudeLoginPhase phase;
  String? loginUrl;
  String? error;
  String _buffer = '';

  final SSHSession _session;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  Timer? _enterTimer;
  bool _closed = false;

  static final _urlRe = RegExp(
    r'https://[^\s<>"\)\]\x1b]+',
    multiLine: true,
  );
  static final _codePromptRe = RegExp(
    r'paste.*code|enter.*code|authorization code',
    caseSensitive: false,
  );
  static final _successRe = RegExp(
    r'login successful|logged in successfully|authentication successful',
    caseSensitive: false,
  );
  static final _enterPromptRe = RegExp(
    r'press enter|enter to continue',
    caseSensitive: false,
  );

  static String stripAnsi(String text) =>
      text.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');

  /// Extract the first Claude/Anthropic OAuth URL from captured PTY output.
  static String? parseLoginUrl(String buffer) {
    final plain = stripAnsi(buffer);
    for (final match in _urlRe.allMatches(plain)) {
      final url = match.group(0)!.trim();
      if (url.contains('claude') ||
          url.contains('anthropic') ||
          url.contains('console')) {
        return url;
      }
    }
    return null;
  }

  void _append(String chunk) {
    _buffer += chunk;
    if (_buffer.length > 32 * 1024) {
      _buffer = _buffer.substring(_buffer.length - 24 * 1024);
    }
    _scan();
  }

  void _scan() {
    final plain = stripAnsi(_buffer);

    if (loginUrl == null) {
      loginUrl = parseLoginUrl(_buffer);
      if (loginUrl != null) {
        phase = ClaudeLoginPhase.enterCode;
      } else if (plain.length > 80) {
        phase = ClaudeLoginPhase.waitingForUrl;
      }
    }

    if (_codePromptRe.hasMatch(plain) && loginUrl != null) {
      phase = ClaudeLoginPhase.enterCode;
    }

    if (_successRe.hasMatch(plain)) {
      phase = ClaudeLoginPhase.success;
      _scheduleEnterAck(plain);
      return;
    }

    if (_enterPromptRe.hasMatch(plain)) {
      _scheduleEnterAck(plain);
    }
  }

  void _scheduleEnterAck(String plain) {
    _enterTimer ??= Timer(const Duration(milliseconds: 400), () {
      if (_closed || phase == ClaudeLoginPhase.error) return;
      if (_enterPromptRe.hasMatch(plain) || phase == ClaudeLoginPhase.success) {
        _write('\n');
      }
    });
  }

  void _write(String text) {
    if (_closed) return;
    try {
      _session.stdin.add(utf8.encode(text));
    } catch (e) {
      SafeLog.d('claude login stdin write failed', e);
    }
  }

  void submitCode(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty || _closed) return;
    phase = ClaudeLoginPhase.verifying;
    _write('$trimmed\n');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _enterTimer?.cancel();
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    try {
      _session.close();
    } catch (_) {}
  }

  static Future<ClaudeRemoteAuthSession> start({
    required SshService ssh,
    required Host host,
  }) async {
    final client = await ssh.connect(host);
    final session = await client.shell(
      pty: const SSHPtyConfig(
        type: 'xterm-256color',
        width: 120,
        height: 40,
      ),
    );

    final auth = ClaudeRemoteAuthSession._(host: host, session: session);
    auth._stdoutSub = session.stdout.listen(auth._appendBytes);
    auth._stderrSub = session.stderr.listen(auth._appendBytes);

    auth._write(
      'export PATH="\$HOME/.local/bin:\$HOME/.npm-global/bin:\$HOME/.cursor/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH"\n',
    );
    auth._write('[ -s "\$HOME/.nvm/nvm.sh" ] && . "\$HOME/.nvm/nvm.sh"\n');
    auth._write('claude auth login\n');
    auth.phase = ClaudeLoginPhase.waitingForUrl;
    return auth;
  }

  void _appendBytes(List<int> bytes) {
    _append(utf8.decode(bytes, allowMalformed: true));
  }
}

/// Remote Claude CLI auth helpers.
class ClaudeRemoteAuth {
  ClaudeRemoteAuth(this._ssh);

  final SshService _ssh;

  static const _pathPrefix = r'''
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.cursor/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
''';

  Future<bool> isLoggedIn(Host host) async {
    try {
      await _ssh.exec(
        host,
        '''
$_pathPrefix
command -v claude >/dev/null || exit 2
claude auth status --text >/dev/null 2>&1
''',
      );
      return true;
    } catch (e) {
      SafeLog.d('claude auth status check failed', e);
      return false;
    }
  }

  Future<ClaudeRemoteAuthSession> startLogin(Host host) =>
      ClaudeRemoteAuthSession.start(ssh: _ssh, host: host);

  Future<bool> waitForSuccess(
    ClaudeRemoteAuthSession session, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (session.phase == ClaudeLoginPhase.success) {
        await session.close();
        return await isLoggedIn(session.host);
      }
      if (session.phase == ClaudeLoginPhase.error) {
        await session.close();
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    session.error ??= 'Timed out waiting for Claude login to finish.';
    session.phase = ClaudeLoginPhase.error;
    await session.close();
    return false;
  }
}
