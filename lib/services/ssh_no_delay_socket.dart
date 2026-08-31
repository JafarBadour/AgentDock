import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// [SSHSocket] over a raw [Socket] with Nagle disabled.
///
/// dartssh2's built-in socket leaves `TCP_NODELAY` off, which makes the kernel
/// hold back small writes. ACP is a stream of small JSON-RPC lines, so Nagle
/// interacting with delayed ACK adds tens of milliseconds to every message.
class SshNoDelaySocket implements SSHSocket {
  SshNoDelaySocket._(this._socket);

  final Socket _socket;

  static Future<SshNoDelaySocket> connect(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {
      // Not fatal — the connection works, it is just slightly less responsive.
    }
    return SshNoDelaySocket._(socket);
  }

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> close() async => _socket.close();

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() async => _socket.flush();

  @override
  String toString() =>
      'SshNoDelaySocket(${_socket.remoteAddress.host}:${_socket.remotePort})';
}
