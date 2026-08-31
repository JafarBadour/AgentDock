import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../data/models/agent_mode.dart';
import '../data/models/agent_model.dart';
import '../data/models/host.dart';
import '../data/models/tool_call_state.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import 'agent_runtime_host.dart';
import 'ssh_service.dart';

/// What the remote agent told us it can do, from the `initialize` response.
class AcpAgentCapabilities {
  const AcpAgentCapabilities({this.loadSession = false});

  /// Whether `session/load` is supported, i.e. whether a previous conversation
  /// can be resumed by id instead of started from scratch.
  final bool loadSession;

  factory AcpAgentCapabilities.fromInitializeResult(Map<String, dynamic> result) {
    final caps = result['agentCapabilities'] ?? result['agent_capabilities'];
    if (caps is Map) {
      final value = caps['loadSession'] ?? caps['load_session'];
      if (value is bool) return AcpAgentCapabilities(loadSession: value);
      if (value != null) {
        return AcpAgentCapabilities(loadSession: value.toString() == 'true');
      }
    }
    return const AcpAgentCapabilities();
  }
}

/// How the agent process is reached.
enum AcpTransport {
  /// `cursor-agent acp` bound directly to an SSH exec channel. The process dies
  /// with the connection.
  direct,

  /// Detached tmux-supervised process with a FIFO stdin and a journal stdout.
  /// Survives SSH drops, and output produced while away is replayed.
  durable,
}

/// Wait for [future], giving up only once [idle] passes with no sign of life.
///
/// A wall-clock timeout is the wrong shape for an agent turn: the agent may
/// stream tool calls and text for many minutes, and cancelling a healthy,
/// actively-working turn is indistinguishable to the user from the agent being
/// stuck. [lastActivity] is re-read on every wakeup, so any output pushes the
/// deadline out.
Future<T> awaitWithIdleTimeout<T>({
  required Future<T> future,
  required Duration idle,
  required DateTime Function() lastActivity,
  required Object Function() onTimeout,
}) async {
  while (true) {
    final remaining = idle - DateTime.now().difference(lastActivity());
    if (remaining <= Duration.zero) throw onTimeout();
    try {
      return await future.timeout(remaining);
    } on TimeoutException {
      // Output may have landed while we waited, moving the deadline; recheck
      // rather than failing a live turn.
      continue;
    }
  }
}

/// Minimal ACP (Agent Client Protocol) JSON-RPC client.
class AcpSession {
  AcpSession._({
    required this.host,
    required this.cwd,
    required this.transport,
    required SSHSession session,
    this.remote,
    this.onJournalAdvance,
  }) : _session = session;

  final Host host;
  final String cwd;
  final AcpTransport transport;

  /// Present only for [AcpTransport.durable].
  final RemoteAgentSession? remote;

  /// Reports total journal bytes consumed so a reconnect can resume.
  final void Function(int consumedBytes)? onJournalAdvance;

  final SSHSession _session;

  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _updates = StreamController<AcpUpdate>.broadcast();
  final _buffer = StringBuffer();

  /// Request ids are prefixed per connection. When resuming a journal we can
  /// still encounter responses addressed to a previous connection's requests;
  /// the prefix stops those from completing an unrelated new request.
  late final String _epoch =
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  int _nextId = 1;

  int _consumed = 0;
  bool _replaying = false;

  /// Last time the agent sent anything, used as the liveness signal for a
  /// running turn.
  DateTime _lastActivityAt = DateTime.now();

  /// Pending `session/prompt` request id, so a turn-complete update can finish
  /// the call even when the JSON-RPC result never arrives.
  String? _promptRequestKey;

  /// True once this turn has produced any streamed output. Soft-settle only
  /// applies after that — otherwise a slow first token would look like "done".
  bool _promptSawOutput = false;

  String? sessionId;
  bool _started = false;
  StreamSubscription<Uint8List>? _stdoutSub;

  AgentSessionMode mode = AgentSessionMode.agent;
  PermissionPolicy permissionPolicy = PermissionPolicy.ask;
  List<String> availableModeIds = const ['ask', 'agent', 'plan'];
  AcpAgentCapabilities capabilities = const AcpAgentCapabilities();

  /// Models the agent advertised for this session, in its own order.
  List<AgentModel> availableModels = const [];
  String? currentModelId;

  /// True when we attached to an already-running agent that kept its context.
  bool resumedInPlace = false;

  bool _clientInitialized = false;

  bool get isPromptActive => _promptRequestKey != null;

  Stream<AcpUpdate> get updates => _updates.stream;

  int get consumedBytes => _consumed;

  static Future<AcpSession> start({
    required SshService ssh,
    required SecureStore secureStore,
    required Host host,
    required String cwd,
    required String binary,
    required String chatId,
    AgentRuntimeHost? runtimeHost,
    List<Map<String, dynamic>> mcpServers = const [],
    AgentSessionMode initialMode = AgentSessionMode.agent,
    PermissionPolicy permissionPolicy = PermissionPolicy.ask,
    String? resumeSessionId,
    String? preferredModelId,
    int journalOffset = 0,
    bool durable = true,
    void Function(int consumedBytes)? onJournalAdvance,
  }) async {
    final cursorKey = await secureStore.readCursorApiKey();

    if (durable && runtimeHost != null) {
      try {
        return await _startDurable(
          ssh: ssh,
          runtimeHost: runtimeHost,
          host: host,
          cwd: cwd,
          binary: binary,
          chatId: chatId,
          cursorKey: cursorKey,
          mcpServers: mcpServers,
          initialMode: initialMode,
          permissionPolicy: permissionPolicy,
          resumeSessionId: resumeSessionId,
          preferredModelId: preferredModelId,
          journalOffset: journalOffset,
          onJournalAdvance: onJournalAdvance,
        );
      } catch (e) {
        SafeLog.d('durable ACP start failed; falling back to direct exec', e);
      }
    }

    return _startDirect(
      ssh: ssh,
      host: host,
      cwd: cwd,
      binary: binary,
      cursorKey: cursorKey,
      mcpServers: mcpServers,
      initialMode: initialMode,
      permissionPolicy: permissionPolicy,
      resumeSessionId: resumeSessionId,
      preferredModelId: preferredModelId,
    );
  }

  static Future<AcpSession> _startDurable({
    required SshService ssh,
    required AgentRuntimeHost runtimeHost,
    required Host host,
    required String cwd,
    required String binary,
    required String chatId,
    required String? cursorKey,
    required List<Map<String, dynamic>> mcpServers,
    required AgentSessionMode initialMode,
    required PermissionPolicy permissionPolicy,
    required String? resumeSessionId,
    required String? preferredModelId,
    required int journalOffset,
    void Function(int consumedBytes)? onJournalAdvance,
  }) async {
    var remote = await runtimeHost.ensure(
      host: host,
      chatId: chatId,
      cwd: cwd,
      binary: binary,
      cursorApiKey: cursorKey,
    );

    var effectiveSessionId = resumeSessionId;
    if (!remote.freshlyStarted && effectiveSessionId == null) {
      effectiveSessionId = await runtimeHost.readSessionId(host, chatId);
    }

    if (!remote.freshlyStarted && effectiveSessionId == null) {
      // The process is alive but we have no id to address its conversation
      // with, so nothing could be sent to it. Replace it with a usable one
      // rather than leaving the chat wedged.
      SafeLog.d('running agent has no known session id; restarting it');
      await runtimeHost.stop(host, chatId);
      remote = await runtimeHost.ensure(
        host: host,
        chatId: chatId,
        cwd: cwd,
        binary: binary,
        cursorApiKey: cursorKey,
      );
      effectiveSessionId = null;
    }

    int offset;
    if (remote.freshlyStarted) {
      offset = 0;
    } else if (journalOffset <= 0 && remote.journalSize > 0) {
      // Attaching to a live agent with no local offset (fresh install, cleared
      // data). Replaying the journal would re-import history the transcript
      // already holds under different ids, so start at the end instead.
      offset = remote.journalSize;
    } else {
      offset = journalOffset.clamp(0, remote.journalSize);
    }

    final client = await ssh.connect(host);
    final session = await client.execute(
      AgentRuntimeHost.bridgeCommand(remote, offset),
    );

    final acp = AcpSession._(
      host: host,
      cwd: cwd,
      transport: AcpTransport.durable,
      session: session,
      remote: remote,
      onJournalAdvance: onJournalAdvance,
    );
    acp._consumed = offset;
    acp.mode = initialMode;
    acp.permissionPolicy = permissionPolicy;
    acp._listen();

    if (remote.freshlyStarted) {
      await acp._initialize();
      await acp._newSession(mcpServers: mcpServers);
      await acp._applyInitialMode(initialMode);
      await acp._applyPreferredModel(preferredModelId);
    } else {
      // The process is already initialized and still holds the conversation in
      // memory; re-running the handshake would confuse it.
      acp.sessionId = effectiveSessionId;
      acp._started = true;
      acp.resumedInPlace = true;
      if (preferredModelId != null && preferredModelId.isNotEmpty) {
        acp.currentModelId = preferredModelId;
      }
    }
    return acp;
  }

  static Future<AcpSession> _startDirect({
    required SshService ssh,
    required Host host,
    required String cwd,
    required String binary,
    required String? cursorKey,
    required List<Map<String, dynamic>> mcpServers,
    required AgentSessionMode initialMode,
    required PermissionPolicy permissionPolicy,
    required String? resumeSessionId,
    required String? preferredModelId,
  }) async {
    final client = await ssh.connect(host);

    final envExports = StringBuffer();
    envExports.write(
      'export PATH="\$HOME/.local/bin:\$HOME/.cursor/bin:/usr/local/bin:/opt/homebrew/bin:\$PATH"; ',
    );
    if (cursorKey != null && cursorKey.isNotEmpty) {
      envExports.write('export CURSOR_API_KEY=${SshService.shellQuote(cursorKey)}; ');
    }

    final command =
        '${envExports}cd ${SshService.shellQuote(cwd)} && exec ${SshService.shellQuote(binary)} acp';

    final session = await client.execute(command);
    final acp = AcpSession._(
      host: host,
      cwd: cwd,
      transport: AcpTransport.direct,
      session: session,
    );
    acp.mode = initialMode;
    acp.permissionPolicy = permissionPolicy;
    acp._listen();

    await acp._initialize();
    await acp._openSession(
      mcpServers: mcpServers,
      resumeSessionId: resumeSessionId,
    );
    await acp._applyInitialMode(initialMode);
    await acp._applyPreferredModel(preferredModelId);
    return acp;
  }

  void _listen() {
    _stdoutSub = _session.stdout.listen(
      _onStdout,
      onError: (Object e, StackTrace st) {
        SafeLog.d('ACP stdout error', e, st);
        _updates.add(AcpUpdate.error(e.toString()));
      },
      onDone: () {
        _updates.add(const AcpUpdate.closed());
      },
    );
    _session.stderr.listen((data) {
      final text = utf8.decode(data, allowMalformed: true);
      if (text.trim().isNotEmpty) {
        SafeLog.d('ACP stderr: ${SafeLog.redact(text)}');
      }
    });
  }

  Future<void> _applyInitialMode(AgentSessionMode initialMode) async {
    if (initialMode == AgentSessionMode.agent) return;
    try {
      await setMode(initialMode);
    } catch (e) {
      SafeLog.d('setMode after session open failed', e);
    }
  }

  /// Re-apply a previously chosen model. Best effort: the agent's catalogue
  /// changes over time, so a model that is no longer offered must not block
  /// the session from opening.
  Future<void> _applyPreferredModel(String? modelId) async {
    if (modelId == null || modelId.isEmpty) return;
    if (modelId == currentModelId) return;
    if (availableModels.isNotEmpty &&
        !availableModels.any((m) => m.modelId == modelId)) {
      SafeLog.d('stored model $modelId is no longer offered; keeping default');
      return;
    }
    try {
      await setModel(modelId);
    } catch (e) {
      SafeLog.d('applying stored model failed', e);
    }
  }

  Future<void> _initialize() async {
    final result = await _request('initialize', {
      'protocolVersion': 1,
      'clientInfo': {'name': 'agent_dock', 'version': '0.1.0'},
      'capabilities': {
        'fs': {'readTextFile': false, 'writeTextFile': false},
      },
    });
    capabilities = AcpAgentCapabilities.fromInitializeResult(result);
    _clientInitialized = true;
    SafeLog.d('ACP agent loadSession=${capabilities.loadSession}');
    await _notify('initialized', {});
  }

  Future<void> _ensureInitialized() async {
    if (_clientInitialized) return;
    await _initialize();
  }

  /// Fill [availableModels] after resume-in-place, when we skipped session/new.
  ///
  /// Uses `session/load` with replay suppressed so the transcript is not
  /// duplicated — we only need the catalogue from the result.
  Future<void> ensureModelCatalog({
    required List<Map<String, dynamic>> mcpServers,
  }) async {
    if (availableModels.isNotEmpty) return;
    if (isPromptActive) return;
    final id = sessionId;
    if (id == null || id.isEmpty) return;

    try {
      await _ensureInitialized();
    } catch (e) {
      SafeLog.d('initialize before model catalog failed', e);
      return;
    }

    if (!capabilities.loadSession) {
      SafeLog.d('agent does not support session/load for model catalog');
      return;
    }

    _replaying = true;
    try {
      final result = await _request('session/load', {
        'sessionId': id,
        'cwd': cwd,
        'mcpServers': mcpServers,
      });
      _applyModels(result['models']);
      _applyModes(result['modes']);
    } catch (e) {
      SafeLog.d('session/load for model catalog failed', e);
    } finally {
      _replaying = false;
    }
  }

  /// Resume [resumeSessionId] when the agent supports it, otherwise start new.
  Future<void> _openSession({
    required List<Map<String, dynamic>> mcpServers,
    String? resumeSessionId,
  }) async {
    if (resumeSessionId != null && capabilities.loadSession) {
      try {
        await _loadSession(resumeSessionId, mcpServers);
        return;
      } catch (e) {
        SafeLog.d('session/load failed; starting a new session', e);
      }
    }
    await _newSession(mcpServers: mcpServers);
  }

  Future<void> _loadSession(
    String id,
    List<Map<String, dynamic>> mcpServers,
  ) async {
    // Loading makes the agent replay the whole conversation as updates. The
    // local transcript already has all of it, so drop them rather than
    // persisting a duplicate copy on every reconnect.
    _replaying = true;
    try {
      final result = await _request('session/load', {
        'sessionId': id,
        'cwd': cwd,
        'mcpServers': mcpServers,
      });
      sessionId = id;
      _started = true;
      _applyModes(result['modes']);
      _applyModels(result['models']);
    } finally {
      _replaying = false;
    }
  }

  Future<void> _newSession({required List<Map<String, dynamic>> mcpServers}) async {
    final result = await _request('session/new', {
      'cwd': cwd,
      'mcpServers': mcpServers,
    });
    sessionId = result['sessionId'] as String? ?? result['session_id'] as String?;
    _started = true;
    _applyModes(result['modes']);
    _applyModels(result['models']);
  }

  void _applyModels(Object? models) {
    if (models is! Map) return;
    final available = models['availableModels'] ?? models['available_models'];
    if (available is List) {
      availableModels = available
          .whereType<Map>()
          .map((e) => AgentModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    final current = models['currentModelId'] ?? models['current_model_id'];
    if (current != null) currentModelId = current.toString();
  }

  /// Switch the model for this session.
  ///
  /// Only ids the agent advertised are accepted; it rejects anything else with
  /// "Invalid model value", so callers must pass a [AgentModel.modelId]
  /// straight from [availableModels].
  Future<void> setModel(String modelId) async {
    if (sessionId == null) throw StateError('ACP session not ready');
    await _request('session/set_model', {
      'sessionId': sessionId,
      'modelId': modelId,
    });
    currentModelId = modelId;
  }

  void _applyModes(Object? modes) {
    if (modes is! Map) return;
    final available = modes['availableModes'] ?? modes['available_modes'];
    if (available is List) {
      availableModeIds = available
          .map((e) {
            if (e is Map) return (e['id'] ?? e['modeId'])?.toString();
            return e?.toString();
          })
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();
    }
    final current = modes['currentModeId'] ?? modes['current_mode_id'];
    if (current != null) {
      mode = AgentSessionMode.fromId(current.toString());
    }
  }

  Future<void> setMode(AgentSessionMode next) async {
    if (!_started || sessionId == null) {
      throw StateError('ACP session not ready');
    }
    await _request('session/set_mode', {
      'sessionId': sessionId,
      'modeId': next.id,
    });
    mode = next;
    _updates.add(AcpUpdate.mode(next));
  }

  void setPermissionPolicy(PermissionPolicy policy) {
    permissionPolicy = policy;
  }

  Future<void> prompt(String text) async {
    if (!_started || sessionId == null) {
      throw StateError('ACP session not ready');
    }
    await _request('session/prompt', {
      'sessionId': sessionId,
      'prompt': [
        {'type': 'text', 'text': text},
      ],
    });
  }

  /// Resolve a hanging `session/prompt` once the agent has clearly finished.
  ///
  /// Cursor occasionally streams the full answer and then never sends the
  /// JSON-RPC result. Completing here unlocks the UI instead of leaving the
  /// spinner up until the idle timeout.
  void _finishPromptEarly({String reason = 'end_turn'}) {
    final key = _promptRequestKey;
    if (key == null) return;
    final completer = _pending.remove(key);
    _promptRequestKey = null;
    if (completer == null || completer.isCompleted) return;
    completer.complete({'stopReason': reason});
  }

  Future<Map<String, dynamic>> _request(String method, Map<String, dynamic> params) async {
    final key = '$_epoch-${_nextId++}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[key] = completer;
    if (method == 'session/prompt') {
      _promptRequestKey = key;
      _promptSawOutput = false;
    }
    _write({
      'jsonrpc': '2.0',
      'id': key,
      'method': method,
      'params': params,
    });
    final timeout = switch (method) {
      'initialize' || 'session/new' => const Duration(seconds: 25),
      'session/load' => const Duration(seconds: 60),
      'session/set_mode' || 'session/set_model' => const Duration(seconds: 15),
      // Silence budget: agent may work for a long time, but once it goes quiet
      // after producing output we settle much sooner (see soft settle below).
      'session/prompt' => const Duration(minutes: 5),
      _ => const Duration(seconds: 120),
    };
    try {
      if (method == 'session/prompt') {
        return await _awaitPrompt(completer.future);
      }
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException(
            'ACP "$method" timed out after ${timeout.inSeconds}s. '
            'The remote agent may be waiting for login (`agent login`) or stuck.',
          );
        },
      );
    } finally {
      if (_promptRequestKey == key) _promptRequestKey = null;
      _pending.remove(key);
    }
  }

  /// Wait for the prompt to finish via JSON-RPC result, a turn-complete
  /// update, or a soft settle after the agent goes quiet *having already
  /// produced output*.
  Future<Map<String, dynamic>> _awaitPrompt(
    Future<Map<String, dynamic>> future,
  ) async {
    // Soft settle only after output: if the agent streamed an answer and then
    // goes silent without closing the turn, treat it as done.
    const softSettle = Duration(seconds: 25);
    // Hard ceiling when the agent never produces anything (login hang, etc.).
    const hardIdle = Duration(minutes: 5);
    final promptStarted = DateTime.now();

    while (true) {
      final now = DateTime.now();
      final sinceActivity = now.difference(_lastActivityAt);
      final sinceStart = now.difference(promptStarted);

      if (_promptSawOutput && sinceActivity >= softSettle) {
        _finishPromptEarly(reason: 'end_turn');
        try {
          return await future.timeout(Duration.zero);
        } on TimeoutException {
          return {'stopReason': 'end_turn'};
        }
      }
      if (!_promptSawOutput && sinceStart >= hardIdle) {
        throw TimeoutException(
          'ACP "session/prompt" produced no output for ${hardIdle.inMinutes} min. '
          'The remote agent may be waiting for login (`agent login`) or stuck.',
        );
      }

      final wait = _promptSawOutput
          ? softSettle - sinceActivity
          : hardIdle - sinceStart;
      try {
        return await future.timeout(wait < const Duration(milliseconds: 50)
            ? const Duration(milliseconds: 50)
            : wait);
      } on TimeoutException {
        continue;
      }
    }
  }

  Future<void> cancel() async {
    if (sessionId == null) return;
    try {
      await _request('session/cancel', {'sessionId': sessionId});
    } catch (e) {
      SafeLog.d('ACP cancel failed', e);
    }
    // Unlock a hanging session/prompt even if the agent never acknowledges.
    _finishPromptEarly(reason: 'cancelled');
  }

  Future<void> _notify(String method, Map<String, dynamic> params) async {
    _write({
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
  }

  void _write(Map<String, dynamic> message) {
    final line = '${jsonEncode(message)}\n';
    _session.stdin.add(utf8.encode(line));
  }

  void _onStdout(Uint8List data) {
    _lastActivityAt = DateTime.now();
    // Byte count, not character count: the resume offset is a file position.
    _consumed += data.length;
    onJournalAdvance?.call(_consumed);
    _buffer.write(utf8.decode(data, allowMalformed: true));
    var content = _buffer.toString();
    var index = content.indexOf('\n');
    while (index >= 0) {
      final line = content.substring(0, index).trim();
      content = content.substring(index + 1);
      if (line.isNotEmpty) {
        _handleLine(line);
      }
      index = content.indexOf('\n');
    }
    _buffer
      ..clear()
      ..write(content);
  }

  void _handleLine(String line) {
    try {
      final msg = jsonDecode(line) as Map<String, dynamic>;
      if (msg.containsKey('id') && (msg.containsKey('result') || msg.containsKey('error'))) {
        final key = '${msg['id']}';
        if (_promptRequestKey == key) _promptRequestKey = null;
        final completer = _pending.remove(key);
        if (completer == null || completer.isCompleted) return;
        if (msg['error'] != null) {
          completer.completeError(Exception(msg['error'].toString()));
        } else {
          final result = msg['result'];
          completer.complete(
            result is Map<String, dynamic> ? result : <String, dynamic>{'value': result},
          );
        }
        return;
      }

      final method = msg['method'] as String?;
      if (method == null) return;
      final params = (msg['params'] as Map<String, dynamic>?) ?? {};
      if (method == 'session/update' || method.endsWith('/update')) {
        if (_replaying) return;
        final update = AcpUpdate.fromParams(params);
        if (update.kind == AcpUpdateKind.delta ||
            update.kind == AcpUpdateKind.thought ||
            update.kind == AcpUpdateKind.tool) {
          _promptSawOutput = true;
        }
        if (update.kind == AcpUpdateKind.turnComplete) {
          _finishPromptEarly(reason: update.text);
        }
        _updates.add(update);
      } else if (method == 'session/request_permission') {
        _answerPermission(msg['id'], params);
      } else if (method == 'cursor/create_plan') {
        _answerCreatePlan(msg['id'], params);
      } else if (method == 'cursor/ask_question') {
        _answerAskQuestion(msg['id'], params);
      } else if (method == 'cursor/update_todos') {
        _handleUpdateTodos(params);
      }
    } catch (e) {
      SafeLog.d('ACP parse error', e);
    }
  }

  void _answerPermission(Object? id, Map<String, dynamic> params) {
    if (id == null) return;

    final options = params['options'];
    String? optionId;
    if (options is List) {
      final ids = options
          .map((o) {
            if (o is Map) return (o['optionId'] ?? o['id'])?.toString();
            return null;
          })
          .whereType<String>()
          .toList();
      if (permissionPolicy == PermissionPolicy.allowAll) {
        for (final o in ids) {
          if (o == 'allow-always' ||
              o == 'allow_always' ||
              o == 'allow-all' ||
              o == 'allow_all') {
            optionId = o;
            break;
          }
        }
      }
      if (optionId == null) {
        for (final o in ids) {
          if (o == 'allow-once' || o == 'allow_once') {
            optionId = o;
            break;
          }
        }
      }
      optionId ??= ids.isNotEmpty ? ids.first : null;
    }
    optionId ??= permissionPolicy == PermissionPolicy.allowAll
        ? 'allow-always'
        : 'allow-once';

    _write({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'outcome': {'outcome': 'selected', 'optionId': optionId},
      },
    });
    _updates.add(
      AcpUpdate.permission(
        permissionPolicy == PermissionPolicy.allowAll
            ? 'Auto-allowed ($optionId)'
            : 'Allowed once ($optionId)',
      ),
    );
  }

  /// Plan mode blocks until the client accepts the plan. Auto-accept on mobile
  /// so the turn can finish — Cursor CLI hangs when this goes unanswered.
  void _answerCreatePlan(Object? id, Map<String, dynamic> params) {
    if (id == null) return;

    final text = _formatCreatePlan(params);
    if (text.isNotEmpty) {
      _promptSawOutput = true;
      _updates.add(AcpUpdate.delta(text));
    }

    _write({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'outcome': {'outcome': 'accepted'},
      },
    });
  }

  static String _formatCreatePlan(Map<String, dynamic> params) {
    final buf = StringBuffer();
    final name = params['name']?.toString();
    final overview = params['overview']?.toString();
    final plan = params['plan']?.toString() ?? '';
    if (name != null && name.isNotEmpty) {
      buf.writeln('## $name');
    }
    if (overview != null && overview.isNotEmpty) {
      buf.writeln(overview);
      buf.writeln();
    }
    if (plan.isNotEmpty) {
      buf.writeln(plan);
    }
    final todos = params['todos'];
    if (todos is List && todos.isNotEmpty) {
      buf.writeln();
      for (final todo in todos) {
        if (todo is! Map) continue;
        final status = (todo['status'] ?? 'pending').toString();
        final mark = switch (status) {
          'completed' => '[x]',
          'in_progress' => '[~]',
          'cancelled' => '[-]',
          _ => '[ ]',
        };
        final content = (todo['content'] ?? todo['text'] ?? '').toString();
        if (content.isNotEmpty) buf.writeln('$mark $content');
      }
    }
    return buf.toString().trim();
  }

  /// Pick the first option for each question so the agent is not left waiting.
  void _answerAskQuestion(Object? id, Map<String, dynamic> params) {
    if (id == null) return;

    final questions = params['questions'];
    final answers = <Map<String, dynamic>>[];
    if (questions is List) {
      for (final q in questions) {
        if (q is! Map) continue;
        final qid = (q['id'] ?? '').toString();
        final options = q['options'];
        if (qid.isEmpty || options is! List || options.isEmpty) continue;
        final first = options.first;
        final oid = first is Map
            ? (first['id'] ?? '').toString()
            : first.toString();
        if (oid.isNotEmpty) {
          answers.add({
            'questionId': qid,
            'selectedOptionIds': [oid],
          });
        }
      }
    }

    if (answers.isNotEmpty) {
      _write({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'outcome': {
            'outcome': 'answered',
            'answers': answers,
          },
        },
      });
      return;
    }

    _write({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'outcome': {
          'outcome': 'skipped',
          'reason': 'No options to select',
        },
      },
    });
  }

  void _handleUpdateTodos(Map<String, dynamic> params) {
    final todos = params['todos'];
    if (todos is! List || todos.isEmpty) return;
    final lines = <String>[];
    for (final todo in todos) {
      if (todo is! Map) continue;
      final status = (todo['status'] ?? 'pending').toString();
      final mark = switch (status) {
        'completed' => '[x]',
        'in_progress' => '[~]',
        'cancelled' => '[-]',
        _ => '[ ]',
      };
      final content = (todo['content'] ?? todo['text'] ?? '').toString();
      if (content.isNotEmpty) lines.add('$mark $content');
    }
    if (lines.isEmpty) return;
    _promptSawOutput = true;
    _updates.add(AcpUpdate.delta('${lines.join('\n')}\n'));
  }

  /// Detach from the agent.
  ///
  /// Only the SSH channel is torn down. The client is pooled and shared, and a
  /// durable agent keeps running on the host so the conversation survives.
  Future<void> close() async {
    await _stdoutSub?.cancel();
    try {
      await _session.stdin.close();
    } catch (_) {}
    _session.close();
    await _updates.close();
    _promptRequestKey = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('ACP session closed'));
      }
    }
    _pending.clear();
  }
}

class AcpUpdate {
  const AcpUpdate._(
    this.kind,
    this.text, {
    this.title,
    this.tool,
    this.mode,
  });

  const AcpUpdate.delta(String text) : this._(AcpUpdateKind.delta, text);
  const AcpUpdate.thought(String text) : this._(AcpUpdateKind.thought, text);
  const AcpUpdate.permission(String text) : this._(AcpUpdateKind.permission, text);
  const AcpUpdate.error(String text) : this._(AcpUpdateKind.error, text);
  const AcpUpdate.closed() : this._(AcpUpdateKind.closed, '');
  const AcpUpdate.ignored() : this._(AcpUpdateKind.ignored, '');
  /// Agent finished the current turn (idle / stopReason), even if the
  /// `session/prompt` JSON-RPC response has not arrived yet.
  const AcpUpdate.turnComplete([String reason = 'end_turn'])
      : this._(AcpUpdateKind.turnComplete, reason);
  const AcpUpdate.status(String text, {String? title})
      : this._(AcpUpdateKind.status, text, title: title);
  AcpUpdate.toolCall(ToolCallState tool)
      : this._(AcpUpdateKind.tool, tool.title, tool: tool);
  AcpUpdate.mode(AgentSessionMode mode)
      : this._(AcpUpdateKind.mode, mode.label, mode: mode);

  factory AcpUpdate.fromParams(Map<String, dynamic> params) {
    final update = params['update'] as Map<String, dynamic>? ?? params;
    final type = (update['sessionUpdate'] ?? update['type'] ?? '').toString();

    const ignoreTypes = {
      'available_commands_update',
      'availableCommandsUpdate',
      'config_option_update',
      'configOptionUpdate',
    };
    if (ignoreTypes.contains(type)) {
      return const AcpUpdate.ignored();
    }

    if (type == 'current_mode_update' || type == 'currentModeUpdate') {
      final id = (update['modeId'] ?? update['currentModeId'] ?? '').toString();
      if (id.isEmpty) return const AcpUpdate.ignored();
      return AcpUpdate.mode(AgentSessionMode.fromId(id));
    }

    // ACP v2 ends a turn with state_update{state:idle, stopReason}. Some
    // agents also emit a bare stopReason on other update shapes. Without this
    // the client keeps "running" until the prompt RPC times out — which, when
    // the result never arrives, is minutes of a stuck spinner on a finished
    // answer.
    if (type == 'state_update' || type == 'stateUpdate') {
      final state = (update['state'] ?? '').toString().toLowerCase();
      final stop = (update['stopReason'] ?? update['stop_reason'] ?? '')
          .toString();
      if (state == 'idle' || stop.isNotEmpty) {
        return AcpUpdate.turnComplete(stop.isEmpty ? 'end_turn' : stop);
      }
      return const AcpUpdate.ignored();
    }
    final bareStop = update['stopReason'] ?? update['stop_reason'];
    if (bareStop != null && bareStop.toString().isNotEmpty) {
      return AcpUpdate.turnComplete(bareStop.toString());
    }

    if (type == 'plan' || type == 'plan_update' || type == 'planUpdate') {
      final formatted = _formatPlanUpdate(update);
      if (formatted == null || formatted.isEmpty) {
        return const AcpUpdate.ignored();
      }
      return AcpUpdate.delta(formatted);
    }

    if (type == 'session_info_update' || type == 'sessionInfoUpdate') {
      final title = update['title']?.toString();
      if (title != null && title.isNotEmpty) {
        return AcpUpdate.status('Session', title: title);
      }
      return const AcpUpdate.ignored();
    }

    if (type == 'agent_message_chunk' ||
        type == 'agentMessageChunk' ||
        type == 'agent_message' ||
        type == 'agentMessage' ||
        type == 'message') {
      final text = _extractText(update);
      if (text == null || text.isEmpty) return const AcpUpdate.ignored();
      return AcpUpdate.delta(text);
    }

    if (type.contains('thought') ||
        type.contains('Thought') ||
        type.contains('reasoning') ||
        type.contains('Reasoning')) {
      final text = _extractText(update);
      if (text == null || text.isEmpty) return const AcpUpdate.ignored();
      return AcpUpdate.thought(text);
    }

    if (type == 'tool_call' ||
        type == 'toolCall' ||
        type == 'tool_call_update' ||
        type == 'toolCallUpdate' ||
        type.contains('tool') ||
        type.contains('Tool')) {
      final tool = _parseTool(update);
      if (tool == null) return const AcpUpdate.ignored();
      return AcpUpdate.toolCall(tool);
    }

    final text = _extractText(update);
    if (text != null && text.isNotEmpty) {
      return AcpUpdate.delta(text);
    }

    SafeLog.d('ACP ignored update type=$type');
    return const AcpUpdate.ignored();
  }

  static String? _formatPlanUpdate(Map<String, dynamic> update) {
    Object? entries = update['entries'];
    final plan = update['plan'];
    if (plan is Map) {
      entries ??= plan['entries'];
    }
    if (entries is! List || entries.isEmpty) return null;

    final lines = <String>['### Plan'];
    for (final entry in entries) {
      if (entry is! Map) {
        lines.add('- $entry');
        continue;
      }
      final content = (entry['content'] ?? entry['text'] ?? '').toString();
      if (content.isEmpty) continue;
      final status = (entry['status'] ?? '').toString();
      final mark = switch (status) {
        'completed' => '[x]',
        'in_progress' => '[~]',
        'cancelled' => '[-]',
        'pending' => '[ ]',
        _ => status.isEmpty ? '•' : '[$status]',
      };
      lines.add('$mark $content');
    }
    return lines.length <= 1 ? null : lines.join('\n');
  }

  static ToolCallState? _parseTool(Map<String, dynamic> update) {
    final nested = update['toolCall'] is Map
        ? Map<String, dynamic>.from(update['toolCall'] as Map)
        : update;
    final id = (nested['toolCallId'] ??
            nested['tool_call_id'] ??
            nested['id'] ??
            update['toolCallId'] ??
            '')
        .toString();
    final title = (nested['title'] ??
            nested['name'] ??
            nested['toolName'] ??
            update['title'] ??
            'Tool')
        .toString();
    if (id.isEmpty && title == 'Tool') return null;

    final locations = <String>[];
    final rawLocs = nested['locations'] ?? update['locations'];
    if (rawLocs is List) {
      for (final loc in rawLocs) {
        if (loc is Map) {
          final path = loc['path']?.toString();
          if (path != null && path.isNotEmpty) {
            final line = loc['line'];
            locations.add(line != null ? '$path:$line' : path);
          }
        }
      }
    }

    return ToolCallState(
      toolCallId: id.isEmpty ? title : id,
      title: title,
      kind: (nested['kind'] ?? update['kind'])?.toString(),
      status: (nested['status'] ?? update['status'] ?? 'pending').toString(),
      locations: locations,
      rawInput: ToolCallState.formatOpaque(nested['rawInput'] ?? update['rawInput']),
      rawOutput: ToolCallState.formatOpaque(nested['rawOutput'] ?? update['rawOutput']),
    );
  }

  static String? _extractText(Map<String, dynamic> update) {
    final content = update['content'];
    if (content is Map && content['text'] != null) {
      return content['text'].toString();
    }
    if (content is String && content.isNotEmpty) return content;
    if (update['text'] != null) return update['text'].toString();

    final message = update['message'] ?? update['agentMessageChunk'];
    if (message is Map) {
      if (message['text'] != null) return message['text'].toString();
      final inner = message['content'];
      if (inner is Map && inner['text'] != null) return inner['text'].toString();
      if (inner is String) return inner;
    }
    if (message is String) return message;

    final delta = update['delta'] ?? update['chunk'];
    if (delta is Map && delta['text'] != null) return delta['text'].toString();
    if (delta is String) return delta;

    return null;
  }

  final AcpUpdateKind kind;
  final String text;
  final String? title;
  final ToolCallState? tool;
  final AgentSessionMode? mode;
}

enum AcpUpdateKind {
  delta,
  tool,
  thought,
  permission,
  error,
  closed,
  ignored,
  status,
  mode,
  turnComplete,
}
