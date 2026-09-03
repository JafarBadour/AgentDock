import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/secure/safe_log.dart';

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _keyController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _cursorKeyController = TextEditingController();
  final _anthropicKeyController = TextEditingController();
  final _gcpKeyController = TextEditingController();
  final _gcpLangController = TextEditingController(text: 'en-US');
  bool _hasKey = false;
  bool _hasCursorKey = false;
  bool _hasAnthropicKey = false;
  bool _hasGcpKey = false;
  bool _saving = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(scheduleRunnerProvider).tick());
    });
  }

  Future<void> _load() async {
    final store = ref.read(secureStoreProvider);
    final hasKey = await store.hasSshPrivateKey();
    final hasCursor = await store.hasCursorApiKey();
    final hasAnthropic = await store.hasAnthropicApiKey();
    final hasGcp = await store.hasGcpSpeechApiKey();
    final gcpLang = await store.readGcpSpeechLanguage();
    if (!mounted) return;
    setState(() {
      _hasKey = hasKey;
      _hasCursorKey = hasCursor;
      _hasAnthropicKey = hasAnthropic;
      _hasGcpKey = hasGcp;
      if (_gcpLangController.text.trim().isEmpty ||
          _gcpLangController.text == 'en-US') {
        _gcpLangController.text = gcpLang;
      }
    });
  }

  Future<void> _saveKey() async {
    final pem = _keyController.text.trim();
    if (pem.isEmpty) {
      setState(() => _status = 'Paste a private key first.');
      return;
    }
    if (!pem.contains('PRIVATE KEY')) {
      setState(() => _status = 'That does not look like a PEM private key.');
      return;
    }
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final store = ref.read(secureStoreProvider);
      await store.saveSshPrivateKey(pem);
      await store.saveSshPassphrase(_passphraseController.text);
      _keyController.clear();
      _passphraseController.clear();
      ref.invalidate(hasSshKeyProvider);
      await _load();
      setState(() => _status = 'SSH key saved.');
    } catch (e) {
      SafeLog.d('save key failed', e);
      setState(() => _status = 'Failed to save key: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearKey() async {
    await ref.read(secureStoreProvider).clearSshPrivateKey();
    ref.invalidate(hasSshKeyProvider);
    await _load();
    setState(() => _status = 'SSH key removed from keystore.');
  }

  Future<void> _saveCursorKey() async {
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      await ref.read(secureStoreProvider).saveCursorApiKey(_cursorKeyController.text);
      _cursorKeyController.clear();
      await _load();
      setState(() => _status = 'Cursor API key saved. Prefer agent login on the remote when possible.');
    } catch (e) {
      SafeLog.d('save cursor key failed', e);
      setState(() => _status = 'Failed to save Cursor key: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAnthropicKey() async {
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      await ref
          .read(secureStoreProvider)
          .saveAnthropicApiKey(_anthropicKeyController.text);
      _anthropicKeyController.clear();
      await _load();
      setState(
        () => _status =
            'Anthropic API key saved. Prefer `claude login` on the remote when possible.',
      );
    } catch (e) {
      SafeLog.d('save anthropic key failed', e);
      setState(() => _status = 'Failed to save Anthropic key: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveGcpKey() async {
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final store = ref.read(secureStoreProvider);
      await store.saveGcpSpeechApiKey(_gcpKeyController.text);
      await store.saveGcpSpeechLanguage(_gcpLangController.text);
      _gcpKeyController.clear();
      await _load();
      setState(
        () => _status =
            'Gemini API key saved. Chat mic uses Gemini to transcribe speech.',
      );
    } catch (e) {
      SafeLog.d('save gemini key failed', e);
      setState(() => _status = 'Failed to save Gemini key: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearGcpKey() async {
    await ref.read(secureStoreProvider).saveGcpSpeechApiKey(null);
    await _load();
    setState(() => _status = 'Gemini API key removed.');
  }

  @override
  void dispose() {
    _keyController.dispose();
    _passphraseController.dispose();
    _cursorKeyController.dispose();
    _anthropicKeyController.dispose();
    _gcpKeyController.dispose();
    _gcpLangController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Secrets stay on this device in the platform keystore. '
            'Nothing is uploaded to our servers — this app has no analytics or cloud backend.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _hasKey ? Icons.check_circle : Icons.warning_amber,
              color: _hasKey ? Colors.green : Colors.orange,
            ),
            title: Text(_hasKey ? 'SSH private key stored' : 'No SSH private key'),
            subtitle: const Text('Used only to open SSH sessions you configure'),
          ),
          TextField(
            controller: _keyController,
            maxLines: 6,
            obscureText: false,
            decoration: const InputDecoration(
              labelText: 'SSH private key (PEM)',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
              hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passphraseController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Key passphrase (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                onPressed: _saving ? null : _saveKey,
                child: const Text('Save key'),
              ),
              const SizedBox(width: 12),
              if (_hasKey)
                OutlinedButton(
                  onPressed: _saving ? null : _clearKey,
                  child: const Text('Remove key'),
                ),
            ],
          ),
          const Divider(height: 40),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _hasCursorKey ? Icons.check_circle : Icons.info_outline,
              color: _hasCursorKey ? Colors.green : null,
            ),
            title: Text(_hasCursorKey ? 'Cursor API key stored' : 'Cursor API key (optional)'),
            subtitle: const Text(
              'Prefer logging in with the Cursor CLI on the remote host. '
              'If set, the key is injected only into that agent process environment.',
            ),
          ),
          TextField(
            controller: _cursorKeyController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'CURSOR_API_KEY',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: _saving ? null : _saveCursorKey,
            child: const Text('Save Cursor key'),
          ),
          const Divider(height: 40),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _hasAnthropicKey ? Icons.check_circle : Icons.info_outline,
              color: _hasAnthropicKey ? Colors.green : null,
            ),
            title: Text(
              _hasAnthropicKey
                  ? 'Anthropic API key stored'
                  : 'Anthropic API key (optional)',
            ),
            subtitle: const Text(
              'For Claude agents. Prefer `claude login` on the remote. '
              'If set, the key is injected only into that agent process environment.',
            ),
          ),
          TextField(
            controller: _anthropicKeyController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'ANTHROPIC_API_KEY',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: _saving ? null : _saveAnthropicKey,
            child: const Text('Save Anthropic key'),
          ),
          const Divider(height: 40),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _hasGcpKey ? Icons.check_circle : Icons.mic_none,
              color: _hasGcpKey ? Colors.green : null,
            ),
            title: Text(
              _hasGcpKey
                  ? 'Gemini API key stored'
                  : 'Gemini speech (optional)',
            ),
            subtitle: const Text(
              'Powers the chat mic. Use an API key from Google AI Studio '
              '(aistudio.google.com). Audio is sent to Gemini for transcription only.',
            ),
          ),
          TextField(
            controller: _gcpKeyController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Gemini API key',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _gcpLangController,
            decoration: const InputDecoration(
              labelText: 'Language code',
              hintText: 'en-US',
              border: OutlineInputBorder(),
              helperText: 'BCP-47 code, e.g. en-US, nl-NL, de-DE',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _saving ? null : _saveGcpKey,
                child: const Text('Save Gemini key'),
              ),
              const SizedBox(width: 12),
              if (_hasGcpKey)
                OutlinedButton(
                  onPressed: _saving ? null : _clearGcpKey,
                  child: const Text('Remove'),
                ),
            ],
          ),
          if (_status != null) ...[
            const SizedBox(height: 20),
            Text(_status!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
