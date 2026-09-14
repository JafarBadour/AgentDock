import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../data/models/host.dart';
import '../data/secure/safe_log.dart';
import 'background_keep_alive.dart';
import 'local_host_bootstrap.dart';
import 'local_notification_service.dart';
import 'ssh_service.dart';

/// Local proxy protocol exposed by [SshSocksService].
enum SshProxyKind {
  socks5,
  http,
}

extension SshProxyKindLabel on SshProxyKind {
  String get label => switch (this) {
        SshProxyKind.socks5 => 'SOCKS5',
        SshProxyKind.http => 'HTTP',
      };

  int get defaultPort => switch (this) {
        SshProxyKind.socks5 => 1080,
        SshProxyKind.http => 8080,
      };
}

/// Active local proxy tunnel over SSH (ssh -D / HTTP CONNECT).
class SshSocksTunnel {
  const SshSocksTunnel({
    required this.hostId,
    required this.hostLabel,
    required this.bindHost,
    required this.port,
    required this.kind,
  });

  final String hostId;
  final String hostLabel;
  final String bindHost;
  final int port;
  final SshProxyKind kind;

  String get endpoint => '$bindHost:$port';
}

/// One app-wide local proxy over a dedicated SSH session.
class SshSocksService extends ChangeNotifier {
  SshSocksService(
    this._ssh, {
    LocalNotificationService? notifications,
    BackgroundKeepAlive? keepAlive,
  })  : _notifications = notifications,
        _keepAlive = keepAlive;

  final SshService _ssh;
  final LocalNotificationService? _notifications;
  final BackgroundKeepAlive? _keepAlive;

  static const bindHost = '127.0.0.1';

  SSHClient? _client;
  SSHDynamicForward? _socksForward;
  _HttpConnectProxyServer? _httpProxy;
  SshSocksTunnel? _active;
  Host? _lastHost;
  SshProxyKind _lastKind = SshProxyKind.socks5;
  String? _error;
  bool _busy = false;
  bool _userStopped = true;
  bool _dropHandling = false;
  int _reconnectAttempts = 0;
  int _generation = 0;
  Timer? _healthTimer;

  SshSocksTunnel? get active => _active;
  String? get lastError => _error;
  bool get busy => _busy;
  SshProxyKind get lastKind => _lastKind;

  bool get isRunning {
    if (_active == null || _client == null || _client!.isClosed) return false;
    if (_active!.kind == SshProxyKind.socks5) {
      return !(_socksForward?.isClosed ?? true);
    }
    return !(_httpProxy?.isClosed ?? true);
  }

  Future<SshSocksTunnel> start(
    Host host, {
    SshProxyKind kind = SshProxyKind.socks5,
    int? preferredPort,
  }) async {
    if (isDesktopLocalHostPlatform && isLocalThisComputerHost(host)) {
      throw StateError(
        'VPN proxy needs a remote SSH host — pick a host other than This Mac/PC.',
      );
    }

    _busy = true;
    _error = null;
    _userStopped = false;
    notifyListeners();

    try {
      await _teardown(notify: false, clearActive: true);

      final client = await _ssh.connectExclusive(host).timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException(
          'Timed out opening SSH to ${host.displayLabel}.',
        ),
      );

      final portHint = preferredPort ?? kind.defaultPort;
      late final String boundHost;
      late final int boundPort;

      if (kind == SshProxyKind.socks5) {
        SSHDynamicForward forward;
        try {
          forward = await client.forwardDynamic(
            bindHost: bindHost,
            bindPort: portHint,
          );
        } catch (e) {
          SafeLog.d('SOCKS bind $portHint failed, trying ephemeral', e);
          forward = await client.forwardDynamic(bindHost: bindHost);
        }
        _socksForward = forward;
        boundHost = forward.host;
        boundPort = forward.port;
      } else {
        _HttpConnectProxyServer http;
        try {
          http = await _HttpConnectProxyServer.bind(
            client: client,
            bindHost: bindHost,
            bindPort: portHint,
          );
        } catch (e) {
          SafeLog.d('HTTP proxy bind $portHint failed, trying ephemeral', e);
          http = await _HttpConnectProxyServer.bind(
            client: client,
            bindHost: bindHost,
            bindPort: 0,
          );
        }
        _httpProxy = http;
        boundHost = http.host;
        boundPort = http.port;
      }

      _client = client;
      _lastHost = host;
      _lastKind = kind;
      _active = SshSocksTunnel(
        hostId: host.id,
        hostLabel: host.displayLabel,
        bindHost: boundHost.isEmpty ? bindHost : boundHost,
        port: boundPort,
        kind: kind,
      );
      _reconnectAttempts = 0;
      _watchClient(client);
      _startHealthTimer();
      await _syncKeepAlive();

      SafeLog.d(
        '${kind.label} tunnel up on ${_active!.endpoint} via ${host.displayLabel}',
      );
      return _active!;
    } catch (e) {
      _error = e.toString();
      SafeLog.d('proxy start failed', e);
      await _teardown(notify: false, clearActive: true);
      rethrow;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> stop({bool notify = true}) async {
    _userStopped = true;
    _reconnectAttempts = 0;
    await _teardown(notify: false, clearActive: true);
    _error = null;
    await _syncKeepAlive();
    if (notify) notifyListeners();
  }

  void _watchClient(SSHClient client) {
    final gen = ++_generation;
    // [done] completes when the transport dies — including silent drops.
    unawaited(
      client.done.then((_) {
        if (gen != _generation) return;
        unawaited(_onTransportLost('SSH session closed'));
      }).catchError((Object e) {
        if (gen != _generation) return;
        unawaited(_onTransportLost('SSH session error: $e'));
      }),
    );
  }

  void _startHealthTimer() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_healthTick());
    });
  }

  Future<void> _healthTick() async {
    final client = _client;
    if (_userStopped || client == null || _busy) return;
    if (client.isClosed) {
      await _onTransportLost('SSH transport closed');
      return;
    }
    try {
      await client.ping().timeout(const Duration(seconds: 8));
    } catch (e) {
      SafeLog.d('VPN SSH health ping failed', e);
      await _onTransportLost('SSH keep-alive failed — connection dropped');
    }
  }

  Future<void> _onTransportLost(String reason) async {
    if (_userStopped || _dropHandling) return;
    if (_active == null && _client == null) return;
    _dropHandling = true;
    try {
      final was = _active;
      final host = _lastHost;
      final kind = _lastKind;
      SafeLog.d('VPN tunnel lost: $reason');

      await _teardown(notify: false, clearActive: true);
      _error = reason;
      notifyListeners();
      await _syncKeepAlive();

      final endpoint = was?.endpoint ?? 'proxy';
      await _notifications?.notifyVpnStatus(
        title: 'VPN proxy dropped',
        body: '$endpoint — $reason. Reconnecting…',
      );

      if (host != null && _reconnectAttempts < 2 && !_userStopped) {
        _reconnectAttempts++;
        _busy = true;
        notifyListeners();
        try {
          await start(host, kind: kind);
          await _notifications?.notifyVpnStatus(
            title: 'VPN proxy restored',
            body: '${_active?.endpoint ?? endpoint} is listening again.',
          );
        } catch (e) {
          _error = 'Dropped ($reason). Reconnect failed: $e';
          SafeLog.d('VPN reconnect failed', e);
          await _notifications?.notifyVpnStatus(
            title: 'VPN proxy dropped',
            body: 'Could not reconnect. Open VPN and start again.',
          );
          notifyListeners();
        } finally {
          _busy = false;
          notifyListeners();
        }
      } else if (!_userStopped) {
        await _notifications?.notifyVpnStatus(
          title: 'VPN proxy dropped',
          body: 'Open the VPN tab and start the proxy again.',
        );
      }
    } finally {
      _dropHandling = false;
    }
  }

  Future<void> _syncKeepAlive() async {
    final keep = _keepAlive;
    if (keep == null) return;
    try {
      if (isRunning && _active != null) {
        await keep.setVpnActive(
          '${_active!.kind.label} ${_active!.endpoint} via ${_active!.hostLabel}',
        );
      } else {
        await keep.setVpnActive(null);
      }
    } catch (e) {
      SafeLog.d('VPN keep-alive sync failed', e);
    }
  }

  Future<void> _teardown({
    required bool notify,
    required bool clearActive,
  }) async {
    _generation++;
    _healthTimer?.cancel();
    _healthTimer = null;

    final socks = _socksForward;
    final http = _httpProxy;
    final client = _client;
    _socksForward = null;
    _httpProxy = null;
    _client = null;
    if (clearActive) _active = null;

    if (socks != null && !socks.isClosed) {
      try {
        await socks.close();
      } catch (e) {
        SafeLog.d('SOCKS forward close', e);
      }
    }
    if (http != null && !http.isClosed) {
      try {
        await http.close();
      } catch (e) {
        SafeLog.d('HTTP proxy close', e);
      }
    }
    if (client != null) {
      try {
        client.close();
      } catch (e) {
        SafeLog.d('VPN SSH close', e);
      }
    }
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    _userStopped = true;
    unawaited(_teardown(notify: false, clearActive: true));
    super.dispose();
  }
}

/// Minimal HTTP CONNECT proxy that tunnels via SSH direct-tcpip.
class _HttpConnectProxyServer {
  _HttpConnectProxyServer._(this._server, this._client) {
    _sub = _server.listen(_handleClient);
  }

  final ServerSocket _server;
  final SSHClient _client;
  late final StreamSubscription<Socket> _sub;
  final _active = <_HttpConnectSession>{};
  bool _closed = false;

  String get host => _server.address.address;
  int get port => _server.port;
  bool get isClosed => _closed;

  static Future<_HttpConnectProxyServer> bind({
    required SSHClient client,
    required String bindHost,
    required int bindPort,
  }) async {
    final server = await ServerSocket.bind(
      InternetAddress(bindHost, type: InternetAddressType.IPv4),
      bindPort,
    );
    return _HttpConnectProxyServer._(server, client);
  }

  void _handleClient(Socket socket) {
    if (_closed || _client.isClosed) {
      socket.destroy();
      return;
    }
    late final _HttpConnectSession session;
    session = _HttpConnectSession(
      socket: socket,
      client: _client,
      onDone: () => _active.remove(session),
    );
    _active.add(session);
    unawaited(session.run());
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _sub.cancel();
    await _server.close();
    final copies = _active.toList();
    _active.clear();
    for (final s in copies) {
      await s.close();
    }
  }
}

class _HttpConnectSession {
  _HttpConnectSession({
    required this.socket,
    required this.client,
    required this.onDone,
  });

  final Socket socket;
  final SSHClient client;
  final void Function() onDone;

  SSHForwardChannel? _remote;
  StreamSubscription<List<int>>? _localSub;
  StreamSubscription<Uint8List>? _remoteSub;
  bool _closed = false;

  Future<void> run() async {
    try {
      final (header, leftover) = await _readHeaders(socket).timeout(
        const Duration(seconds: 15),
      );
      final first = header.split('\r\n').first;
      final match = RegExp(
        r'^CONNECT\s+([^:\s]+):(\d+)\s+HTTP/\d',
        caseSensitive: false,
      ).firstMatch(first);
      if (match == null) {
        socket.add(
          utf8.encode(
            'HTTP/1.1 405 Method Not Allowed\r\n'
            'Connection: close\r\n'
            'Content-Length: 0\r\n\r\n',
          ),
        );
        await socket.flush();
        await close();
        return;
      }
      final host = match.group(1)!;
      final port = int.parse(match.group(2)!);
      if (client.isClosed) {
        throw StateError('SSH client closed');
      }
      _remote = await client.forwardLocal(host, port).timeout(
        const Duration(seconds: 20),
      );
      socket.add(utf8.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
      await socket.flush();
      if (leftover.isNotEmpty) {
        _remote!.sink.add(leftover);
      }

      _localSub = socket.listen(
        (data) {
          final remote = _remote;
          if (remote == null || _closed) return;
          remote.sink.add(data);
        },
        onError: (_) => unawaited(close()),
        onDone: () => unawaited(close()),
        cancelOnError: true,
      );
      _remoteSub = _remote!.stream.listen(
        (data) {
          if (_closed) return;
          socket.add(data);
        },
        onError: (_) => unawaited(close()),
        onDone: () => unawaited(close()),
        cancelOnError: true,
      );
    } catch (e) {
      SafeLog.d('HTTP CONNECT failed', e);
      try {
        if (!_closed) {
          socket.add(
            utf8.encode(
              'HTTP/1.1 502 Bad Gateway\r\n'
              'Connection: close\r\n'
              'Content-Length: 0\r\n\r\n',
            ),
          );
        }
      } catch (_) {}
      await close();
    }
  }

  Future<(String, Uint8List)> _readHeaders(Socket socket) async {
    final buffer = BytesBuilder(copy: false);
    final completer = Completer<(String, Uint8List)>();
    late final StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (chunk) {
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        for (var i = 3; i < bytes.length; i++) {
          if (bytes[i - 3] == 13 &&
              bytes[i - 2] == 10 &&
              bytes[i - 1] == 13 &&
              bytes[i] == 10) {
            unawaited(sub.cancel());
            if (!completer.isCompleted) {
              completer.complete((
                utf8.decode(bytes.sublist(0, i + 1)),
                Uint8List.sublistView(bytes, i + 1),
              ));
            }
            return;
          }
        }
        if (bytes.length > 65536 && !completer.isCompleted) {
          unawaited(sub.cancel());
          completer.completeError(StateError('HTTP header too large'));
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(StateError('Client closed before headers'));
        }
      },
      cancelOnError: true,
    );
    return completer.future;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _localSub?.cancel();
    } catch (_) {}
    try {
      await _remoteSub?.cancel();
    } catch (_) {}
    try {
      await _remote?.close();
    } catch (_) {}
    try {
      socket.destroy();
    } catch (_) {}
    onDone();
  }
}
