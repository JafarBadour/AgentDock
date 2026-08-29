import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import 'ssh_service.dart';

/// Stock tmux session lifecycle — no third-party remote binaries.
class TmuxService {
  TmuxService(this._ssh);

  final SshService _ssh;

  static String sessionNameForChat(String chatId) {
    final safe = chatId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final trimmed = safe.length > 24 ? safe.substring(0, 24) : safe;
    return 'ap-$trimmed';
  }

  Future<bool> hasSession(Host host, String session) async {
    try {
      final out = await _ssh.exec(
        host,
        'tmux has-session -t ${SshService.shellQuote(session)} 2>/dev/null && echo YES || echo NO',
      );
      return out.trim() == 'YES';
    } catch (e) {
      SafeLog.d('tmux has-session failed', e);
      return false;
    }
  }

  /// Start a detached tmux session running [command] in [cwd].
  Future<void> createSession({
    required Host host,
    required String session,
    required String cwd,
    required String command,
  }) async {
    final exists = await hasSession(host, session);
    if (exists) return;

    final script = [
      'tmux new-session -d',
      '-s ${SshService.shellQuote(session)}',
      '-c ${SshService.shellQuote(cwd)}',
      SshService.shellQuote(command),
    ].join(' ');

    await _ssh.exec(host, script);
  }

  Future<void> killSession(Host host, String session) async {
    try {
      await _ssh.exec(
        host,
        'tmux kill-session -t ${SshService.shellQuote(session)} 2>/dev/null || true',
      );
    } catch (e) {
      SafeLog.d('tmux kill-session failed', e);
    }
  }

  Future<String> resolveCursorBinary(Host host) => _ssh.ensureCursorCli(host);
}
