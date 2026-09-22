import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/secure/safe_log.dart';
import '../../services/codex_remote_auth.dart';

/// Bottom sheet for Codex's device-code login: the host prints a link and a
/// one-time code; the user signs in on the web and the host CLI completes.
class CodexLoginSheet extends ConsumerStatefulWidget {
  const CodexLoginSheet({super.key, required this.host});

  final Host host;

  /// Returns true when remote `codex login --device-auth` succeeded.
  static Future<bool?> show(BuildContext context, {required Host host}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: CodexLoginSheet(host: host),
      ),
    );
  }

  @override
  ConsumerState<CodexLoginSheet> createState() => _CodexLoginSheetState();
}

class _CodexLoginSheetState extends ConsumerState<CodexLoginSheet> {
  CodexRemoteAuthSession? _session;
  CodexLoginPhase _phase = CodexLoginPhase.starting;
  String? _loginUrl;
  String? _userCode;
  String? _error;
  Timer? _poll;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // "Try again" — drop the previous PTY session and its UI poll first.
    _poll?.cancel();
    await _session?.close();
    _session = null;
    if (!mounted) return;
    setState(() {
      _phase = CodexLoginPhase.starting;
      _error = null;
      _loginUrl = null;
      _userCode = null;
    });
    try {
      final ssh = ref.read(sshServiceProvider);
      await ssh.ensureCodexAcpBinary(
        widget.host,
        onProgress: (msg) {
          if (!mounted) return;
          setState(() => _error = null);
        },
      );
      final auth = CodexRemoteAuth(ssh);
      final session = await auth.startLogin(widget.host);
      _session = session;
      _poll = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted || _session == null) return;
        final s = _session!;
        setState(() {
          _phase = s.phase;
          _loginUrl = s.loginUrl;
          _userCode = s.userCode;
          _error = s.error;
        });
      });
      // The CLI completes on its own once the code is approved on the web;
      // `waitForSuccess` also polls `codex login status` as a fallback.
      final ok = await auth.waitForSuccess(session);
      if (!mounted || _finishing) return;
      if (ok) {
        await _finish(success: true);
      } else {
        setState(() {
          _phase = CodexLoginPhase.error;
          _error = session.error ?? 'Login did not complete.';
        });
      }
    } catch (e) {
      SafeLog.d('codex login start failed', e);
      if (mounted) {
        setState(() {
          _phase = CodexLoginPhase.error;
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

  Future<void> _copyCode() async {
    final code = _userCode;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Code copied.')),
      );
    }
  }

  Future<void> _finish({required bool success}) async {
    if (_finishing) return;
    _finishing = true;
    _poll?.cancel();
    await _session?.close();
    if (mounted) Navigator.pop(context, success);
  }

  @override
  void dispose() {
    _poll?.cancel();
    unawaited(_session?.close());
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
              'Sign in to Codex',
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
            if (_userCode != null) ...[
              const SizedBox(height: 16),
              Center(
                child: InkWell(
                  onTap: _copyCode,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _userCode!,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            letterSpacing: 2,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Icon(Icons.copy, size: 18),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            if (_loginUrl != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _openUrl,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open sign-in page'),
              ),
              const SizedBox(height: 8),
              SelectableText(
                _loginUrl!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
            if (_phase == CodexLoginPhase.starting ||
                _phase == CodexLoginPhase.waitingForCode ||
                _phase == CodexLoginPhase.waitingForApproval) ...[
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
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_phase == CodexLoginPhase.error)
                  TextButton(
                    onPressed: _start,
                    child: const Text('Try again'),
                  ),
                TextButton(
                  onPressed: () => _finish(success: false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String get _statusLine => switch (_phase) {
        CodexLoginPhase.starting =>
          'Preparing Codex on the remote host… (this signs out any existing '
              'Codex session there)',
        CodexLoginPhase.waitingForCode =>
          'Starting login — waiting for the one-time code…',
        CodexLoginPhase.waitingForApproval =>
          'Open the sign-in page, log in with your ChatGPT account and enter '
              'this code. The host finishes automatically.',
        CodexLoginPhase.success => 'Signed in successfully.',
        CodexLoginPhase.error => 'Could not sign in.',
      };
}

/// Host picker + launch for Settings → Codex sign-in.
class CodexHostLoginPanel extends ConsumerStatefulWidget {
  const CodexHostLoginPanel({super.key});

  @override
  ConsumerState<CodexHostLoginPanel> createState() =>
      _CodexHostLoginPanelState();
}

class _CodexHostLoginPanelState extends ConsumerState<CodexHostLoginPanel> {
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
        await CodexRemoteAuth(ref.read(sshServiceProvider)).isLoggedIn(host);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _loggedIn = loggedIn;
    });
  }

  Future<void> _signIn() async {
    final host = _selected;
    if (host == null) return;
    if (_loggedIn == true) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Already signed in'),
          content: Text(
            'Starting a new login signs Codex out on ${host.displayLabel} '
            'first. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sign in again'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    final ok = await CodexLoginSheet.show(context, host: host);
    if (!mounted) return;
    if (ok == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Codex signed in on ${host.displayLabel}.')),
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
        title: Text('Codex sign-in'),
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
          title: const Text('Codex sign-in (remote)'),
          subtitle: Text(
            _checking
                ? 'Checking login status…'
                : _loggedIn == true
                    ? 'Signed in on ${_selected!.displayLabel}'
                    : 'Sign in on the remote host with your ChatGPT account '
                        '(Plus/Pro/Team). No API key needed.',
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
              child: const Text('Sign in to Codex'),
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
