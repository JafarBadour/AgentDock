import 'dart:convert';

import '../data/models/agent_provider.dart';
import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import 'ssh_service.dart';

/// State of the remote agent process after [AgentRuntimeHost.ensure].
class RemoteAgentSession {
  const RemoteAgentSession({
    required this.dir,
    required this.tmuxSession,
    required this.freshlyStarted,
    required this.journalSize,
  });

  /// `~/.agentdock/sessions/<chatId>`.
  final String dir;
  final String tmuxSession;

  /// True when we started the process just now, so it still needs the ACP
  /// handshake. False means we attached to one that is already initialized.
  final bool freshlyStarted;

  /// Bytes currently in the journal, used to sanity-check a stored offset.
  final int journalSize;

  String get journalPath => '$dir/out.jsonl';
  String get stdinPath => '$dir/in';
}

/// Runs the ACP agent as a detached, tmux-supervised process on the host.
///
/// The agent's stdio deliberately does **not** go through the tmux PTY. A pane
/// is a terminal: writing long JSON-RPC lines into it hits the ~4KB canonical
/// line limit and reading back via `capture-pane` is lossy because of wrapping
/// and scrollback limits. Instead tmux only supervises the process, while:
///
///  * stdin is a FIFO held open by a parked `sleep`, so a client disconnecting
///    never sends EOF to the agent, and
///  * stdout is appended to a plain journal file, so output produced while no
///    phone is attached is durably kept and can be replayed from a byte offset.
class AgentRuntimeHost {
  AgentRuntimeHost(this._ssh);

  final SshService _ssh;

  static String sessionNameForChat(String chatId) {
    final safe = chatId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return 'ad-${safe.length > 24 ? safe.substring(0, 24) : safe}';
  }

  static String dirForChat(String home, String chatId) {
    final safe = chatId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return '$home/.agentdock/sessions/$safe';
  }

  /// Start the agent for [chatId] if it isn't already running with the same
  /// [fullAccess] mode. A mode mismatch restarts the process (journal kept).
  Future<RemoteAgentSession> ensure({
    required Host host,
    required String chatId,
    required String cwd,
    required String binary,
    AgentProvider provider = AgentProvider.cursor,
    String? apiKey,
    bool fullAccess = true,
  }) async {
    final home = await _ssh.remoteHomeDirectory(host);
    final dir = dirForChat(home, chatId);
    final tmux = sessionNameForChat(chatId);

    final script = ensureScript(
      dir: dir,
      tmuxSession: tmux,
      cwd: cwd,
      binary: binary,
      provider: provider,
      apiKey: apiKey,
      fullAccess: fullAccess,
    );

    final out = await _ssh.exec(host, 'sh -c ${SshService.shellQuote(script)}');
    final parts = out.trim().split(RegExp(r'\s+'));
    final state = parts.isNotEmpty ? parts.first : '';
    final size = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;

    SafeLog.d(
      'agent runtime $tmux state=$state journal=$size '
      'provider=${provider.id} fullAccess=$fullAccess',
    );
    return RemoteAgentSession(
      dir: dir,
      tmuxSession: tmux,
      freshlyStarted: state != 'RUNNING',
      journalSize: size,
    );
  }

  /// Command that bridges one SSH channel to the detached agent.
  ///
  /// stdout of the channel streams the journal from [fromByte]; stdin of the
  /// channel is funnelled into the agent's FIFO.
  static String bridgeCommand(RemoteAgentSession session, int fromByte) {
    final q = SshService.shellQuote;
    // `tail -c +N` is 1-based, so resuming after N consumed bytes starts at N+1.
    final start = fromByte < 0 ? 1 : fromByte + 1;
    final script = 'tail -c +$start -f ${q(session.journalPath)} & '
        'TAILPID=\$!; '
        'trap "kill \$TAILPID 2>/dev/null" EXIT INT TERM HUP; '
        'cat > ${q(session.stdinPath)}';
    return 'sh -c ${q(script)}';
  }

  Future<bool> isRunning(Host host, String chatId) async {
    final tmux = sessionNameForChat(chatId);
    try {
      final out = await _ssh.exec(
        host,
        'tmux has-session -t ${SshService.shellQuote(tmux)} 2>/dev/null '
        '&& echo YES || echo NO',
      );
      return out.trim() == 'YES';
    } catch (e) {
      SafeLog.d('agent runtime has-session failed', e);
      return false;
    }
  }

  /// Stop the agent and clear its journal.
  Future<void> stop(Host host, String chatId) async {
    final tmux = sessionNameForChat(chatId);
    final q = SshService.shellQuote;
    try {
      final home = await _ssh.remoteHomeDirectory(host);
      final dir = dirForChat(home, chatId);
      await _ssh.exec(
        host,
        'tmux kill-session -t ${q(tmux)} 2>/dev/null; rm -rf ${q(dir)}; true',
      );
    } catch (e) {
      SafeLog.d('agent runtime stop failed', e);
    }
  }

  /// Best-effort mirror of the live ACP session id on the host, so a second
  /// device can attach before the catalog push lands.
  Future<void> writeSessionId(Host host, String chatId, String sessionId) async {
    if (sessionId.isEmpty) return;
    try {
      final home = await _ssh.remoteHomeDirectory(host);
      final dir = dirForChat(home, chatId);
      final path = '$dir/acp_session_id';
      await _ssh.exec(
        host,
        'mkdir -p ${SshService.shellQuote(dir)} && '
        'printf %s ${SshService.shellQuote(sessionId)} > ${SshService.shellQuote(path)}',
      );
    } catch (e) {
      SafeLog.d('agent runtime write session id failed', e);
    }
  }

  Future<String?> readSessionId(Host host, String chatId) async {
    try {
      final home = await _ssh.remoteHomeDirectory(host);
      final path = SshService.shellQuote('${dirForChat(home, chatId)}/acp_session_id');
      final raw = await _ssh.exec(host, 'cat $path 2>/dev/null || true');
      final id = raw.trim();
      return id.isEmpty ? null : id;
    } catch (e) {
      SafeLog.d('agent runtime read session id failed', e);
      return null;
    }
  }

  /// Idempotent bootstrap run on the host. Pure, so its quoting is testable.
  ///
  /// Prints `RUNNING`, `STARTED`, or `RESTARTED`, then the journal's byte size.
  static String ensureScript({
    required String dir,
    required String tmuxSession,
    required String cwd,
    required String binary,
    AgentProvider provider = AgentProvider.cursor,
    String? apiKey,
    bool fullAccess = true,
  }) {
    final q = SshService.shellQuote;
    final scriptB64 = base64Encode(
      utf8.encode(
        runScript(
          dir: dir,
          cwd: cwd,
          binary: binary,
          provider: provider,
          fullAccess: fullAccess,
        ),
      ),
    );
    final want = fullAccess ? '1' : '0';
    final marker = '$dir/full_access';
    final envBody = _envFileContents(provider: provider, apiKey: apiKey);

    return <String>[
      'set -e',
      'mkdir -p ${q(dir)}',
      'chmod 700 ${q(dir)}',
      'printf %s ${q(scriptB64)} | base64 -d > ${q('$dir/run.sh')}',
      '[ -p ${q('$dir/in')} ] || mkfifo ${q('$dir/in')}',
      'touch ${q('$dir/out.jsonl')}',
      'WANT=$want',
      'HAVE=\$(cat ${q(marker)} 2>/dev/null || true)',
      'if tmux has-session -t ${q(tmuxSession)} 2>/dev/null; then',
      '  if [ "\$HAVE" = "\$WANT" ]; then',
      '    printf RUNNING',
      '  else',
      // Full access ↔ Ask changed: recycle the process, keep journal + session id.
      '    tmux kill-session -t ${q(tmuxSession)} 2>/dev/null || true',
      '    printf %s "\$WANT" > ${q(marker)}',
      if (envBody != null) ...[
        '    umask 077',
        '    printf %s ${q(envBody)} > ${q('$dir/env')}',
      ],
      '    tmux new-session -d -s ${q(tmuxSession)} -c ${q(cwd)} '
          '${q('sh $dir/run.sh')} || { rm -f ${q('$dir/env')}; exit 1; }',
      '    printf RESTARTED',
      '  fi',
      'else',
      '  : > ${q('$dir/out.jsonl')}',
      '  printf %s "\$WANT" > ${q(marker)}',
      if (envBody != null) ...[
        '  umask 077',
        '  printf %s ${q(envBody)} > ${q('$dir/env')}',
      ],
      '  tmux new-session -d -s ${q(tmuxSession)} -c ${q(cwd)} '
          '${q('sh $dir/run.sh')} || { rm -f ${q('$dir/env')}; exit 1; }',
      '  printf STARTED',
      'fi',
      'printf " "',
      'wc -c < ${q('$dir/out.jsonl')} | tr -d ${q(' ')}',
    ].join('\n');
  }

  /// Env exports written to a 0600 file and sourced by [runScript].
  static String? _envFileContents({
    required AgentProvider provider,
    String? apiKey,
  }) {
    final lines = <String>[];
    if (apiKey != null && apiKey.isNotEmpty) {
      switch (provider) {
        case AgentProvider.cursor:
          lines.add('CURSOR_API_KEY=${SshService.shellQuote(apiKey)}');
          lines.add('export CURSOR_API_KEY');
        case AgentProvider.claude:
          lines.add('ANTHROPIC_API_KEY=${SshService.shellQuote(apiKey)}');
          lines.add('export ANTHROPIC_API_KEY');
      }
    }
    if (lines.isEmpty) return null;
    return '${lines.join('\n')}\n';
  }

  /// The supervised process wrapper that tmux launches.
  static String runScript({
    required String dir,
    required String cwd,
    required String binary,
    AgentProvider provider = AgentProvider.cursor,
    bool fullAccess = true,
  }) {
    final q = SshService.shellQuote;
    final agentArgs = switch (provider) {
      // Shift+Tab "full access" in the interactive Cursor CLI.
      AgentProvider.cursor =>
        fullAccess ? '--force --approve-mcps --trust acp' : 'acp',
      // Zed's claude-code-acp speaks ACP on stdio with no subcommand.
      AgentProvider.claude => '',
    };
    final skipPerms = provider == AgentProvider.claude && fullAccess
        ? 'export CLAUDE_ACP_SKIP_PERMISSIONS=true\n'
        : '';
    final execLine = agentArgs.isEmpty ? q(binary) : '${q(binary)} $agentArgs';
    return '''#!/bin/sh
DIR=${q(dir)}

# Secrets arrive in a 0600 file and are removed as soon as they are in the
# environment, so they never show up in `ps` and never persist on disk.
if [ -f "\$DIR/env" ]; then
  . "\$DIR/env"
  rm -f "\$DIR/env"
fi

$skipPerms
# claude-code-acp is a #!/usr/bin/env node script — nvm's node must be on PATH
# when tmux starts a non-login shell (otherwise: "env: node: No such file").
for d in "\$HOME"/.nvm/versions/node/*/bin; do
  [ -d "\$d" ] && PATH="\$d:\$PATH"
done
export PATH="\$HOME/.local/bin:\$HOME/.cursor/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH"
cd ${q(cwd)} || exit 1

# Park a writer on the stdin FIFO forever. Without it, every time the phone
# disconnects the agent would read EOF on stdin and exit.
sleep 2147483647 > "\$DIR/in" &
echo \$! > "\$DIR/holder.pid"

exec < "\$DIR/in"
exec >> "\$DIR/out.jsonl"
exec 2>> "\$DIR/err.log"

# stdout is a file, so libc would normally switch to 4KB block buffering and
# stall streaming. Force line buffering when stdbuf is available.
if command -v stdbuf >/dev/null 2>&1; then
  exec stdbuf -oL -eL $execLine
fi
exec $execLine
''';
  }
}
