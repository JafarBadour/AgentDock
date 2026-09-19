import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/secure/safe_log.dart';

/// SSH private key + chat mic language.
///
/// API keys live under Settings → API keys.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({
    super.key,
    this.embedded = false,
    this.nestedInParentScroll = false,
  });

  final bool embedded;

  /// When true, use a non-scrolling shrink-wrapped list for embedding in
  /// another [ListView] (Settings).
  final bool nestedInParentScroll;

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _keyController = TextEditingController();
  final _passphraseController = TextEditingController();
  final _gcpLangController = TextEditingController(text: 'en-US');
  bool _hasKey = false;
  bool _saving = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = ref.read(secureStoreProvider);
    final hasKey = await store.hasSshPrivateKey();
    final gcpLang = await store.readGcpSpeechLanguage();
    if (!mounted) return;
    setState(() {
      _hasKey = hasKey;
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

  Future<void> _saveGcpKey() async {
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final store = ref.read(secureStoreProvider);
      await store.saveGcpSpeechLanguage(_gcpLangController.text);
      await _load();
      setState(
        () =>
            _status = 'Speech language saved. Mic uses on-device recognition.',
      );
    } catch (e) {
      SafeLog.d('save speech language failed', e);
      setState(() => _status = 'Failed to save speech language: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _keyController.dispose();
    _passphraseController.dispose();
    _gcpLangController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nested = widget.nestedInParentScroll;
    final body = ListView(
      shrinkWrap: nested,
      physics: nested ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.all(nested ? 0 : (widget.embedded ? 12 : 16)),
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
          title: Text(
            _hasKey ? 'SSH private key stored' : 'No SSH private key',
          ),
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
          leading: const Icon(Icons.mic),
          title: const Text('Chat mic'),
          subtitle: const Text(
            'Uses on-device speech recognition (no Gemini upload). '
            'Set a language hint below if needed.',
          ),
        ),
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
        FilledButton.tonal(
          onPressed: _saving ? null : _saveGcpKey,
          child: const Text('Save language'),
        ),
        if (_status != null) ...[
          const SizedBox(height: 20),
          Text(_status!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );

    if (widget.embedded || widget.nestedInParentScroll) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('Keys & credentials')),
      body: body,
    );
  }
}
