import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../app/providers.dart';
import '../../data/secure/safe_log.dart';

class TerminalSessionScreen extends ConsumerStatefulWidget {
  const TerminalSessionScreen({super.key, required this.hostId});

  final String hostId;

  @override
  ConsumerState<TerminalSessionScreen> createState() =>
      _TerminalSessionScreenState();
}

class _TerminalSessionScreenState extends ConsumerState<TerminalSessionScreen> {
  final _terminal = Terminal(maxLines: 10000);
  final _terminalController = TerminalController();

  SSHSession? _session;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  bool _connecting = true;
  String? _error;
  String _title = 'Terminal';

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    _terminal.write('Connecting…\r\n');

    try {
      final host = await ref.read(appDatabaseProvider).getHost(widget.hostId);
      if (host == null) {
        throw StateError('Host not found');
      }
      _title = host.displayLabel;

      final ssh = ref.read(sshServiceProvider);
      final client = await ssh.connect(host).timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw TimeoutException('SSH connect timed out'),
      );
      final session = await client
          .shell(
            pty: SSHPtyConfig(
              type: 'xterm-256color',
              width: _terminal.viewWidth > 0 ? _terminal.viewWidth : 80,
              height: _terminal.viewHeight > 0 ? _terminal.viewHeight : 24,
            ),
          )
          .timeout(
            const Duration(seconds: 20),
            onTimeout: () => throw TimeoutException('Opening shell timed out'),
          );
      _session = session;

      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);

      _terminal.onTitleChange = (title) {
        if (!mounted) return;
        setState(() => _title = title.isEmpty ? host.displayLabel : title);
      };

      _terminal.onResize = (width, height, pixelWidth, pixelHeight) {
        try {
          session.resizeTerminal(width, height, pixelWidth, pixelHeight);
        } catch (e) {
          SafeLog.d('resizeTerminal failed', e);
        }
      };

      _terminal.onOutput = (data) {
        session.write(Uint8List.fromList(utf8.encode(data)));
      };

      _stdoutSub = session.stdout.listen(
        (data) => _terminal.write(utf8.decode(data, allowMalformed: true)),
        onError: (Object e) => SafeLog.d('terminal stdout error', e),
        onDone: () {
          _terminal.write('\r\n[session closed]\r\n');
        },
      );
      _stderrSub = session.stderr.listen(
        (data) => _terminal.write(utf8.decode(data, allowMalformed: true)),
      );

      if (mounted) {
        setState(() => _connecting = false);
      }
    } catch (e) {
      SafeLog.d('terminal connect failed', e);
      _terminal.write('\r\nFailed: $e\r\n');
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _disconnect() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    try {
      _session?.close();
    } catch (_) {}
    // The client is pooled and shared with agent sessions; closing it here
    // would drop them too. Releasing the shell channel is enough.
    _session = null;
  }

  void _sendKey(String seq) {
    final session = _session;
    if (session == null) return;
    session.write(Uint8List.fromList(utf8.encode(seq)));
  }

  @override
  void dispose() {
    unawaited(_disconnect());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(_title),
        actions: [
          if (_connecting)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: 'Reconnect',
              onPressed: () async {
                await _disconnect();
                await _connect();
              },
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                title: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                ),
              ),
            ),
          Expanded(
            child: TerminalView(
              _terminal,
              controller: _terminalController,
              autofocus: true,
              backgroundOpacity: 1,
              theme: TerminalThemes.whiteOnBlack,
            ),
          ),
          _SpecialKeysBar(onSend: _sendKey),
        ],
      ),
    );
  }
}

class _SpecialKeysBar extends StatelessWidget {
  const _SpecialKeysBar({required this.onSend});

  final void Function(String seq) onSend;

  @override
  Widget build(BuildContext context) {
    final keys = <(String, String)>[
      ('Esc', '\x1b'),
      ('Tab', '\t'),
      ('Ctrl-C', '\x03'),
      ('Ctrl-D', '\x04'),
      ('Ctrl-Z', '\x1a'),
      ('Ctrl-L', '\x0c'),
      ('↑', '\x1b[A'),
      ('↓', '\x1b[B'),
      ('←', '\x1b[D'),
      ('→', '\x1b[C'),
    ];

    return Material(
      color: const Color(0xFF1A1A1A),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              for (final key in keys)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 36),
                    ),
                    onPressed: () => onSend(key.$2),
                    child: Text(key.$1, style: const TextStyle(fontSize: 12)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
