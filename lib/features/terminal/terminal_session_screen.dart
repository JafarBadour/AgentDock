import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:xterm/xterm.dart';

import '../../app/platform_layout.dart';
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

  SSHClient? _client;
  SSHSession? _session;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  bool _connecting = true;
  bool _hasSelection = false;
  String? _error;
  String _title = 'Terminal';

  @override
  void initState() {
    super.initState();
    _terminalController.addListener(_onSelectionChanged);
    _connect();
  }

  void _onSelectionChanged() {
    final has = _terminalController.selection != null;
    if (has == _hasSelection) return;
    if (has) {
      HapticFeedback.selectionClick();
    }
    setState(() => _hasSelection = has);
  }

  String? _selectedText() {
    final selection = _terminalController.selection;
    if (selection == null) return null;
    final text = _terminal.buffer.getText(selection);
    return text.isEmpty ? null : text;
  }

  Future<void> _copySelection() async {
    final text = _selectedText();
    if (text == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Long-press text to select, then Copy.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _terminalController.clearSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Clipboard is empty'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    _terminal.paste(text);
    _terminalController.clearSelection();
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
      // Exclusive client so an interactive shell is not fighting ADSM/agent
      // channels on the shared pool connection.
      final client = await ssh.connectExclusive(host).timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw TimeoutException('SSH connect timed out'),
      );
      _client = client;
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
      await _closeClient();
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = e.toString();
        });
      }
    }
  }

  Future<void> _closeClient() async {
    final client = _client;
    _client = null;
    if (client == null) return;
    try {
      client.close();
    } catch (_) {}
  }

  Future<void> _disconnect() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    try {
      _session?.close();
    } catch (_) {}
    _session = null;
    await _closeClient();
  }

  void _closeScreen() {
    if (context.canPop()) {
      context.pop();
      return;
    }
    // Desktop center-column embed has no navigator stack under this screen.
    context.go('/agents');
  }

  void _sendKey(String seq) {
    final session = _session;
    if (session == null) return;
    session.write(Uint8List.fromList(utf8.encode(seq)));
  }

  @override
  void dispose() {
    _terminalController.removeListener(_onSelectionChanged);
    unawaited(_disconnect());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final desktop = useDesktopShell(context);
    final canPop = GoRouter.of(context).canPop();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        leading: desktop || !canPop
            ? IconButton(
                tooltip: 'Close terminal',
                icon: const Icon(Icons.close),
                onPressed: _closeScreen,
              )
            : null,
        title: Text(_title),
        actions: [
          IconButton(
            tooltip: 'Copy selection',
            onPressed: () => unawaited(_copySelection()),
            icon: Icon(
              Icons.copy,
              color: _hasSelection ? Colors.white : Colors.white54,
            ),
          ),
          IconButton(
            tooltip: 'Paste',
            onPressed: () => unawaited(_pasteClipboard()),
            icon: const Icon(Icons.paste),
          ),
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
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
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
              // Soft keyboards often omit hardware delete events.
              deleteDetection: true,
            ),
          ),
          if (!desktop)
            _SpecialKeysBar(
              onSend: _sendKey,
              onCopy: () => unawaited(_copySelection()),
              onPaste: () => unawaited(_pasteClipboard()),
              onClearSelection:
                  _hasSelection ? _terminalController.clearSelection : null,
              hasSelection: _hasSelection,
            ),
        ],
      ),
    );
  }
}

class _SpecialKeysBar extends StatelessWidget {
  const _SpecialKeysBar({
    required this.onSend,
    required this.onCopy,
    required this.onPaste,
    required this.hasSelection,
    this.onClearSelection,
  });

  final void Function(String seq) onSend;
  final VoidCallback onCopy;
  final VoidCallback onPaste;
  final VoidCallback? onClearSelection;
  final bool hasSelection;

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
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: hasSelection
                        ? const Color(0xFF3D5AFE)
                        : const Color(0xFF333333),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 36),
                  ),
                  onPressed: onCopy,
                  child: const Text('Copy', style: TextStyle(fontSize: 12)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    minimumSize: const Size(0, 36),
                  ),
                  onPressed: onPaste,
                  child: const Text('Paste', style: TextStyle(fontSize: 12)),
                ),
              ),
              if (hasSelection && onClearSelection != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 36),
                    ),
                    onPressed: onClearSelection,
                    child: const Text('Clear', style: TextStyle(fontSize: 12)),
                  ),
                ),
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
