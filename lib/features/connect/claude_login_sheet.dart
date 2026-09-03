import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/secure/safe_log.dart';
import '../../services/claude_remote_auth.dart';

/// Bottom sheet: open Claude login URL, paste the code from the browser.
class ClaudeLoginSheet extends ConsumerStatefulWidget {
  const ClaudeLoginSheet({super.key, required this.host});

  final Host host;

  /// Returns true when remote `claude auth login` succeeded.
  static Future<bool?> show(BuildContext context, {required Host host}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ClaudeLoginSheet(host: host),
      ),
    );
  }

  @override
  ConsumerState<ClaudeLoginSheet> createState() => _ClaudeLoginSheetState();
}

class _ClaudeLoginSheetState extends ConsumerState<ClaudeLoginSheet> {
  final _code = TextEditingController();
  ClaudeRemoteAuthSession? _session;
  ClaudeLoginPhase _phase = ClaudeLoginPhase.starting;
  String? _loginUrl;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _phase = ClaudeLoginPhase.starting;
      _error = null;
      _loginUrl = null;
    });
    try {
      final ssh = ref.read(sshServiceProvider);
      await ssh.ensureClaudeAcpBinary(
        widget.host,
        onProgress: (msg) {
          if (!mounted) return;
          setState(() => _error = null);
        },
      );
      final auth = ClaudeRemoteAuth(ssh);
      final session = await auth.startLogin(widget.host);
      _session = session;
      _poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted || _session == null) return;
        final s = _session!;
        setState(() {
          _phase = s.phase;
          _loginUrl = s.loginUrl;
          _error = s.error;
        });
        if (s.phase == ClaudeLoginPhase.success) {
          unawaited(_finish(success: true));
        }
      });
    } catch (e) {
      SafeLog.d('claude login start failed', e);
      if (mounted) {
        setState(() {
          _phase = ClaudeLoginPhase.error;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _openUrl() async {
    final url = _loginUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the login link.')),
      );
    }
  }

  Future<void> _submitCode() async {
    final session = _session;
    if (session == null) return;
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _phase = ClaudeLoginPhase.verifying;
      _error = null;
    });
    session.submitCode(code);
    final auth = ClaudeRemoteAuth(ref.read(sshServiceProvider));
    final ok = await auth.waitForSuccess(session);
    if (!mounted) return;
    if (ok) {
      await _finish(success: true);
    } else {
      setState(() {
        _phase = ClaudeLoginPhase.enterCode;
        _error = session.error ??
            'Login did not complete. Check the code and try again.';
      });
    }
  }

  Future<void> _finish({required bool success}) async {
    _poll?.cancel();
    await _session?.close();
    if (mounted) Navigator.pop(context, success);
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_session?.close());
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Sign in to Claude',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              widget.host.displayLabel,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Text(
              _statusLine,
              style: theme.textTheme.bodyMedium,
            ),
            if (_loginUrl != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _openUrl,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open Claude login in browser'),
              ),
              const SizedBox(height: 8),
              SelectableText(
                _loginUrl!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
            if (_phase == ClaudeLoginPhase.enterCode ||
                _phase == ClaudeLoginPhase.verifying) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _code,
                decoration: const InputDecoration(
                  labelText: 'Login code from browser',
                  hintText: 'Paste the code shown after you sign in',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submitCode(),
                enabled: _phase != ClaudeLoginPhase.verifying,
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed:
                    _phase == ClaudeLoginPhase.verifying ? null : _submitCode,
                child: Text(
                  _phase == ClaudeLoginPhase.verifying
                      ? 'Verifying…'
                      : 'Submit code',
                ),
              ),
            ],
            if (_phase == ClaudeLoginPhase.starting ||
                _phase == ClaudeLoginPhase.waitingForUrl) ...[
              const SizedBox(height: 20),
              const Center(child: CircularProgressIndicator()),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => _finish(success: false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }

  String get _statusLine => switch (_phase) {
        ClaudeLoginPhase.starting =>
          'Preparing Claude on the remote host…',
        ClaudeLoginPhase.waitingForUrl =>
          'Starting login — waiting for the sign-in link…',
        ClaudeLoginPhase.enterCode =>
          'Open the link, sign in with your Claude account, then paste the code the browser shows.',
        ClaudeLoginPhase.verifying => 'Checking the code on the remote host…',
        ClaudeLoginPhase.success => 'Signed in successfully.',
        ClaudeLoginPhase.error => 'Could not sign in.',
      };
}

/// Host picker + launch for Connect tab.
class ClaudeHostLoginPanel extends ConsumerStatefulWidget {
  const ClaudeHostLoginPanel({super.key});

  @override
  ConsumerState<ClaudeHostLoginPanel> createState() =>
      _ClaudeHostLoginPanelState();
}

class _ClaudeHostLoginPanelState extends ConsumerState<ClaudeHostLoginPanel> {
  List<Host> _hosts = [];
  Host? _selected;
  bool _checking = false;
  bool? _loggedIn;

  @override
  void initState() {
    super.initState();
    _loadHosts();
  }

  Future<void> _loadHosts() async {
    final hosts = await ref.read(appDatabaseProvider).listHosts();
    if (!mounted) return;
    setState(() {
      _hosts = hosts;
      _selected ??= hosts.isNotEmpty ? hosts.first : null;
    });
    if (_selected != null) unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final host = _selected;
    if (host == null) return;
    setState(() {
      _checking = true;
      _loggedIn = null;
    });
    final loggedIn =
        await ClaudeRemoteAuth(ref.read(sshServiceProvider)).isLoggedIn(host);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _loggedIn = loggedIn;
    });
  }

  Future<void> _signIn() async {
    final host = _selected;
    if (host == null) return;
    final ok = await ClaudeLoginSheet.show(context, host: host);
    if (!mounted) return;
    if (ok == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Claude signed in on ${host.displayLabel}.')),
      );
      await _refreshStatus();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hosts.isEmpty) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.login),
        title: Text('Claude sign-in'),
        subtitle: Text('Add a host under Hosts first, then sign in here.'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            _loggedIn == true ? Icons.check_circle : Icons.login,
            color: _loggedIn == true ? Colors.green : null,
          ),
          title: const Text('Claude sign-in (remote)'),
          subtitle: Text(
            _checking
                ? 'Checking login status…'
                : _loggedIn == true
                    ? 'Signed in on ${_selected!.displayLabel}'
                    : 'Sign in on the remote host with your Claude account '
                        '(Pro/Max/Team). No API key needed.',
          ),
        ),
        DropdownButtonFormField<Host>(
          initialValue: _selected,
          decoration: const InputDecoration(
            labelText: 'Host',
            border: OutlineInputBorder(),
          ),
          items: [
            for (final h in _hosts)
              DropdownMenuItem(value: h, child: Text(h.displayLabel)),
          ],
          onChanged: (h) {
            setState(() => _selected = h);
            unawaited(_refreshStatus());
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.tonal(
              onPressed: _selected == null ? null : _signIn,
              child: const Text('Sign in to Claude'),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: _checking || _selected == null ? null : _refreshStatus,
              child: const Text('Refresh'),
            ),
          ],
        ),
      ],
    );
  }
}
