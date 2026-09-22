import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/platform_layout.dart';
import '../../app/providers.dart';
import '../../data/secure/safe_log.dart';
import '../connect/claude_login_sheet.dart';
import '../connect/codex_login_sheet.dart';

/// Which secret the detail editor is for.
enum ApiKeyKind {
  cursor,
  anthropic,
  openai;

  String get routeId => name;

  static ApiKeyKind? tryParse(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final k in values) {
      if (k.name == id) return k;
    }
    return null;
  }

  String get title => switch (this) {
        cursor => 'Cursor API key',
        anthropic => 'Anthropic API key',
        openai => 'OpenAI API key',
      };

  String get fieldLabel => switch (this) {
        cursor => 'CURSOR_API_KEY',
        anthropic => 'ANTHROPIC_API_KEY',
        openai => 'OPENAI_API_KEY',
      };

  String get subtitle => switch (this) {
        cursor =>
          'Prefer logging in with the Cursor CLI on the remote host. '
              'If set, the key is injected only into that agent process environment.',
        anthropic =>
          'Optional if you signed in with Claude on the remote. '
              'If set, the key is injected only into that agent process environment.',
        openai =>
          'Optional if you signed in with ChatGPT on the remote. '
              'Used by Codex agents; note Codex keeps a copy in ~/.codex/auth.json on the host.',
      };
}

/// List of API keys — tap one to set or clear it.
class ApiKeysScreen extends ConsumerStatefulWidget {
  const ApiKeysScreen({super.key, this.embedded = false});

  final bool embedded;

  @override
  ConsumerState<ApiKeysScreen> createState() => _ApiKeysScreenState();
}

class _ApiKeysScreenState extends ConsumerState<ApiKeysScreen> {
  bool? _hasCursor;
  bool? _hasAnthropic;
  bool? _hasOpenAi;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final store = ref.read(secureStoreProvider);
    final cursor = await store.hasCursorApiKey();
    final anthropic = await store.hasAnthropicApiKey();
    final openai = await store.hasOpenAiApiKey();
    if (!mounted) return;
    setState(() {
      _hasCursor = cursor;
      _hasAnthropic = anthropic;
      _hasOpenAi = openai;
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, widget.embedded ? 16 : 32),
      children: [
        Text(
          'Keys stay on this device in the platform keystore. '
          'They are injected only into the matching agent process on the host.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        _ApiKeyTile(
          kind: ApiKeyKind.cursor,
          stored: _hasCursor,
          onTap: () => openSettingsSubpage(context, ref, '/settings/keys/cursor'),
        ),
        _ApiKeyTile(
          kind: ApiKeyKind.anthropic,
          stored: _hasAnthropic,
          onTap: () =>
              openSettingsSubpage(context, ref, '/settings/keys/anthropic'),
        ),
        _ApiKeyTile(
          kind: ApiKeyKind.openai,
          stored: _hasOpenAi,
          onTap: () => openSettingsSubpage(context, ref, '/settings/keys/openai'),
        ),
        const SizedBox(height: 20),
        Text('Claude sign-in', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Remote OAuth for Claude agents (alternative to an API key).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        const ClaudeHostLoginPanel(),
        const SizedBox(height: 20),
        Text('Codex sign-in', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'ChatGPT device-code login for Codex agents (alternative to an API key).',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        const CodexHostLoginPanel(),
      ],
    );

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => closeSettingsSubpage(context, ref),
                ),
                Expanded(
                  child: Text(
                    'API keys',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('API keys')),
      body: body,
    );
  }
}

class _ApiKeyTile extends StatelessWidget {
  const _ApiKeyTile({
    required this.kind,
    required this.stored,
    required this.onTap,
  });

  final ApiKeyKind kind;
  final bool? stored;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ready = stored == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          ready ? Icons.check_circle : Icons.key_outlined,
          color: ready ? Colors.green : null,
        ),
        title: Text(kind.title),
        subtitle: Text(ready ? 'Stored on this device' : 'Not set'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Edit a single API key.
class ApiKeyEditScreen extends ConsumerStatefulWidget {
  const ApiKeyEditScreen({
    super.key,
    required this.kind,
    this.embedded = false,
  });

  final ApiKeyKind kind;
  final bool embedded;

  @override
  ConsumerState<ApiKeyEditScreen> createState() => _ApiKeyEditScreenState();
}

class _ApiKeyEditScreenState extends ConsumerState<ApiKeyEditScreen> {
  final _controller = TextEditingController();
  bool _hasStored = false;
  bool _saving = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final store = ref.read(secureStoreProvider);
    final has = switch (widget.kind) {
      ApiKeyKind.cursor => await store.hasCursorApiKey(),
      ApiKeyKind.anthropic => await store.hasAnthropicApiKey(),
      ApiKeyKind.openai => await store.hasOpenAiApiKey(),
    };
    if (!mounted) return;
    setState(() => _hasStored = has);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final store = ref.read(secureStoreProvider);
      final raw = _controller.text;
      switch (widget.kind) {
        case ApiKeyKind.cursor:
          await store.saveCursorApiKey(raw);
        case ApiKeyKind.anthropic:
          await store.saveAnthropicApiKey(raw);
        case ApiKeyKind.openai:
          await store.saveOpenAiApiKey(raw);
      }
      _controller.clear();
      await _load();
      if (!mounted) return;
      setState(() => _status = '${widget.kind.title} saved.');
    } catch (e) {
      SafeLog.d('save api key failed', e);
      if (!mounted) return;
      setState(() => _status = 'Failed to save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    setState(() {
      _saving = true;
      _status = null;
    });
    try {
      final store = ref.read(secureStoreProvider);
      switch (widget.kind) {
        case ApiKeyKind.cursor:
          await store.saveCursorApiKey(null);
        case ApiKeyKind.anthropic:
          await store.saveAnthropicApiKey(null);
        case ApiKeyKind.openai:
          await store.saveOpenAiApiKey(null);
      }
      _controller.clear();
      await _load();
      if (!mounted) return;
      setState(() => _status = '${widget.kind.title} removed.');
    } catch (e) {
      SafeLog.d('clear api key failed', e);
      if (!mounted) return;
      setState(() => _status = 'Failed to remove: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _back() {
    if (widget.embedded) {
      openSettingsSubpage(context, ref, '/settings/keys');
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/settings/keys');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind;
    final body = ListView(
      padding: EdgeInsets.fromLTRB(16, 8, 16, widget.embedded ? 16 : 32),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            _hasStored ? Icons.check_circle : Icons.key_outlined,
            color: _hasStored ? Colors.green : null,
          ),
          title: Text(_hasStored ? 'Key stored' : 'No key stored'),
          subtitle: Text(kind.subtitle),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _controller,
          obscureText: true,
          decoration: InputDecoration(
            labelText: kind.fieldLabel,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save key'),
            ),
            const SizedBox(width: 12),
            if (_hasStored)
              OutlinedButton(
                onPressed: _saving ? null : _clear,
                child: const Text('Remove'),
              ),
          ],
        ),
        if (_status != null) ...[
          const SizedBox(height: 16),
          Text(_status!, style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _back,
                ),
                Expanded(
                  child: Text(
                    kind.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: body),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(kind.title)),
      body: body,
    );
  }
}
