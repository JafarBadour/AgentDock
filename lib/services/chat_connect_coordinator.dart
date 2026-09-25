import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../data/models/agent_mode.dart';
import '../data/models/agent_provider.dart';
import '../data/models/chat.dart';
import '../data/models/host.dart';
import '../data/models/repo.dart';
import '../data/local/app_database.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import 'adsm_client.dart';
import 'agent_session.dart';
import 'claude_remote_auth.dart';
import 'codex_remote_auth.dart';
import 'ssh_service.dart';

/// What a chat's bring-up is doing right now, for whatever screen is looking.
enum ConnectPhase {
  idle,

  /// SSH/ADSM bring-up in flight. [ConnectProgress.attempt] says which try.
  connecting,

  /// Blocked on an interactive sign-in. Only a visible screen can clear this,
  /// so the connect parks here instead of burning its retries.
  needsLogin,

  /// Terminal for this run — the banner explains why and offers Retry.
  failed,

  connected,
}

/// Immutable snapshot of a chat's bring-up, watched by the chat screen.
class ConnectProgress {
  const ConnectProgress({
    this.phase = ConnectPhase.idle,
    this.status,
    this.error,
    this.attempt = 0,
    this.showSdkInstallGuide = false,
    this.resumedInPlace = false,
    this.loginProvider,
  });

  final ConnectPhase phase;

  /// Fine-grained label ("Starting ADSM…") for the header spinner.
  final String? status;
  final String? error;

  /// 1-based attempt number; 0 while idle.
  final int attempt;
  final bool showSdkInstallGuide;
  final bool resumedInPlace;

  /// Set with [ConnectPhase.needsLogin] so the screen knows which sheet.
  final AgentProvider? loginProvider;

  bool get connecting => phase == ConnectPhase.connecting;

  /// True once a retry is under way, so the UI can say "try 2 of 3" rather
  /// than silently sitting on the same spinner for two minutes.
  bool get retrying => connecting && attempt > 1;

  ConnectProgress copyWith({
    ConnectPhase? phase,
    String? status,
    String? error,
    int? attempt,
    bool? showSdkInstallGuide,
    bool? resumedInPlace,
    AgentProvider? loginProvider,
    bool clearStatus = false,
    bool clearError = false,
    bool clearLoginProvider = false,
  }) {
    return ConnectProgress(
      phase: phase ?? this.phase,
      status: clearStatus ? null : (status ?? this.status),
      error: clearError ? null : (error ?? this.error),
      attempt: attempt ?? this.attempt,
      showSdkInstallGuide: showSdkInstallGuide ?? this.showSdkInstallGuide,
      resumedInPlace: resumedInPlace ?? this.resumedInPlace,
      loginProvider: clearLoginProvider
          ? null
          : (loginProvider ?? this.loginProvider),
    );
  }
}

/// The interactive bits a headless connect cannot do itself.
///
/// The chat screen registers one while it is mounted; the coordinator falls
/// back to parking on [ConnectPhase.needsLogin] when nothing is attached.
abstract class ConnectUiDelegate {
  /// Show the provider's login sheet. `true` when the user signed in.
  Future<bool> requestLogin(AgentProvider provider, Host host);
}

/// Runs a chat's SSH/ADSM bring-up outside the widget tree.
///
/// This used to live on `_ChatScreenState`, guarded at every await by
/// `mounted && epoch == _connectEpoch`. Leaving the chat unmounted the State,
/// so the next guard abandoned the handshake — and past the attach point it
/// actively closed a session that had just connected. Switching agents or
/// backgrounding the app therefore threw away work that had already
/// succeeded.
///
/// The coordinator lives in the provider container, so only an explicit
/// [cancel] (or a newer [ensure] for the same chat) supersedes a connect.
/// Navigation, another agent, and app switches no longer touch it.
class ChatConnectCoordinator extends StateNotifier<Map<String, ConnectProgress>> {
  ChatConnectCoordinator(this._ref) : super({});

  final Ref _ref;

  /// Bumped per chat by [cancel] / a fresh [ensure]. A run whose epoch is
  /// stale tears itself down; anything else is allowed to finish.
  final Map<String, int> _epochs = {};
  final Map<String, Future<void>> _inFlight = {};
  final Map<String, ConnectUiDelegate> _delegates = {};
  final Map<String, Completer<bool>> _pendingLogins = {};

  /// Total tries per user-initiated connect, including the first.
  static const int maxAttempts = 3;

  /// Grows between tries so a host that is briefly unreachable (VPN handover,
  /// laptop waking) gets a slower second look rather than three in a row.
  static const List<Duration> _backoff = [
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  ConnectProgress progressFor(String chatId) =>
      state[chatId] ?? const ConnectProgress();

  bool isConnecting(String chatId) => progressFor(chatId).connecting;

  /// Register the screen that can show login sheets for [chatId].
  void attachUi(String chatId, ConnectUiDelegate delegate) {
    _delegates[chatId] = delegate;
  }

  /// Drop the screen's delegate without disturbing an in-flight connect.
  void detachUi(String chatId, ConnectUiDelegate delegate) {
    if (_delegates[chatId] == delegate) _delegates.remove(chatId);
  }

  /// Answer a parked [ConnectPhase.needsLogin]. Called by the screen once its
  /// sheet closes.
  void provideLoginResult(String chatId, bool signedIn) {
    final pending = _pendingLogins.remove(chatId);
    if (pending != null && !pending.isCompleted) pending.complete(signedIn);
  }

  void _emit(String chatId, ConnectProgress progress) {
    state = {...state, chatId: progress};
  }

  void _patch(String chatId, ConnectProgress Function(ConnectProgress) f) {
    _emit(chatId, f(progressFor(chatId)));
  }

  /// Abandon the current connect for [chatId] — user pressed Cancel, or a
  /// force-reconnect is about to start a clean one.
  void cancel(String chatId, {required Host? host}) {
    _epochs[chatId] = (_epochs[chatId] ?? 0) + 1;
    _inFlight.remove(chatId);
    final pending = _pendingLogins.remove(chatId);
    if (pending != null && !pending.isCompleted) pending.complete(false);
    if (host != null) {
      final ssh = _ref.read(sshServiceProvider);
      ssh.abandonAdsmEnsure(host.id);
      ssh.clearAdsmReady(host.id);
    }
    _emit(chatId, const ConnectProgress());
  }

  bool _current(String chatId, int epoch) => _epochs[chatId] == epoch;

  /// Bring up a session for [chat], retrying transport failures up to
  /// [maxAttempts] times. Re-entrant: a second call while one is in flight
  /// joins it instead of racing a duplicate handshake.
  Future<void> ensure({
    required Chat chat,
    required Repo repo,
    required Host host,
    required AgentSessionMode mode,
    required PermissionPolicy permission,
    bool forceFreshSession = false,
  }) {
    final inflight = _inFlight[chat.id];
    if (inflight != null) return inflight;

    final epoch = (_epochs[chat.id] ?? 0) + 1;
    _epochs[chat.id] = epoch;

    late final Future<void> run;
    run = _run(
      chat: chat,
      repo: repo,
      host: host,
      mode: mode,
      permission: permission,
      forceFreshSession: forceFreshSession,
      epoch: epoch,
    ).whenComplete(() {
      if (identical(_inFlight[chat.id], run)) _inFlight.remove(chat.id);
    });
    _inFlight[chat.id] = run;
    return run;
  }

  Future<void> _run({
    required Chat chat,
    required Repo repo,
    required Host host,
    required AgentSessionMode mode,
    required PermissionPolicy permission,
    required bool forceFreshSession,
    required int epoch,
  }) async {
    // Hold the foreground service for the duration. Without it, pausing the
    // app runs `_suspendBridgesUnlessKeepAlive` in main.dart, which suspends
    // every bridge and kills the handshake the moment the user checks another
    // app.
    final keepAlive = _ref.read(backgroundKeepAliveProvider);
    if (!keepAlive.canSurviveBackground) {
      try {
        await keepAlive.hold(
          sessionCount: _ref.read(activeAcpSessionsProvider).length + 1,
          force: true,
        );
      } catch (e) {
        SafeLog.d('keep-alive hold for connect failed', e);
      }
    }

    var forceFresh = forceFreshSession;
    Object? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (!_current(chat.id, epoch)) return;
      _patch(
        chat.id,
        (p) => p.copyWith(
          phase: ConnectPhase.connecting,
          attempt: attempt,
          status: 'Reaching ${host.displayLabel}…',
          clearError: true,
          showSdkInstallGuide: false,
          clearLoginProvider: true,
        ),
      );

      try {
        final outcome = await _attempt(
          chat: chat,
          repo: repo,
          host: host,
          mode: mode,
          permission: permission,
          forceFreshSession: forceFresh,
          epoch: epoch,
        );
        // A fresh session is minted once, never re-minted by a retry.
        forceFresh = false;
        if (!_current(chat.id, epoch)) return;
        switch (outcome) {
          case _AttemptOutcome.connected:
          case _AttemptOutcome.superseded:
          case _AttemptOutcome.needsLogin:
            return;
        }
      } on MissingToolException catch (e) {
        // The remote is reachable and the tool is genuinely absent; two more
        // installs will fail the same way.
        if (!_current(chat.id, epoch)) return;
        await _failTerminal(chat, host, _missingToolMessage(e, chat, host),
            showGuide: true);
        return;
      } catch (e) {
        lastError = e;
        if (!_current(chat.id, epoch)) return;
        SafeLog.d('ACP connect attempt $attempt/$maxAttempts failed', e);
        if (!_isRetryable(e) || attempt == maxAttempts) break;
        final wait = _backoff[(attempt - 1).clamp(0, _backoff.length - 1)];
        _patch(
          chat.id,
          (p) => p.copyWith(
            status: 'Retrying in ${wait.inSeconds}s '
                '(try ${attempt + 1} of $maxAttempts)…',
          ),
        );
        await Future<void>.delayed(wait);
      }
    }

    if (!_current(chat.id, epoch)) return;
    final e = lastError;
    if (e == null) return;
    final lower = e.toString().toLowerCase();
    final looksLikeMissingSdk =
        lower.contains('cursor') ||
        lower.contains('claude') ||
        lower.contains('claude-code-acp') ||
        lower.contains('codex') ||
        lower.contains('agent') ||
        lower.contains('not found') ||
        lower.contains('no such file') ||
        lower.contains('install');
    await _failTerminal(
      chat,
      host,
      looksLikeMissingSdk
          ? 'Could not start ${chat.provider.label} — install may have '
                'failed on the remote.\n$e'
          : compactConnectError(e, provider: chat.provider),
      showGuide: looksLikeMissingSdk,
    );
  }

  /// Transport-ish failures are worth another go; anything that encodes a
  /// decision on the host (missing binary, refused auth) is not.
  bool _isRetryable(Object e) {
    if (e is MissingToolException) return false;
    if (e is TimeoutException || e is SocketException) return true;
    final lower = e.toString().toLowerCase();
    if (lower.contains('sign-in required') ||
        lower.contains('sign in required') ||
        lower.contains('permission denied') ||
        lower.contains('authentication fail')) {
      return false;
    }
    return lower.contains('timed out') ||
        lower.contains('socketexception') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('network is unreachable') ||
        lower.contains('no route to host') ||
        lower.contains('broken pipe') ||
        lower.contains('adsm');
  }

  Future<void> _failTerminal(
    Chat chat,
    Host host,
    String message, {
    required bool showGuide,
  }) async {
    _patch(
      chat.id,
      (p) => p.copyWith(
        phase: ConnectPhase.failed,
        error: message,
        showSdkInstallGuide: showGuide,
        clearStatus: true,
      ),
    );
    final updated = chat.copyWith(
      status: ChatStatus.error,
      updatedAt: DateTime.now(),
    );
    try {
      await _ref.read(appDatabaseProvider).upsertChat(updated);
      _ref.read(agentDockServiceProvider).schedulePushChat(updated.id);
    } catch (e) {
      SafeLog.d('persist connect failure failed', e);
    }
  }

  String _missingToolMessage(MissingToolException e, Chat chat, Host host) {
    final providerLabel = chat.provider == AgentProvider.cursor
        ? 'Cursor CLI'
        : chat.provider.label;
    final isAdsm = e.tool.toUpperCase().contains('ADSM');
    final mismatch = e.installHint.toLowerCase().contains('adsm mismatch');
    if (isAdsm) {
      return mismatch
          ? 'ADSM mismatch — cannot run until the host matches this app '
                '(needs v$kRequiredAdsmVersion).\n'
                'Agent Dock tried to update automatically. Leave this chat '
                'and open it again to retry, or update ADSM on the remote.\n\n'
                '${e.installHint}'
          : 'Could not install ADSM on ${host.displayLabel}.\n'
                'Agent Dock tried automatically — run the setup below on the '
                'remote, then Connect again.\n\n'
                '${e.tool} still missing.';
    }
    return 'Could not install $providerLabel on ${host.displayLabel}.\n'
        'Agent Dock tried automatically — run the setup below on the '
        'remote (or fix network/sudo), then Connect again.\n\n'
        '${e.tool} still missing.';
  }

  Future<_AttemptOutcome> _attempt({
    required Chat chat,
    required Repo repo,
    required Host host,
    required AgentSessionMode mode,
    required PermissionPolicy permission,
    required bool forceFreshSession,
    required int epoch,
  }) async {
    final ssh = _ref.read(sshServiceProvider);
    final db = _ref.read(appDatabaseProvider);
    final sessions = _ref.read(activeAcpSessionsProvider.notifier);
    var meta = chat;

    void status(String message) {
      if (!_current(chat.id, epoch)) return;
      _patch(chat.id, (p) => p.copyWith(status: message));
    }

    await ssh.connect(host).timeout(
      const Duration(seconds: 20),
      onTimeout: () =>
          throw TimeoutException('Timed out reaching ${host.displayLabel}'),
    );
    if (!_current(chat.id, epoch)) return _AttemptOutcome.superseded;

    // Pull the live session id the desktop wrote before attaching — without
    // it the agent starts over and only sees messages sent on this device.
    try {
      status('Syncing chat…');
      final changed = await _ref
          .read(agentDockServiceProvider)
          .syncChatRecord(host: host, chatId: chat.id)
          .timeout(const Duration(seconds: 12));
      if (!_current(chat.id, epoch)) return _AttemptOutcome.superseded;
      if (changed) {
        final refreshed = await db.getChat(chat.id);
        if (!_current(chat.id, epoch)) return _AttemptOutcome.superseded;
        if (refreshed != null) meta = refreshed;
      }
    } catch (e) {
      SafeLog.d('sync chat record before connect failed', e);
    }

    final loginOk = await _ensureSignedIn(
      chat: meta,
      host: host,
      epoch: epoch,
      status: status,
    );
    if (loginOk != null) return loginOk;

    if (!_current(chat.id, epoch)) return _AttemptOutcome.superseded;
    status('Starting ${meta.provider.label}…');
    final factory = buildSessionFactory(
      ssh: ssh,
      secureStore: _ref.read(secureStoreProvider),
      db: db,
      sessions: sessions,
      bridgePool: _ref.read(adsmBridgePoolProvider),
      chatId: meta.id,
      cwd: repo.remotePath,
      host: host,
      provider: meta.provider,
      fallbackMode: mode,
      fallbackPermission: permission,
      forceFreshSession: forceFreshSession,
      onProgress: status,
    );

    final session = await factory();
    // Past this point the handshake has succeeded. Only a real cancel may
    // discard it — an unmounted screen must not.
    if (!_current(chat.id, epoch)) {
      try {
        await session.close();
      } catch (_) {}
      return _AttemptOutcome.superseded;
    }

    final runtime = await sessions.attach(
      chatId: meta.id,
      session: session,
      sessionFactory: factory,
    );
    if (!_current(chat.id, epoch)) {
      await sessions.close(meta.id);
      return _AttemptOutcome.superseded;
    }
    runtime.chatMeta = meta;

    final sessionId = session.sessionId;
    if (sessionId != null) {
      unawaited(
        _ref
            .read(agentRuntimeHostProvider)
            .writeSessionId(host, meta.id, sessionId),
      );
    }

    final updated = meta.copyWith(
      status: ChatStatus.running,
      acpSessionId: session.sessionId,
      updatedAt: DateTime.now(),
    );
    runtime.chatMeta = updated;
    await db.upsertChat(updated);
    _ref.read(agentDockServiceProvider).schedulePushChat(updated.id);

    _patch(
      chat.id,
      (p) => p.copyWith(
        phase: ConnectPhase.connected,
        clearStatus: true,
        clearError: true,
        showSdkInstallGuide: false,
        resumedInPlace: session.resumedInPlace,
      ),
    );
    return _AttemptOutcome.connected;
  }

  /// Returns non-null when the attempt should stop here (parked on login or
  /// superseded); null when the chat is signed in and bring-up may continue.
  Future<_AttemptOutcome?> _ensureSignedIn({
    required Chat chat,
    required Host host,
    required int epoch,
    required void Function(String) status,
  }) async {
    final provider = chat.provider;
    if (provider != AgentProvider.claude && provider != AgentProvider.codex) {
      return null;
    }
    final secure = _ref.read(secureStoreProvider);
    final apiKey = provider == AgentProvider.claude
        ? await secure.readAnthropicApiKey()
        : await secure.readOpenAiApiKey();
    if (!_current(chat.id, epoch)) return _AttemptOutcome.superseded;
    if (apiKey != null && apiKey.isNotEmpty) return null;

    status('Checking ${provider.label} login…');
    final ssh = _ref.read(sshServiceProvider);
    final loggedIn = provider == AgentProvider.claude
        ? await ClaudeRemoteAuth(ssh)
              .isLoggedIn(host)
              .timeout(const Duration(seconds: 25), onTimeout: () => false)
        : await CodexRemoteAuth(ssh)
              .isLoggedIn(host)
              .timeout(const Duration(seconds: 25), onTimeout: () => false);
    if (!_current(chat.id, epoch)) return _AttemptOutcome.superseded;
    if (loggedIn) return null;

    // Sign-in needs a sheet. With no screen attached, park rather than spend
    // the remaining retries on a prompt nobody can answer.
    final delegate = _delegates[chat.id];
    if (delegate == null) {
      _patch(
        chat.id,
        (p) => p.copyWith(
          phase: ConnectPhase.needsLogin,
          loginProvider: provider,
          status: 'Sign-in required…',
          error: '${provider.label} sign-in required. '
              'Open this chat to continue.',
        ),
      );
      return _AttemptOutcome.needsLogin;
    }

    status('Sign in required…');
    final completer = Completer<bool>();
    _pendingLogins[chat.id] = completer;
    bool signedIn;
    try {
      signedIn = await delegate.requestLogin(provider, host);
      provideLoginResult(chat.id, signedIn);
    } catch (e) {
      SafeLog.d('login sheet failed', e);
      provideLoginResult(chat.id, false);
      signedIn = false;
    }
    if (!_current(chat.id, epoch)) return _AttemptOutcome.superseded;
    if (!signedIn) {
      _patch(
        chat.id,
        (p) => p.copyWith(
          phase: ConnectPhase.failed,
          clearStatus: true,
          error: '${provider.label} sign-in required. '
              'Open Settings to continue.',
        ),
      );
      return _AttemptOutcome.needsLogin;
    }
    return null;
  }
}

enum _AttemptOutcome { connected, superseded, needsLogin }

/// A closure that can open a transport for this chat at any later time.
///
/// Captures services rather than holding `ref` across awaits, because the
/// runtime keeps reconnecting in the background long after any one screen is
/// gone.
Future<AgentSession> Function() buildSessionFactory({
  required SshService ssh,
  required SecureStore secureStore,
  required AppDatabase db,
  required ActiveAcpSessions sessions,
  required AdsmBridgePool bridgePool,
  required String chatId,
  required String cwd,
  required Host host,
  required AgentProvider provider,
  required AgentSessionMode fallbackMode,
  required PermissionPolicy fallbackPermission,
  required bool forceFreshSession,
  void Function(String)? onProgress,
}) {
  // Consume once — background reconnects must resume the new session id.
  var forceNewOnce = forceFreshSession;

  return () async {
    final forceNew = forceNewOnce;
    forceNewOnce = false;
    final live = sessions.get(chatId);
    final mode = live?.preferredMode ?? fallbackMode;
    final permission = live?.preferredPermissionPolicy ?? fallbackPermission;

    void status(String message) => onProgress?.call(message);

    status('Checking ${provider.label}…');

    final adsmReady = ssh.isAdsmReady(host.id);
    final cachedBinary = switch (provider) {
      AgentProvider.cursor => ssh.cachedCursorCli(host.id),
      AgentProvider.claude => ssh.cachedClaudeAcp(host.id),
      AgentProvider.codex => ssh.cachedCodexAcp(host.id),
    };

    // Skip the tmux install probe when the agent binary is already known —
    // cold reconnects used to hang here forever on ProxyJump SSH.
    if (!adsmReady && cachedBinary == null) {
      await ssh.ensureTmux(host, onProgress: status).timeout(
        const Duration(seconds: 45),
        onTimeout: () =>
            throw TimeoutException('Timed out checking tmux on the remote.'),
      );
    }

    final String binary;
    if (cachedBinary != null) {
      binary = cachedBinary;
      // Do not say "ready" here — ADSM attach can still hang, and that label
      // next to the header spinner made chats look connected while the
      // composer stayed locked.
      status(switch (provider) {
        AgentProvider.cursor => 'Cursor found…',
        AgentProvider.claude => 'Claude ACP found…',
        AgentProvider.codex => 'Codex ACP found…',
      });
    } else {
      binary = switch (provider) {
        AgentProvider.cursor =>
          await ssh.ensureCursorCli(host, onProgress: status).timeout(
            const Duration(minutes: 8),
            onTimeout: () => throw TimeoutException(
              'Timed out installing/finding Cursor CLI on the remote.',
            ),
          ),
        AgentProvider.claude =>
          await ssh.ensureClaudeAcpBinary(host, onProgress: status).timeout(
            const Duration(seconds: 90),
            onTimeout: () => throw TimeoutException(
              'Timed out finding Claude ACP on the remote. '
              'Open Hosts → terminal and check `claude-code-acp`.',
            ),
          ),
        AgentProvider.codex =>
          await ssh.ensureCodexAcpBinary(host, onProgress: status).timeout(
            const Duration(minutes: 8),
            onTimeout: () => throw TimeoutException(
              'Timed out installing/finding Codex ACP on the remote. '
              'Open Hosts → terminal and check `codex-acp`.',
            ),
          ),
      };
    }

    status(adsmReady ? 'Connecting to ADSM…' : 'Starting ADSM…');
    try {
      await ssh
          .ensureAdsm(host, onProgress: status, allowUpgrade: !adsmReady)
          .timeout(
            adsmReady
                ? const Duration(seconds: 60)
                : const Duration(seconds: 90),
            onTimeout: () => throw TimeoutException(
              adsmReady
                  ? 'Timed out connecting to ADSM on ${host.displayLabel}. '
                        'Check VPN/SSH, tap Cancel, then reconnect.'
                  : 'Timed out installing/starting ADSM on ${host.displayLabel}. '
                        'Check VPN/SSH, tap Cancel, then reconnect.',
            ),
          );
    } on TimeoutException {
      ssh.clearAdsmReady(host.id);
      ssh.abandonAdsmEnsure(host.id);
      rethrow;
    }

    final mcps = await db.listEnabledMcpsForHost(host.id);
    final latest = await db.getChat(chatId);

    status('Starting agent…');

    return AdsmSession.start(
      ssh: ssh,
      secureStore: secureStore,
      bridgePool: bridgePool,
      host: host,
      cwd: cwd,
      binary: binary,
      chatId: chatId,
      provider: provider,
      mcpServers: mcps.map((m) => m.toAcpConfig()).toList(),
      initialMode: mode,
      permissionPolicy: permission,
      resumeSessionId: forceNew ? null : latest?.acpSessionId,
      forceNewSession: forceNew,
      preferredModelId: latest?.modelId,
    ).timeout(
      const Duration(seconds: 90),
      onTimeout: () => throw TimeoutException('${provider.label} connect timed out'),
    );
  };
}

/// One-line connect failure for the compact banner (full text on tap).
String compactConnectError(
  Object error, {
  required AgentProvider provider,
}) {
  var msg = error.toString().trim();
  const prefixes = ['TimeoutException: ', 'Exception: ', 'StateError: '];
  for (final p in prefixes) {
    if (msg.startsWith(p)) msg = msg.substring(p.length).trim();
  }
  // Unwrap "Could not start … ACP: …" if we re-enter.
  final acp = RegExp(
    r'^Could not start (?:Claude|Cursor|Codex)(?: ACP)?:\s*',
    caseSensitive: false,
  ).firstMatch(msg);
  if (acp != null) msg = msg.substring(acp.end).trim();
  for (final p in prefixes) {
    if (msg.startsWith(p)) msg = msg.substring(p.length).trim();
  }

  final lower = msg.toLowerCase();
  if (lower.contains('can\'t reach') ||
      lower.contains('timed out reaching') ||
      lower.contains('timed out opening ssh') ||
      lower.contains('socketexception') ||
      lower.contains('connection refused') ||
      lower.contains('network is unreachable') ||
      lower.contains('no route to host')) {
    return 'Can\'t reach host — check VPN/network';
  }
  if (lower.contains('timed out connecting to adsm')) {
    final host = RegExp(
      r'on ([^\s.]+)',
      caseSensitive: false,
    ).firstMatch(msg)?.group(1);
    return host != null ? 'ADSM timed out on $host' : 'ADSM connect timed out';
  }
  if (lower.contains('timed out installing/starting adsm')) {
    return 'ADSM install timed out';
  }
  if (lower.contains('timed out opening ssh')) {
    return 'SSH timed out';
  }
  if (lower.contains('connect timed out')) {
    return '${provider.label} connect timed out';
  }
  if (msg.length > 72) return '${msg.substring(0, 69)}…';
  return msg;
}
