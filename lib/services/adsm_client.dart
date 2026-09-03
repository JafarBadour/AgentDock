import 'dart:async';
import 'dart:convert';
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
import 'ssh_service.dart';

export 'adsm_version.dart';

/// NDJSON control client for the host ADSM daemon (`agentdock-adsm client`).
class AdsmClient {
  AdsmClient._(this._session);

  final SSHSession _session;
  final _pending = <Object, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _buffer = StringBuffer();
  StreamSubscription<Uint8List>? _sub;
  bool _open = true;
  int _nextId = 1;

  Stream<Map<String, dynamic>> get events => _events.stream;

  static Future<AdsmClient> connect(SshService ssh, Host host) async {
    final client = await ssh.connect(host);
    final session = await client.execute(
      r'''
export PATH="$HOME/.local/bin:$PATH"
if command -v agentdock-adsm >/dev/null 2>&1; then
  exec agentdock-adsm client
elif [ -x "$HOME/.local/bin/agentdock-adsm" ]; then
  exec "$HOME/.local/bin/agentdock-adsm" client
else
  echo "agentdock-adsm not found" >&2
  exit 127
fi
''',
    );
    final adsm = AdsmClient._(session);
    adsm._listen();
    // Warm ping — also learns protocol version for wire chunking.
    final pong = await adsm.request('ping', {}).timeout(const Duration(seconds: 8));
    adsm.protocolVersion = pong['version']?.toString();
    return adsm;
  }

  void _listen() {
    _sub = _session.stdout.listen(
      (data) {
        _buffer.write(utf8.decode(data, allowMalformed: true));
        var content = _buffer.toString();
        var index = content.indexOf('\n');
        while (index >= 0) {
          final line = content.substring(0, index).trim();
          content = content.substring(index + 1);
          if (line.isNotEmpty) _onLine(line);
          index = content.indexOf('\n');
        }
        _buffer
          ..clear()
          ..write(content);
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
      },
    );
    _session.stderr.listen((data) {
      final text = utf8.decode(data, allowMalformed: true).trim();
      if (text.isNotEmpty) SafeLog.d('ADSM stderr: $text');
    });
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
    final payload = jsonEncode({
      'id': id,
      'method': method,
      'params': params,
    });
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
      _session.stdin.add(utf8.encode('$payload\n'));
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
      _session.stdin.add(utf8.encode('$chunkLine\n'));
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
    try {
      await _session.stdin.close();
    } catch (_) {}
    try {
      _session.close();
    } catch (_) {}
    _failAll(StateError('ADSM closed'));
    await _events.close();
  }
}

/// Durable agent session mediated by ADSM (not a raw ACP journal bridge).
class AdsmSession implements AgentSession {
  AdsmSession._({
    required this.host,
    required this.chatId,
    required AdsmClient client,
  }) : _client = client;

  final Host host;
  final String chatId;
  final AdsmClient _client;

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

  /// Host-authoritative status when known (`idle` / `running` / …).
  String? get daemonStatus => _daemonStatus;

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
  }) async {
    final apiKey = switch (provider) {
      AgentProvider.cursor => await secureStore.readCursorApiKey(),
      AgentProvider.claude => await secureStore.readAnthropicApiKey(),
    };

    final client = await AdsmClient.connect(ssh, host);
    final session = AdsmSession._(host: host, chatId: chatId, client: client);
    session.mode = initialMode;
    session.permissionPolicy = permissionPolicy;
    session._eventSub = client.events.listen(session._onEvent);

    await client.request('session.subscribe', {
      'chatId': chatId,
      'afterSeq': 0,
    });

    final snap = await client.request(
      'agents.ensure',
      {
        'chatId': chatId,
        'cwd': cwd,
        'binary': binary,
        'provider': provider.id,
        if (apiKey != null && apiKey.isNotEmpty) 'apiKey': apiKey,
        'fullAccess': permissionPolicy.fullAccess,
        'permissionAsk': !permissionPolicy.fullAccess,
        if (resumeSessionId != null) 'resumeSessionId': resumeSessionId,
        'mcpServers': mcpServers,
        'mode': initialMode.id,
        if (preferredModelId != null && preferredModelId.isNotEmpty)
          'modelId': preferredModelId,
      },
      timeout: const Duration(seconds: 90),
    );

    session._applySnapshot(snap);
    // If ensure returned RUNNING attach without re-init, treat as resume.
    final state = snap['status']?.toString();
    if (state == 'idle' && (resumeSessionId != null || session.sessionId != null)) {
      session.resumedInPlace = snap['acpSessionId'] == resumeSessionId;
    }
    // Pull durable host transcript ASAP — before UI settles on SQLite-only.
    try {
      session.hostTranscript = await session.pullTranscript();
    } catch (e) {
      SafeLog.d('ADSM transcript.pull failed', e);
    }
    return session;
  }

  /// Messages pulled from host `~/.agentdock/messages/<chatId>.jsonl`.
  List<ChatMessage> hostTranscript = const [];

  Future<List<ChatMessage>> pullTranscript() async {
    final result = await _client.request('transcript.pull', {
      'chatId': chatId,
    });
    final raw = result['messages'];
    if (raw is! List) return const [];
    final out = <ChatMessage>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        out.add(ChatMessage.fromMap(Map<String, Object?>.from(item)));
      } catch (_) {}
    }
    hostTranscript = out;
    return out;
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
        final title = params['title']?.toString() ??
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
      case 'status':
        _daemonStatus = params['status']?.toString() ?? _daemonStatus;
        final title = params['title']?.toString();
        if (title != null && title.isNotEmpty) {
          _updates.add(AcpUpdate.status('Session', title: title));
        }
        // Map daemon lifecycle into activity when no explicit activity event.
        final st = params['status']?.toString();
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
            'availableModels':
                (params['models'] as Map)['availableModels'],
            'modelId': (params['models'] as Map)['currentModelId'] ??
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
      final rpc = _client.request(
        'session.prompt',
        {
          'chatId': chatId,
          'text': text,
          if (images.isNotEmpty)
            'images': [for (final img in images) img.toWire()],
          if (userMessageId != null && userMessageId.isNotEmpty)
            'userMessageId': userMessageId,
          if (userCreatedAt != null)
            'userCreatedAt': userCreatedAt.toUtc().toIso8601String(),
        },
        timeout: const Duration(minutes: 15),
      );
      // Race cancel() so a hung image/turn can unlock without waiting 15 min.
      final winner = await Future.any<String>([
        rpc.then((_) => 'rpc'),
        c.future.then((_) => 'cancel'),
      ]);
      if (winner == 'rpc') {
        _finishPrompt();
      } else {
        // cancel() already completed [c] via _finishPrompt — drop late RPC.
        unawaited(rpc.then((_) {}, onError: (_) {}));
      }
    } catch (e) {
      _finishPrompt();
      rethrow;
    }
    // If turn_complete arrived before RPC returned, completer already done.
    if (!c.isCompleted) {
      try {
        await c.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // RPC returned — treat as done.
      }
    }
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
    final snap = await _client.request('session.set_model', {
      'chatId': chatId,
      'modelId': modelId,
    });
    _applySnapshot(snap);
    currentModelId = modelId;
  }

  @override
  void setPermissionPolicy(PermissionPolicy policy) {
    permissionPolicy = policy;
  }

  @override
  void resolvePermission(Object requestId, String optionId) {
    unawaited(
      _client.request('session.respond_permission', {
        'chatId': chatId,
        'requestId': '$requestId',
        'optionId': optionId,
      }).catchError((Object e) {
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
      final snap = await _client.request(
        'session.refresh_models',
        {
          'chatId': chatId,
          'mcpServers': mcpServers,
        },
        timeout: const Duration(seconds: 90),
      );
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
    }
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
    try {
      await _client.close();
    } catch (_) {}
    if (!_updates.isClosed) {
      try {
        _updates.add(const AcpUpdate.closed());
      } catch (_) {}
      await _updates.close();
    }
  }
}
