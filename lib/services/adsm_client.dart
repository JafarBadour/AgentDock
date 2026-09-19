import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../data/models/agent_mode.dart';
import '../data/models/agent_model.dart';
import '../data/models/agent_provider.dart';
import '../data/models/chat_message.dart';
import '../data/models/host.dart';
import '../data/models/prompt_image.dart';
import '../data/models/tool_call_state.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import 'agent_session.dart';
import 'adsm_version.dart';
import 'cursor_acp_service.dart';
import 'local_host_bootstrap.dart';
import 'ssh_service.dart';
import 'transcript_budget.dart';

export 'adsm_version.dart';

/// One long-lived `agentdock-adsm client` SSH bridge per host.
///
/// ADSM already multiplexes many chats over a single NDJSON client. Opening a
/// fresh exclusive SSH per agent exhausts sshd channels (especially via
/// ProxyJump) and surfaces as `SSHChannelOpenError(...: open failed)`.
class AdsmBridgePool {
  AdsmBridgePool(this._ssh);

  final SshService _ssh;
  final Map<String, _AdsmBridgeEntry> _entries = {};
  final Map<String, Future<AdsmClient>> _connecting = {};

  /// Borrow the shared bridge for [host]. Pair with [release].
  Future<AdsmClient> acquire(Host host) async {
    while (true) {
      final existing = _entries[host.id];
      if (existing != null && existing.client.isOpen) {
        existing.refs++;
        return existing.client;
      }
      if (existing != null) {
        _entries.remove(host.id);
      }

      var inflight = _connecting[host.id];
      if (inflight == null) {
        late final Future<AdsmClient> created;
        created = () async {
          try {
            return await AdsmClient.connect(_ssh, host);
          } finally {
            if (identical(_connecting[host.id], created)) {
              _connecting.remove(host.id);
            }
          }
        }();
        _connecting[host.id] = created;
        inflight = created;
      }

      final client = await inflight;
      if (!client.isOpen) {
        // Stale connect — loop and open a fresh one.
        continue;
      }
      final entry = _entries.putIfAbsent(host.id, () {
        unawaited(
          client.done.whenComplete(() {
            final cur = _entries[host.id];
            if (cur != null && identical(cur.client, client)) {
              _entries.remove(host.id);
            }
          }),
        );
        return _AdsmBridgeEntry(client);
      });
      if (!identical(entry.client, client) || !entry.client.isOpen) {
        continue;
      }
      entry.refs++;
      return entry.client;
    }
  }

  /// Drop a live bridge (e.g. after the host ADSM daemon was restarted).
  Future<void> drop(String hostId) async {
    final entry = _entries.remove(hostId);
    if (entry == null) return;
    entry.refs = 0;
    try {
      await entry.client.close();
    } catch (_) {}
  }

  /// Drop one borrower. Closes the SSH bridge when the last chat releases.
  Future<void> release(String hostId) async {
    final entry = _entries[hostId];
    if (entry == null) return;
    entry.refs--;
    if (entry.refs > 0) return;
    _entries.remove(hostId);
    try {
      await entry.client.close();
    } catch (_) {}
  }
}

class _AdsmBridgeEntry {
  _AdsmBridgeEntry(this.client);

  final AdsmClient client;
  int refs = 0;
}

/// NDJSON control client for the host ADSM daemon (`agentdock-adsm client`).
class AdsmClient {
  AdsmClient._ssh(this._sshClient, this._session) : _process = null;

  AdsmClient._local(this._process) : _sshClient = null, _session = null;

  /// Dedicated SSH connection — not pooled, so periodic pool health checks
  /// cannot tear down a long-lived ADSM bridge mid-turn.
  final SSHClient? _sshClient;
  final SSHSession? _session;

  /// Local `agentdock-adsm client` process for This Mac/PC (no SSH).
  final Process? _process;

  final _pending = <Object, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _buffer = StringBuffer();
  StreamSubscription<List<int>>? _sub;
  bool _open = true;
  bool _drainingStdout = false;
  int _nextId = 1;
  final Completer<void> _done = Completer<void>();

  StreamSubscription? _stderrSub;

  void _writeStdin(List<int> data) {
    final process = _process;
    if (process != null) {
      process.stdin.add(data);
      return;
    }
    _session!.stdin.add(Uint8List.fromList(data));
  }

  Future<void> _closeStdin() async {
    final process = _process;
    if (process != null) {
      await process.stdin.close();
      return;
    }
    await _session!.stdin.close();
  }

  Stream<List<int>> get _stdout {
    final process = _process;
    if (process != null) return process.stdout;
    return _session!.stdout;
  }

  Stream<List<int>> get _stderr {
    final process = _process;
    if (process != null) return process.stderr;
    return _session!.stderr;
  }

  Stream<Map<String, dynamic>> get events => _events.stream;

  bool get isOpen => _open;

  /// Completes when the ADSM channel / SSH session ends.
  Future<void> get done => _done.future;

  static const _clientLaunch = r'''
export PATH="$HOME/.local/bin:$PATH"
if command -v agentdock-adsm >/dev/null 2>&1; then
  exec agentdock-adsm client
elif [ -x "$HOME/.local/bin/agentdock-adsm" ]; then
  exec "$HOME/.local/bin/agentdock-adsm" client
else
  echo "agentdock-adsm not found" >&2
  exit 127
fi
''';

  static Future<AdsmClient> connect(SshService ssh, Host host) async {
    if (isDesktopLocalHostPlatform && isLocalThisComputerHost(host)) {
      return _connectLocal();
    }
    final client = await ssh.connectExclusive(host);
    final session = await client.execute(_clientLaunch);
    final adsm = AdsmClient._ssh(client, session);
    adsm._listen();
    // Warm ping — also learns protocol version for wire chunking.
    final pong = await adsm
        .request('ping', {})
        .timeout(const Duration(seconds: 8));
    adsm.protocolVersion = pong['version']?.toString();
    return adsm;
  }

  static Future<AdsmClient> _connectLocal() async {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final path = [
      if (home.isNotEmpty) '$home/.local/bin',
      if (Platform.isMacOS) '/opt/homebrew/bin',
      '/usr/local/bin',
      Platform.environment['PATH'] ?? '',
    ].where((s) => s.isNotEmpty).join(Platform.isWindows ? ';' : ':');
    final process = await Process.start(
      Platform.isWindows ? 'bash' : '/bin/bash',
      ['-lc', _clientLaunch],
      workingDirectory: home.isEmpty ? null : home,
      environment: {...Platform.environment, 'PATH': path},
    );
    final adsm = AdsmClient._local(process);
    adsm._listen();
    final pong = await adsm
        .request('ping', {})
        .timeout(const Duration(seconds: 8));
    adsm.protocolVersion = pong['version']?.toString();
    return adsm;
  }

  void _listen() {
    _sub = _stdout.listen(
      (data) {
        _buffer.write(utf8.decode(data, allowMalformed: true));
        unawaited(_drainStdout());
      },
      onError: (Object e) {
        SafeLog.d('ADSM stdout error', e);
        _failAll(e);
      },
      onDone: () {
        _open = false;
        _failAll(StateError('ADSM channel closed'));
        if (!_events.isClosed) {
          _events.add({'method': 'closed'});
        }
        if (!_done.isCompleted) _done.complete();
      },
    );
    _stderrSub = _stderr.listen((data) {
      final text = utf8.decode(data, allowMalformed: true).trim();
      if (text.isNotEmpty) SafeLog.d('ADSM stderr: $text');
    });
  }

  /// Parse NDJSON off the critical path in batches so a tool-spam burst cannot
  /// freeze scrolling / panel switches on the UI isolate.
  Future<void> _drainStdout() async {
    if (_drainingStdout) return;
    _drainingStdout = true;
    try {
      var processed = 0;
      while (_open || _buffer.isNotEmpty) {
        var content = _buffer.toString();
        final index = content.indexOf('\n');
        if (index < 0) {
          _buffer
            ..clear()
            ..write(content);
          break;
        }
        final line = content.substring(0, index).trim();
        _buffer
          ..clear()
          ..write(content.substring(index + 1));
        if (line.isNotEmpty) _onLine(line);
        processed++;
        // Yield every batch so frames can paint between JSON decode spikes.
        if (processed % 24 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    } finally {
      _drainingStdout = false;
      // More data may have arrived while we yielded.
      if (_buffer.toString().contains('\n')) {
        unawaited(_drainStdout());
      }
    }
  }

  void _onLine(String line) {
    try {
      final msg = jsonDecode(line) as Map<String, dynamic>;
      if (msg.containsKey('id') &&
          (msg.containsKey('result') || msg.containsKey('error'))) {
        final id = msg['id'];
        final c = _pending.remove(id);
        if (c == null || c.isCompleted) return;
        if (msg['error'] != null) {
          c.completeError(Exception(msg['error'].toString()));
        } else {
          final result = msg['result'];
          c.complete(
            result is Map<String, dynamic>
                ? result
                : <String, dynamic>{'value': result},
          );
        }
        return;
      }
      if (msg['method'] == 'event') {
        final params = msg['params'];
        if (params is Map<String, dynamic>) {
          _events.add(params);
        } else if (params is Map) {
          _events.add(Map<String, dynamic>.from(params));
        }
        return;
      }
      if (msg['method'] == 'closed') {
        _events.add({'method': 'closed'});
      }
    } catch (e) {
      SafeLog.d('ADSM parse error', e);
    }
  }

  /// Host ADSM protocol version from the last successful `ping` (e.g. `0.4.2`).
  String? protocolVersion;

  /// Soft max NDJSON line size. Larger RPCs go out as `rpc.chunk` pieces when
  /// the host is ≥ 0.4.2 (avoids killing the channel on big prompts/images).
  static const int chunkSoftLimit = 48 * 1024;

  /// Payload bytes per `rpc.chunk` line (ASCII base64); leave headroom for framing.
  static const int chunkPayloadBytes = 36 * 1024;

  bool get _supportsWireChunks => adsmSupportsWireChunks(protocolVersion);

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (!_open) throw StateError('ADSM channel closed');
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    final payload = jsonEncode({'id': id, 'method': method, 'params': params});
    try {
      _writeRequest(id, payload);
    } catch (e) {
      _pending.remove(id);
      throw StateError('ADSM write failed: $e');
    }
    try {
      return await c.future.timeout(
        timeout,
        onTimeout: () {
          _pending.remove(id);
          throw TimeoutException('ADSM "$method" timed out');
        },
      );
    } finally {
      _pending.remove(id);
    }
  }

  void _writeRequest(Object id, String payload) {
    final bytes = utf8.encode(payload);
    if (!_supportsWireChunks || bytes.length <= chunkSoftLimit) {
      _writeStdin(utf8.encode('$payload\n'));
      return;
    }
    final b64 = base64Encode(bytes);
    final n = (b64.length + chunkPayloadBytes - 1) ~/ chunkPayloadBytes;
    for (var i = 0; i < n; i++) {
      final start = i * chunkPayloadBytes;
      final end = start + chunkPayloadBytes > b64.length
          ? b64.length
          : start + chunkPayloadBytes;
      final chunkLine = jsonEncode({
        'method': 'rpc.chunk',
        'params': {
          'reqId': id,
          'i': i,
          'n': n,
          'encoding': 'base64',
          'data': b64.substring(start, end),
        },
      });
      _writeStdin(utf8.encode('$chunkLine\n'));
    }
  }

  void _failAll(Object e) {
    final pending = Map<Object, Completer<Map<String, dynamic>>>.from(_pending);
    _pending.clear();
    for (final c in pending.values) {
      if (!c.isCompleted) c.completeError(e);
    }
  }

  Future<void> close() async {
    _open = false;
    await _sub?.cancel();
    _sub = null;
    await _stderrSub?.cancel();
    _stderrSub = null;
    try {
      await _closeStdin();
    } catch (_) {}
    try {
      _session?.close();
    } catch (_) {}
    try {
      _sshClient?.close();
    } catch (_) {}
    try {
      _process?.kill();
    } catch (_) {}
    _failAll(StateError('ADSM closed'));
    // Notify borrowers before closing the broadcast — otherwise sessions keep
    // a dead client while the UI still shows Bridge · Connected.
    if (!_events.isClosed) {
      try {
        _events.add({'method': 'closed'});
      } catch (_) {}
    }
    if (!_done.isCompleted) _done.complete();
    await _events.close();
  }
}

/// Snapshot for the ADSM host status sheet (daemon + this chat's worker).
class AdsmHostHealth {
  const AdsmHostHealth({
    required this.hostLabel,
    required this.bridgeOpen,
    required this.pingVersion,
    required this.requiredVersion,
    this.daemonPid,
    this.workerCount,
    this.eventSeq,
    this.agentStatus,
    this.agentLastError,
    this.acpSessionId,
    this.fetchError,
  });

  final String hostLabel;
  final bool bridgeOpen;
  final String? pingVersion;
  final String requiredVersion;
  final int? daemonPid;
  final int? workerCount;
  final int? eventSeq;
  final String? agentStatus;
  final String? agentLastError;
  final String? acpSessionId;
  final String? fetchError;

  bool get versionMeets => adsmVersionMeets(pingVersion, requiredVersion);

  bool get daemonReachable =>
      bridgeOpen && fetchError == null && daemonPid != null;

  bool get agentHealthy {
    final st = agentStatus?.toLowerCase();
    return st != 'dead' && st != 'error';
  }

  bool get healthy =>
      bridgeOpen && versionMeets && daemonReachable && agentHealthy;
}

/// Durable agent session mediated by ADSM (not a raw ACP journal bridge).
class AdsmSession implements AgentSession {
  AdsmSession._({
    required this.host,
    required this.chatId,
    required AdsmClient client,
    AdsmBridgePool? bridgePool,
  }) : _client = client,
       _bridgePool = bridgePool;

  final Host host;
  final String chatId;
  final AdsmClient _client;
  final AdsmBridgePool? _bridgePool;

  final _updates = StreamController<AcpUpdate>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _eventSub;

  @override
  String? sessionId;

  @override
  AcpTransport get transport => AcpTransport.durable;

  @override
  AgentSessionMode mode = AgentSessionMode.agent;

  @override
  PermissionPolicy permissionPolicy = PermissionPolicy.allowAll;

  @override
  List<AgentModel> availableModels = const [];

  @override
  String? currentModelId;

  @override
  List<String> availableModeIds = const ['ask', 'agent', 'plan'];

  @override
  AcpAgentCapabilities capabilities = const AcpAgentCapabilities();

  @override
  bool resumedInPlace = false;

  @override
  bool get isPromptActive => _promptInFlight;

  bool _promptInFlight = false;
  Completer<void>? _promptCompleter;
  String? _daemonStatus;

  @override
  Stream<AcpUpdate> get updates => _updates.stream;

  /// Shared ADSM client this session rides on (for coalescing `agents.list`).
  AdsmClient get bridgeClient => _client;

  /// Host-authoritative status when known (`idle` / `running` / …).
  String? get daemonStatus => _daemonStatus;

  /// ADSM protocol version from the last successful `ping`.
  String? get protocolVersion => _client.protocolVersion;

  /// Pull this worker's status from `agents.list` and push it through the same
  /// update path as live daemon events — clears sticky "Exploring / Thinking"
  /// when the host already went idle.
  ///
  /// Prefer [ActiveAcpSessions] polling once per bridge via [applyAgentsList]
  /// so N open chats do not each hammer `agents.list`.
  ///
  /// Set [forceEmit] when the UI must re-sync even if status is unchanged
  /// (watchdog clearing sticky tools). Periodic polls keep it false.
  Future<String?> refreshDaemonStatus({bool forceEmit = false}) async {
    if (_updates.isClosed) return _daemonStatus;
    try {
      final list = await _client.request(
        'agents.list',
        {},
        timeout: const Duration(seconds: 8),
      );
      return applyAgentsList(list, forceEmit: forceEmit);
    } catch (e) {
      SafeLog.d('ADSM status poll failed chat=$chatId', e);
      // Do not return a stale "running" — that freezes the UI as working
      // forever when the bridge/VPN drops.
      return null;
    }
  }

  /// Apply a shared `agents.list` result to this session (no extra RPC).
  String? applyAgentsList(Map<String, dynamic> list, {bool forceEmit = false}) {
    if (_updates.isClosed) return _daemonStatus;
    final agents = list['agents'];
    if (agents is! List) return _daemonStatus;
    for (final raw in agents) {
      if (raw is! Map) continue;
      if (raw['chatId']?.toString() != chatId) continue;
      final snap = Map<String, dynamic>.from(raw);
      final prev = _daemonStatus;
      _applySnapshot(snap);
      final st = _daemonStatus;
      if (st == null || st.isEmpty) return st;
      final changed = st != prev;
      // Only notify the UI when status actually changes — re-emitting idle /
      // running every 15s rebuilt every ListenableBuilder row and fought
      // scrolling. Watchdogs pass [forceEmit] when they need a sticky clear.
      if (changed || forceEmit) {
        if (!_updates.isClosed) {
          _updates.add(AcpUpdate.daemonStatus(st));
          if (st == 'idle' || st == 'dead' || st == 'error') {
            _updates.add(const AcpUpdate.activity(''));
          } else if (changed &&
              (st == 'running' ||
                  st == 'starting' ||
                  st == 'waiting_permission')) {
            _updates.add(
              AcpUpdate.activity(
                st == 'waiting_permission'
                    ? 'Waiting for permission'
                    : 'Working on host…',
              ),
            );
          }
        }
      }
      return st;
    }
    // List succeeded but this chat is gone — worker finished / was reaped.
    final prev = _daemonStatus;
    if (prev == 'running' ||
        prev == 'starting' ||
        prev == 'waiting_permission' ||
        forceEmit) {
      _daemonStatus = 'idle';
      if (!_updates.isClosed) {
        _updates.add(const AcpUpdate.daemonStatus('idle'));
        _updates.add(const AcpUpdate.activity(''));
      }
      return 'idle';
    }
    return _daemonStatus;
  }

  /// Live daemon + agent snapshot for the status sheet.
  Future<AdsmHostHealth> fetchHostHealth({required bool bridgeOpen}) async {
    String? pingVersion = _client.protocolVersion;
    int? pid;
    int? workers;
    int? seq;
    String? agentStatus = _daemonStatus;
    String? agentError;
    String? acpId = sessionId;
    String? fetchError;

    // The SSH NDJSON client can die while ChatSessionRuntime still thinks the
    // bridge is up (missed closed event / shared-pool teardown).
    final live = bridgeOpen && _client.isOpen;
    if (!live) {
      return AdsmHostHealth(
        hostLabel: host.displayLabel,
        bridgeOpen: false,
        pingVersion: pingVersion,
        requiredVersion: kRequiredAdsmVersion,
        daemonPid: pid,
        workerCount: workers,
        eventSeq: seq,
        agentStatus: agentStatus,
        agentLastError: agentError,
        acpSessionId: acpId,
        fetchError: _client.isOpen
            ? 'Bridge closed — reconnect to refresh'
            : 'ADSM channel closed — tap Reconnect',
      );
    }

    try {
      final pong = await _client.request(
        'ping',
        {},
        timeout: const Duration(seconds: 6),
      );
      pingVersion = pong['version']?.toString() ?? pingVersion;
      _client.protocolVersion = pingVersion;
    } catch (e) {
      fetchError = 'Ping failed: $e';
      if ('$e'.toLowerCase().contains('channel closed') ||
          '$e'.toLowerCase().contains('adsm closed')) {
        return AdsmHostHealth(
          hostLabel: host.displayLabel,
          bridgeOpen: false,
          pingVersion: pingVersion,
          requiredVersion: kRequiredAdsmVersion,
          agentStatus: agentStatus,
          agentLastError: agentError,
          acpSessionId: acpId,
          fetchError: 'ADSM channel closed — tap Reconnect',
        );
      }
    }

    try {
      final daemon = await _client.request(
        'daemon.status',
        {},
        timeout: const Duration(seconds: 6),
      );
      pid = daemon['pid'] is int
          ? daemon['pid'] as int
          : int.tryParse('${daemon['pid']}');
      workers = daemon['workers'] is int
          ? daemon['workers'] as int
          : int.tryParse('${daemon['workers']}');
      seq = daemon['seq'] is int
          ? daemon['seq'] as int
          : int.tryParse('${daemon['seq']}');
      pingVersion ??= daemon['version']?.toString();
    } catch (e) {
      fetchError ??= 'Daemon status failed: $e';
    }

    try {
      final list = await _client.request(
        'agents.list',
        {},
        timeout: const Duration(seconds: 8),
      );
      final agents = list['agents'];
      if (agents is List) {
        for (final raw in agents) {
          if (raw is! Map) continue;
          if (raw['chatId']?.toString() != chatId) continue;
          final snap = Map<String, dynamic>.from(raw);
          _applySnapshot(snap);
          agentStatus = snap['status']?.toString() ?? agentStatus;
          agentError = snap['lastError']?.toString();
          acpId = snap['acpSessionId']?.toString() ?? acpId;
          break;
        }
      }
    } catch (e) {
      fetchError ??= 'Agent list failed: $e';
    }

    return AdsmHostHealth(
      hostLabel: host.displayLabel,
      bridgeOpen: true,
      pingVersion: pingVersion,
      requiredVersion: kRequiredAdsmVersion,
      daemonPid: pid,
      workerCount: workers,
      eventSeq: seq,
      agentStatus: agentStatus,
      agentLastError: agentError,
      acpSessionId: acpId,
      fetchError: fetchError,
    );
  }

  static Future<AdsmSession> start({
    required SshService ssh,
    required SecureStore secureStore,
    required Host host,
    required String cwd,
    required String binary,
    required String chatId,
    required AgentProvider provider,
    required List<Map<String, dynamic>> mcpServers,
    AgentSessionMode initialMode = AgentSessionMode.agent,
    PermissionPolicy permissionPolicy = PermissionPolicy.allowAll,
    String? resumeSessionId,
    String? preferredModelId,
    AdsmBridgePool? bridgePool,
    bool forceNewSession = false,
  }) async {
    final apiKey = switch (provider) {
      AgentProvider.cursor => await secureStore.readCursorApiKey(),
      AgentProvider.claude => await secureStore.readAnthropicApiKey(),
    };

    final pool = bridgePool;
    final client = pool != null
        ? await pool.acquire(host)
        : await AdsmClient.connect(ssh, host);
    final session = AdsmSession._(
      host: host,
      chatId: chatId,
      client: client,
      bridgePool: pool,
    );
    session.mode = initialMode;
    session.permissionPolicy = permissionPolicy;
    session._eventSub = client.events.listen(
      session._onEvent,
      onDone: () {
        if (!session._updates.isClosed) {
          session._updates.add(const AcpUpdate.closed());
        }
      },
      onError: (Object e) {
        SafeLog.d('ADSM event stream error', e);
        if (!session._updates.isClosed) {
          session._updates.add(const AcpUpdate.closed());
        }
      },
    );

    try {
      await client.request('session.subscribe', {
        'chatId': chatId,
        'afterSeq': 0,
      });

      final snap = await client.request('agents.ensure', {
        'chatId': chatId,
        'cwd': cwd,
        'binary': binary,
        'provider': provider.id,
        if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
        'fullAccess': permissionPolicy.fullAccess,
        'permissionAsk': !permissionPolicy.fullAccess,
        if (!forceNewSession && resumeSessionId != null)
          'resumeSessionId': resumeSessionId,
        if (forceNewSession) 'forceNewSession': true,
        'mcpServers': mcpServers,
        'mode': initialMode.id,
        if (preferredModelId != null && preferredModelId.isNotEmpty)
          'modelId': preferredModelId,
      }, timeout: const Duration(seconds: 90));

      session._applySnapshot(snap);
      // If ensure returned RUNNING attach without re-init, treat as resume.
      final state = snap['status']?.toString();
      if (!forceNewSession &&
          state == 'idle' &&
          (resumeSessionId != null || session.sessionId != null)) {
        session.resumedInPlace = snap['acpSessionId'] == resumeSessionId;
      }
      // Pull durable host transcript ASAP — before UI settles on SQLite-only.
      try {
        session.hostTranscript = await session.pullTranscript(
          maxBytes: kTranscriptChunkBytes,
        );
      } catch (e) {
        SafeLog.d('ADSM transcript.pull failed', e);
      }
      return session;
    } catch (e) {
      await session._eventSub?.cancel();
      session._eventSub = null;
      if (pool != null) {
        await pool.release(host.id);
      } else {
        try {
          await client.close();
        } catch (_) {}
      }
      rethrow;
    }
  }

  /// Messages pulled from host `~/.agentdock/messages/<chatId>.jsonl`.
  List<ChatMessage> hostTranscript = const [];

  /// Whether the host archive has messages older than [hostTranscript].
  bool hostTranscriptHasMore = false;

  Future<List<ChatMessage>> pullTranscript({
    int limit = 300,
    int? maxBytes,
    String? beforeId,
  }) async {
    final result = await pullTranscriptPage(
      limit: limit,
      maxBytes: maxBytes,
      beforeId: beforeId,
    );
    return result.messages;
  }

  Future<({List<ChatMessage> messages, bool hasMore, int bytes})>
  pullTranscriptPage({
    int limit = 300,
    int? maxBytes,
    String? beforeId,
  }) async {
    final params = <String, dynamic>{
      'chatId': chatId,
      'limit': limit,
      if (maxBytes != null && maxBytes > 0) 'maxBytes': maxBytes,
      if (beforeId != null && beforeId.isNotEmpty) 'beforeId': beforeId,
    };
    final result = await _client.request('transcript.pull', params);
    final raw = result['messages'];
    final out = <ChatMessage>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        try {
          out.add(ChatMessage.fromMap(Map<String, Object?>.from(item)));
        } catch (_) {}
      }
    }
    final hasMore = result['hasMore'] == true;
    final bytes = (result['bytes'] is int)
        ? result['bytes'] as int
        : out.fold<int>(0, (sum, m) => sum + chatMessageBytes(m));
    if (beforeId == null) {
      hostTranscript = out;
      hostTranscriptHasMore = hasMore;
    }
    return (messages: out, hasMore: hasMore, bytes: bytes);
  }

  /// Push local messages into the host store (merge by id).
  ///
  /// Chunked so a full history sync cannot blow asyncio's NDJSON line limit on
  /// the host (that used to kill the ADSM channel mid-send).
  Future<void> syncTranscriptToHost(List<ChatMessage> messages) async {
    if (messages.isEmpty) return;
    const chunkSize = 40;
    for (var i = 0; i < messages.length; i += chunkSize) {
      final end = i + chunkSize > messages.length
          ? messages.length
          : i + chunkSize;
      final slice = messages.sublist(i, end);
      await _client.request('transcript.sync', {
        'chatId': chatId,
        'messages': [for (final m in slice) m.toMap()],
      });
    }
  }

  void _applySnapshot(Map<String, dynamic> snap) {
    sessionId = snap['acpSessionId'] as String? ?? sessionId;
    _daemonStatus = snap['status']?.toString();
    final modeId = snap['mode']?.toString();
    if (modeId != null && modeId.isNotEmpty) {
      mode = AgentSessionMode.fromId(modeId);
    }
    currentModelId = snap['modelId'] as String? ?? currentModelId;
    final models = snap['availableModels'];
    if (models is List) {
      availableModels = models
          .whereType<Map>()
          .map((e) => AgentModel.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    final modes = snap['availableModes'];
    if (modes is List) {
      availableModeIds = modes.map((e) => e.toString()).toList();
    }
    final load = snap['loadSession'];
    if (load is bool) {
      capabilities = AcpAgentCapabilities(loadSession: load);
    }
  }

  void _onEvent(Map<String, dynamic> params) {
    if (params['method'] == 'closed') {
      if (!_updates.isClosed) _updates.add(const AcpUpdate.closed());
      return;
    }
    final chat = params['chatId']?.toString();
    if (chat != null && chat.isNotEmpty && chat != chatId) return;

    final kind = params['kind']?.toString() ?? '';
    switch (kind) {
      case 'text':
        final t = params['text']?.toString() ?? '';
        if (t.isNotEmpty) _updates.add(AcpUpdate.delta(t));
      case 'thought':
        final t = params['text']?.toString() ?? '';
        if (t.isNotEmpty) _updates.add(AcpUpdate.thought(t));
      case 'tool_start':
      case 'tool_update':
        final tool = _toolFrom(params['tool']);
        if (tool != null) _updates.add(AcpUpdate.toolCall(tool));
      case 'permission':
        if (params['resolved'] == true) {
          _updates.add(
            AcpUpdate.permission(params['text']?.toString() ?? 'Permission'),
          );
          break;
        }
        final reqId = params['requestId'];
        final options = <PermissionOption>[];
        final rawOpts = params['options'];
        if (rawOpts is List) {
          for (final o in rawOpts) {
            if (o is Map) {
              options.add(
                PermissionOption(
                  optionId: (o['optionId'] ?? o['id'] ?? '').toString(),
                  name: (o['name'] ?? o['label'] ?? '').toString(),
                  kind: (o['kind'] ?? '').toString(),
                ),
              );
            }
          }
        }
        final title =
            params['title']?.toString() ??
            params['text']?.toString() ??
            'Allow this action?';
        if (reqId != null) {
          _updates.add(
            AcpUpdate.permission(
              title,
              request: PendingPermissionRequest(
                requestId: reqId,
                title: title,
                description: null,
                options: options,
              ),
            ),
          );
        } else {
          _updates.add(AcpUpdate.permission(title));
        }
      case 'turn_complete':
        _finishPrompt();
        _updates.add(const AcpUpdate.activity(''));
        _updates.add(
          AcpUpdate.turnComplete(params['reason']?.toString() ?? 'end_turn'),
        );
      case 'activity':
        final label = params['label']?.toString() ?? '';
        _updates.add(AcpUpdate.activity(label));
      case 'prompt_accepted':
        final mid = params['userMessageId']?.toString() ?? '';
        _updates.add(AcpUpdate.promptAccepted(mid));
        // Treat accept as host activity so Thinking can arm.
        _updates.add(const AcpUpdate.activity('Thinking'));
      case 'status':
        _daemonStatus = params['status']?.toString() ?? _daemonStatus;
        final title = params['title']?.toString();
        if (title != null && title.isNotEmpty) {
          _updates.add(AcpUpdate.status('Session', title: title));
        }
        final st = params['status']?.toString();
        if (st != null && st.isNotEmpty) {
          _updates.add(AcpUpdate.daemonStatus(st));
        }
        // Map daemon lifecycle into activity when no explicit activity event.
        if (st == 'running') {
          _updates.add(const AcpUpdate.activity('Thinking'));
        } else if (st == 'idle' || st == 'dead') {
          _updates.add(const AcpUpdate.activity(''));
        }
        if (st == 'waiting_permission') {
          _updates.add(const AcpUpdate.activity('Waiting for permission'));
        }
      case 'mode':
        final mid = params['mode']?.toString();
        if (mid != null && mid.isNotEmpty) {
          mode = AgentSessionMode.fromId(mid);
          _updates.add(AcpUpdate.mode(mode));
        }
      case 'usage':
        final used = _asInt(params['used']);
        final size = _asInt(params['size']);
        if (used != null && size != null) {
          _updates.add(AcpUpdate.usage(used: used, size: size));
        }
      case 'session':
        _applySnapshot({
          'acpSessionId': params['acpSessionId'],
          'models': params['models'] is List
              ? {
                  'availableModels': params['models'],
                  'currentModelId': params['modelId'],
                }
              : null,
          'availableModels': params['models'],
          'availableModes': params['modes'],
          'mode': params['mode'],
          'modelId': params['modelId'],
          'loadSession': params['loadSession'],
          'status': _daemonStatus,
        });
        if (params['models'] is Map) {
          _applySnapshot({
            ...params,
            'availableModels': (params['models'] as Map)['availableModels'],
            'modelId':
                (params['models'] as Map)['currentModelId'] ??
                params['modelId'],
          });
        }
      case 'error':
        _finishPrompt();
        final t = params['text']?.toString() ?? 'ADSM error';
        _updates.add(AcpUpdate.error(t));
      default:
        break;
    }
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v == null) return null;
    return int.tryParse(v.toString());
  }

  static ToolCallState? _toolFrom(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final id = (m['toolCallId'] ?? m['id'] ?? '').toString();
    final title = (m['title'] ?? 'Tool').toString();
    if (id.isEmpty && title == 'Tool') return null;
    final locations = <String>[];
    final locs = m['locations'];
    if (locs is List) {
      for (final loc in locs) {
        locations.add(loc.toString());
      }
    }
    return ToolCallState(
      toolCallId: id.isEmpty ? title : id,
      title: title,
      kind: m['kind']?.toString(),
      status: (m['status'] ?? 'pending').toString(),
      locations: locations,
      rawInput: ToolCallState.formatOpaque(m['rawInput']),
      rawOutput: ToolCallState.formatOpaque(m['rawOutput']),
      content: ToolCallState.formatOpaque(m['content']),
    );
  }

  void _finishPrompt() {
    _promptInFlight = false;
    final c = _promptCompleter;
    _promptCompleter = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> prompt(
    String text, {
    List<PromptImage> images = const [],
    String? userMessageId,
    DateTime? userCreatedAt,
  }) async {
    _promptInFlight = true;
    final c = Completer<void>();
    _promptCompleter = c;
    try {
      // ADSM ≥0.4.3 returns {accepted:true} immediately; older hosts block
      // until the full turn. Delivery retries must not wait for the turn.
      final result = await _client.request('session.prompt', {
        'chatId': chatId,
        'text': text,
        if (images.isNotEmpty)
          'images': [for (final img in images) img.toWire()],
        if (userMessageId != null && userMessageId.isNotEmpty)
          'userMessageId': userMessageId,
        if (userCreatedAt != null)
          'userCreatedAt': userCreatedAt.toUtc().toIso8601String(),
      }, timeout: const Duration(seconds: 25));

      final accepted = result['accepted'] == true;
      if (accepted) {
        final mid = result['userMessageId']?.toString() ?? '';
        _emitDelivered(mid);
        return;
      }

      // Legacy host: RPC waited for the whole turn.
      _finishPrompt();
    } catch (e) {
      // Host mid-turn / transport errors — do not fake a delivery ack.
      _finishPrompt();
      rethrow;
    }
  }

  void _emitDelivered(String userMessageId) {
    if (_updates.isClosed) return;
    _updates.add(AcpUpdate.promptAccepted(userMessageId));
    _updates.add(const AcpUpdate.activity('Thinking'));
  }

  @override
  Future<void> cancel() async {
    try {
      await _client.request('session.cancel', {'chatId': chatId});
    } catch (e) {
      SafeLog.d('ADSM cancel failed', e);
    }
    _finishPrompt();
  }

  @override
  Future<void> setMode(AgentSessionMode next) async {
    final snap = await _client.request('session.set_mode', {
      'chatId': chatId,
      'modeId': next.id,
    });
    _applySnapshot(snap);
    mode = next;
    _updates.add(AcpUpdate.mode(next));
  }

  @override
  Future<void> setModel(String modelId) async {
    // May relaunch the remote tmux worker when the ACP adapter lacks model RPCs.
    final snap = await _client.request('session.set_model', {
      'chatId': chatId,
      'modelId': modelId,
    }, timeout: const Duration(seconds: 90));
    _applySnapshot(snap);
    currentModelId = snap['modelId']?.toString() ?? modelId;
  }

  @override
  void setPermissionPolicy(PermissionPolicy policy) {
    permissionPolicy = policy;
  }

  @override
  void resolvePermission(Object requestId, String optionId) {
    unawaited(
      _client
          .request('session.respond_permission', {
            'chatId': chatId,
            'requestId': '$requestId',
            'optionId': optionId,
          })
          .catchError((Object e) {
            SafeLog.d('ADSM respond_permission failed', e);
            return <String, dynamic>{};
          }),
    );
    _updates.add(AcpUpdate.permission(optionId));
  }

  @override
  void cancelOpenPermissions() {
    // Daemon auto-cancels on session.cancel; nothing local to clear.
  }

  @override
  Future<void> ensureModelCatalog({
    required List<Map<String, dynamic>> mcpServers,
  }) async {
    if (availableModels.isNotEmpty) return;
    try {
      final snap = await _client.request('session.refresh_models', {
        'chatId': chatId,
        'mcpServers': mcpServers,
      }, timeout: const Duration(seconds: 90));
      _applySnapshot(snap);
    } catch (e) {
      SafeLog.d('ADSM model catalog refresh failed', e);
      // Older ADSM: fall back to agents.list (may still be empty).
      try {
        final snap = await _client.request('agents.list', {});
        final agents = snap['agents'];
        if (agents is List) {
          for (final a in agents) {
            if (a is Map && a['chatId'] == chatId) {
              _applySnapshot(Map<String, dynamic>.from(a));
              break;
            }
          }
        }
      } catch (e2) {
        SafeLog.d('ADSM model catalog list fallback failed', e2);
      }
      if (availableModels.isEmpty) rethrow;
    }
  }

  @override
  void seedModelCatalog(List<AgentModel> models) {
    if (availableModels.isNotEmpty || models.isEmpty) return;
    availableModels = List<AgentModel>.unmodifiable(models);
  }

  @override
  void handOffPrompt() {
    // SSH client channel will close; daemon continues the turn.
    final c = _promptCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _promptInFlight = false;
  }

  @override
  Future<void> close() async {
    await _eventSub?.cancel();
    _eventSub = null;
    _finishPrompt();
    final pool = _bridgePool;
    if (pool != null) {
      await pool.release(host.id);
    } else {
      try {
        await _client.close();
      } catch (_) {}
    }
    if (!_updates.isClosed) {
      try {
        _updates.add(const AcpUpdate.closed());
      } catch (_) {}
      await _updates.close();
    }
  }
}
