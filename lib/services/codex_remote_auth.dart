import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import 'ssh_service.dart';

enum CodexLoginPhase {
  starting,
  waitingForCode,

  /// URL and one-time code are known; waiting for the user to approve in
  /// the browser (the CLI on the host polls OpenAI until then).
  waitingForApproval,
  success,
  error,
}

/// Drives `codex login --device-auth` on a remote host over an SSH PTY.
///
/// Unlike Claude's flow (paste a code *back* into the CLI), Codex's device
/// flow goes the other way: the CLI prints a verification URL plus a one-time
/// code, the user enters the code on the web, and the CLI completes on its
/// own. Starting this flow signs out any existing Codex session on the host.
class CodexRemoteAuthSession {
  CodexRemoteAuthSession._({
    required this.host,
    required SSHSession session,
  })  : _session = session,
        phase = CodexLoginPhase.starting;

  final Host host;
  CodexLoginPhase phase;
  String? loginUrl;
  String? userCode;
  String? error;
  String _buffer = '';

  final SSHSession _session;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  bool _closed = false;

  /// True once [close] ran (user cancelled or the flow finished).
  bool get isClosed => _closed;

  static final _urlRe = RegExp(
    r'https://[^\s<>"\)\]\x1b]+',
    multiLine: true,
  );

  /// `QXGT-9ANR6`-style device codes.
  static final _codeRe = RegExp(r'\b([A-Z0-9]{4,6}-[A-Z0-9]{4,6})\b');
  static final _successRe = RegExp(
    r'successfully logged in|login successful|logged in as|'
    r'authentication successful|you are now logged in',
    caseSensitive: false,
  );
  static final _failureRe = RegExp(
    r'expired|denied|access_denied|login failed|failed to login|'
    r'error:|not authorized',
    caseSensitive: false,
  );

  static String stripAnsi(String text) =>
      text.replaceAll(RegExp(r'\x1B\[[0-9;?]*[ -/]*[@-~]'), '');

  /// First OpenAI device-auth URL in captured PTY output.
  static String? parseLoginUrl(String buffer) {
    final plain = stripAnsi(buffer);
    for (final match in _urlRe.allMatches(plain)) {
      final url = match.group(0)!.trim();
      if (url.contains('openai.com') || url.contains('chatgpt.com')) {
        return url;
      }
    }
    return null;
  }

  /// One-time code printed after the verification URL.
  static String? parseUserCode(String buffer) {
    final plain = stripAnsi(buffer);
    // Only trust a code that appears after the URL — avoids matching version
    // strings or hashes in banner text.
    final urlIdx = plain.indexOf('openai.com');
    final haystack = urlIdx >= 0 ? plain.substring(urlIdx) : plain;
    return _codeRe.firstMatch(haystack)?.group(1);
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

    loginUrl ??= parseLoginUrl(_buffer);
    if (loginUrl != null) {
      userCode ??= parseUserCode(_buffer);
    }
    if (loginUrl != null && userCode != null) {
      if (phase == CodexLoginPhase.starting ||
          phase == CodexLoginPhase.waitingForCode) {
        phase = CodexLoginPhase.waitingForApproval;
      }
    } else if (plain.length > 40 && phase == CodexLoginPhase.starting) {
      phase = CodexLoginPhase.waitingForCode;
    }

    if (_successRe.hasMatch(plain)) {
      phase = CodexLoginPhase.success;
      return;
    }
    if (phase == CodexLoginPhase.waitingForApproval) {
      // Only text printed *after* the code counts as an outcome.
      final codeIdx = plain.indexOf(userCode!);
      final tail = codeIdx >= 0 ? plain.substring(codeIdx + userCode!.length) : '';
      if (_failureRe.hasMatch(tail)) {
        error ??= 'Codex reported the login failed or expired.';
        phase = CodexLoginPhase.error;
      }
    }
  }

  void _write(String text) {
    if (_closed) return;
    try {
      _session.stdin.add(utf8.encode(text));
    } catch (e) {
      SafeLog.d('codex login stdin write failed', e);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    try {
      // Ctrl-C the CLI so an abandoned login doesn't keep polling.
      _session.stdin.add(Uint8List.fromList(const [3]));
    } catch (_) {}
    try {
      _session.close();
    } catch (_) {}
  }

  static Future<CodexRemoteAuthSession> start({
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

    final auth = CodexRemoteAuthSession._(host: host, session: session);
    auth._stdoutSub = session.stdout.listen(auth._appendBytes);
    auth._stderrSub = session.stderr.listen(auth._appendBytes);

    auth._write('${CodexRemoteAuth.pathPrefix}\n');
    auth._write('codex login --device-auth\n');
    auth.phase = CodexLoginPhase.waitingForCode;
    return auth;
  }

  void _appendBytes(List<int> bytes) {
    _append(utf8.decode(bytes, allowMalformed: true));
  }
}

/// Remote Codex CLI auth helpers.
class CodexRemoteAuth {
  CodexRemoteAuth(this._ssh);

  final SshService _ssh;

  static const pathPrefix = r'''
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
[ -s "$HOME/.nvm/nvm.sh" ] && . "$HOME/.nvm/nvm.sh"
for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
''';

  /// `codex login status` exits 0 when a ChatGPT session or API key is stored.
  Future<bool> isLoggedIn(Host host) async {
    try {
      await _ssh.exec(
        host,
        '''
$pathPrefix
command -v codex >/dev/null || exit 2
codex login status >/dev/null 2>&1
''',
      );
      return true;
    } catch (e) {
      SafeLog.d('codex login status check failed', e);
      return false;
    }
  }

  Future<CodexRemoteAuthSession> startLogin(Host host) =>
      CodexRemoteAuthSession.start(ssh: _ssh, host: host);

  /// Waits for the CLI to report success, or for `codex login status` to flip
  /// (the CLI's success line is not guaranteed to reach the PTY buffer).
  Future<bool> waitForSuccess(
    CodexRemoteAuthSession session, {
    Duration timeout = const Duration(minutes: 15),
    Duration statusPoll = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var nextPoll = DateTime.now().add(statusPoll);
    while (DateTime.now().isBefore(deadline)) {
      if (session.phase == CodexLoginPhase.success) {
        await session.close();
        return true;
      }
      if (session.phase == CodexLoginPhase.error) {
        await session.close();
        return false;
      }
      // Sheet dismissed — stop polling the host.
      if (session.isClosed) return false;
      if (session.phase == CodexLoginPhase.waitingForApproval &&
          DateTime.now().isAfter(nextPoll)) {
        nextPoll = DateTime.now().add(statusPoll);
        if (await isLoggedIn(session.host)) {
          session.phase = CodexLoginPhase.success;
          await session.close();
          return true;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    session.error ??= 'Timed out waiting for Codex login to finish.';
    session.phase = CodexLoginPhase.error;
    await session.close();
    return false;
  }
}
