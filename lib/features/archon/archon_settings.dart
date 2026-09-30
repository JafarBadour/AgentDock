import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/secure/safe_log.dart';
import '../../services/deepgram_service.dart';
import '../agents/agents_screen.dart';
import 'archon_screen.dart';

/// Archon's settings: which host it runs on, and how it hears and speaks.
///
/// The Deepgram key is the only secret here and goes to the same secure store
/// as the agent keys, never to the metadata database.
class ArchonSettingsSheet extends ConsumerStatefulWidget {
  const ArchonSettingsSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const ArchonSettingsSheet(),
  );

  @override
  ConsumerState<ArchonSettingsSheet> createState() =>
      _ArchonSettingsSheetState();
}

class _ArchonSettingsSheetState extends ConsumerState<ArchonSettingsSheet> {
  final _key = TextEditingController();
  final _stt = TextEditingController();
  final _tts = TextEditingController();
  final _language = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _hadKey = false;

  @override
  void initState() {
    super.initState();
    unawaitedLoad();
  }

  void unawaitedLoad() {
    () async {
      String? key, stt, tts, language;
      try {
        final store = ref.read(secureStoreProvider);
        key = await store.readDeepgramApiKey();
        stt = await store.readDeepgramSttModel();
        tts = await store.readDeepgramTtsModel();
        language = await store.readDeepgramLanguage();
      } catch (e) {
        // An unreadable store must not leave the sheet spinning forever —
        // empty fields still let the user type a key and save one.
        SafeLog.d('archon settings load failed', e);
      }
      if (!mounted) return;
      setState(() {
        _hadKey = key != null && key.trim().isNotEmpty;
        // Never show a stored secret back; an empty field keeps what is saved.
        _stt.text = stt ?? '';
        _tts.text = tts ?? '';
        _language.text = language ?? '';
        _loading = false;
      });
    }();
  }

  @override
  void dispose() {
    _key.dispose();
    _stt.dispose();
    _tts.dispose();
    _language.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final store = ref.read(secureStoreProvider);
      // A blank key field leaves the saved one alone — the field starts blank
      // by design, so treating blank as "clear" would wipe it on every open.
      if (_key.text.trim().isNotEmpty) {
        await store.saveDeepgramApiKey(_key.text);
      }
      await store.saveDeepgramSttModel(_stt.text);
      await store.saveDeepgramTtsModel(_tts.text);
      await store.saveDeepgramLanguage(_language.text);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      SafeLog.d('archon settings save failed', e);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not save — $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clearKey() async {
    await ref.read(secureStoreProvider).saveDeepgramApiKey(null);
    if (!mounted) return;
    setState(() => _hadKey = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _loading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(),
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _ArchonHostSection(),
                  const SizedBox(height: 24),
                  Text('Archon voice', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Deepgram turns your speech into text and Archon\'s replies '
                    'into sound. It never sees what Archon decides.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _key,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Deepgram API key',
                      helperText: _hadKey
                          ? 'A key is saved — type to replace it'
                          : 'Required for voice',
                      suffixIcon: _hadKey
                          ? IconButton(
                              tooltip: 'Remove saved key',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _saving ? null : _clearKey,
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _stt,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Speech-to-text model',
                      hintText: DeepgramService.defaultSttModel,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _tts,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Voice',
                      hintText: DeepgramService.defaultTtsModel,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _language,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Language',
                      hintText: 'Detected automatically',
                      helperText: 'A BCP-47 tag such as en or nl',
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _saving ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// Which host Archon runs on, and moving it.
///
/// Only reachable once Archon exists — before that the whole page is the
/// picker. Moving keeps the conversation and takes its folder along; what it
/// cannot take is the ACP session, which belonged to the old host.
class _ArchonHostSection extends ConsumerStatefulWidget {
  const _ArchonHostSection();

  @override
  ConsumerState<_ArchonHostSection> createState() => _ArchonHostSectionState();
}

class _ArchonHostSectionState extends ConsumerState<_ArchonHostSection> {
  bool _moving = false;

  Future<void> _moveTo(Host host) async {
    setState(() => _moving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(archonServiceProvider).placeOn(host);
      ref.read(agentsCatalogEpochProvider.notifier).state++;
      ref.invalidate(archonHostProvider);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Archon now runs on ${host.alias}')),
      );
    } catch (e) {
      // Placement installs the skill first, and a failure there means Archon
      // would be an ordinary agent on that host — worth saying, not swallowing.
      SafeLog.d('moving archon failed', e);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('Could not move — $e')));
    } finally {
      if (mounted) setState(() => _moving = false);
    }
  }

  Future<void> _pick(List<Host> hosts, Host? current) async {
    final chosen = await showDialog<Host>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Run Archon on'),
        children: [
          for (final host in hosts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, host),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  host.id == current?.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(host.alias),
                subtitle: Text('${host.username}@${host.hostname}'),
              ),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    // Re-picking the host Archon is already on is allowed on purpose: it
    // re-runs placement, which reinstalls the skill and repairs the workspace
    // path. Refusing it would leave a bad placement with no way back.
    await _moveTo(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = ref.watch(archonHostProvider);
    final tree = ref.watch(agentsTreeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Where Archon runs', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'One host at a time. Moving brings the conversation and its memory '
          'with it. Picking the current host again reinstalls the skill.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.dns_outlined),
          title: Text(
            current.valueOrNull?.alias ?? 'Not running anywhere yet',
          ),
          subtitle: current.valueOrNull == null
              ? null
              : Text(
                  '${current.value!.username}@${current.value!.hostname}',
                ),
          trailing: _moving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : TextButton(
                  onPressed: tree.valueOrNull == null
                      ? null
                      : () => unawaited(
                          _pick(tree.value!.hosts, current.valueOrNull),
                        ),
                  child: const Text('Move'),
                ),
        ),
      ],
    );
  }
}
