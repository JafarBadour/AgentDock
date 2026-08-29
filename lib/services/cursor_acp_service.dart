import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../data/models/agent_mode.dart';
import '../data/models/host.dart';
import '../data/models/tool_call_state.dart';
import '../data/secure/safe_log.dart';
import '../data/secure/secure_store.dart';
import 'ssh_service.dart';

/// Minimal ACP (Agent Client Protocol) JSON-RPC client over an SSH exec session.
class AcpSession {
  AcpSession._({
    required this.host,
    required this.cwd,
    required SSHClient client,
    required SSHSession session,
  })  : _client = client,
        _session = session;

  final Host host;
  final String cwd;
  final SSHClient _client;
  final SSHSession _session;

  final _pending = <Object, Completer<Map<String, dynamic>>>{};
  final _updates = StreamController<AcpUpdate>.broadcast();
  final _buffer = StringBuffer();
  int _nextId = 1;
  String? sessionId;
  bool _started = false;
  StreamSubscription<Uint8List>? _stdoutSub;

  AgentSessionMode mode = AgentSessionMode.agent;
  PermissionPolicy permissionPolicy = PermissionPolicy.ask;
  List<String> availableModeIds = const ['ask', 'agent', 'plan'];

  Stream<AcpUpdate> get updates => _updates.stream;

  static Future<AcpSession> start({
    required SshService ssh,
    required SecureStore secureStore,
    required Host host,
    required String cwd,
    required String binary,
    List<Map<String, dynamic>> mcpServers = const [],
    AgentSessionMode initialMode = AgentSessionMode.agent,
    PermissionPolicy permissionPolicy = PermissionPolicy.ask,
  }) async {
    final client = await ssh.connect(host);
    final cursorKey = await secureStore.readCursorApiKey();

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
    final acp = AcpSession._(host: host, cwd: cwd, client: client, session: session);
    acp.mode = initialMode;
    acp.permissionPolicy = permissionPolicy;
    acp._stdoutSub = session.stdout.listen(
      acp._onStdout,
      onError: (Object e, StackTrace st) {
        SafeLog.d('ACP stdout error', e, st);
        acp._updates.add(AcpUpdate.error(e.toString()));
      },
      onDone: () {
        acp._updates.add(const AcpUpdate.closed());
      },
    );
    session.stderr.listen((data) {
      final text = utf8.decode(data);
      if (text.trim().isNotEmpty) {
        SafeLog.d('ACP stderr: ${SafeLog.redact(text)}');
      }
    });

    await acp._initialize();
    await acp._newSession(mcpServers: mcpServers);
    if (initialMode != AgentSessionMode.agent) {
      try {
        await acp.setMode(initialMode);
      } catch (e) {
        SafeLog.d('setMode after session/new failed', e);
      }
    }
    return acp;
  }

  Future<void> _initialize() async {
    await _request('initialize', {
      'protocolVersion': 1,
      'clientInfo': {'name': 'agentic_phone', 'version': '0.1.0'},
      'capabilities': {
        'fs': {'readTextFile': false, 'writeTextFile': false},
      },
    });
    await _notify('initialized', {});
  }

  Future<void> _newSession({required List<Map<String, dynamic>> mcpServers}) async {
    final result = await _request('session/new', {
      'cwd': cwd,
      'mcpServers': mcpServers,
    });
    sessionId = result['sessionId'] as String? ?? result['session_id'] as String?;
    _started = true;

    final modes = result['modes'];
    if (modes is Map) {
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

  Future<void> cancel() async {
    if (sessionId == null) return;
    try {
      await _request('session/cancel', {'sessionId': sessionId});
    } catch (e) {
      SafeLog.d('ACP cancel failed', e);
    }
  }

  Future<Map<String, dynamic>> _request(String method, Map<String, dynamic> params) async {
    final id = _nextId++;
    final key = '$id';
    final completer = Completer<Map<String, dynamic>>();
    _pending[key] = completer;
    _write({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    final timeout = switch (method) {
      'initialize' || 'session/new' => const Duration(seconds: 25),
      'session/set_mode' => const Duration(seconds: 15),
      _ => const Duration(seconds: 120),
    };
    try {
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
      _pending.remove(key);
    }
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
    _buffer.write(utf8.decode(data));
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
        _updates.add(AcpUpdate.fromParams(params));
      } else if (method == 'session/request_permission') {
        _answerPermission(msg['id'], params);
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

  Future<void> close() async {
    await _stdoutSub?.cancel();
    try {
      await _session.stdin.close();
    } catch (_) {}
    _session.close();
    _client.close();
    await _updates.close();
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

    if (type == 'plan') {
      // Plan mode content — show as a thought-style note for now.
      final entries = update['entries'] ?? update['plan'];
      if (entries is List && entries.isNotEmpty) {
        final lines = entries.map((e) {
          if (e is Map) {
            return '• ${e['content'] ?? e['text'] ?? e}';
          }
          return '• $e';
        }).join('\n');
        return AcpUpdate.thought('Plan\n$lines');
      }
      return const AcpUpdate.ignored();
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
}
