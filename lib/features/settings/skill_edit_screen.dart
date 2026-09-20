import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/platform_layout.dart';
import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../data/models/skill.dart';
import '../../data/secure/safe_log.dart';
import 'settings_screen.dart';

class SkillEditScreen extends ConsumerStatefulWidget {
  const SkillEditScreen({super.key, this.skillId, this.embedded = false});

  final String? skillId;
  final bool embedded;

  @override
  ConsumerState<SkillEditScreen> createState() => _SkillEditScreenState();
}

class _SkillEditScreenState extends ConsumerState<SkillEditScreen> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _body = TextEditingController();
  bool _disableModelInvocation = false;
  bool _loading = true;
  bool _saving = false;
  AgentSkill? _existing;
  List<Host> _hosts = const [];
  final Map<String, SkillHostLink> _links = {};
  final Set<String> _busyHosts = {};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final hosts = await db.listHosts();
    AgentSkill? skill;
    if (widget.skillId != null) {
      skill = await db.getSkill(widget.skillId!);
      if (skill != null) {
        _name.text = skill.name;
        _description.text = skill.description;
        _body.text = skill.bodyMarkdown;
        _disableModelInvocation = skill.disableModelInvocation;
        final links = await db.listSkillHostLinks(skillId: skill.id);
        for (final link in links) {
          _links[link.hostId] = link;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _existing = skill;
      _hosts = hosts;
      _loading = false;
    });
  }

  Future<AgentSkill?> _saveDefinition() async {
    var name = _name.text.trim().toLowerCase();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name is required.')),
      );
      return null;
    }
    if (!AgentSkill.isValidName(name)) {
      name = AgentSkill.slugify(name);
      _name.text = name;
    }
    if (!AgentSkill.isValidName(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Name must be lowercase letters, numbers, and hyphens '
            '(e.g. code-review).',
          ),
        ),
      );
      return null;
    }
    final description = _description.text.trim();
    if (description.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Description is required — the agent uses it to decide when '
            'to apply the skill.',
          ),
        ),
      );
      return null;
    }
    final body = _body.text.trim();
    if (body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Skill body (markdown) is required.')),
      );
      return null;
    }

    final existingByName = _existing == null
        ? await ref.read(appDatabaseProvider).findSkillByName(name)
        : null;
    if (_existing == null && existingByName != null) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'A skill named "$name" already exists — open it instead of '
            'creating a duplicate.',
          ),
        ),
      );
      return null;
    }

    final skill = AgentSkill(
      id: _existing?.id ?? const Uuid().v4(),
      name: name,
      description: description,
      bodyMarkdown: body,
      disableModelInvocation: _disableModelInvocation,
      createdAt: _existing?.createdAt ?? DateTime.now(),
    );
    await ref.read(appDatabaseProvider).upsertSkill(skill);
    ref.invalidate(skillListProvider);
    ref.invalidate(skillHostLinksProvider);
    setState(() => _existing = skill);
    return skill;
  }

  Future<void> _saveOnly() async {
    setState(() => _saving = true);
    try {
      final skill = await _saveDefinition();
      if (skill != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Skill saved.')),
        );
        if (widget.skillId == null) {
          if (widget.embedded) {
            openSettingsSubpage(context, ref, '/settings/skills/${skill.id}');
          } else {
            context.replace('/settings/skills/${skill.id}');
          }
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleHost(Host host, bool enable) async {
    final skill = await _saveDefinition();
    if (skill == null || !mounted) return;

    setState(() => _busyHosts.add(host.id));
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          enable
              ? 'Installing ${skill.name} on ${host.displayLabel}…'
              : 'Removing ${skill.name} from ${host.displayLabel}…',
        ),
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      final deploy = ref.read(skillDeployServiceProvider);
      final link = enable
          ? await deploy.deployToHost(skill: skill, host: host)
          : await deploy.removeFromHost(skill: skill, host: host);
      if (!mounted) return;
      setState(() {
        _links[host.id] = link;
        _busyHosts.remove(host.id);
      });
      ref.invalidate(skillListProvider);
      ref.invalidate(skillHostLinksProvider);
      final ok = link.installStatus == SkillHostInstallStatus.installed ||
          link.installStatus == SkillHostInstallStatus.removed;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? (enable
                    ? 'Done — ${skill.name} installed on ${host.displayLabel}'
                    : 'Done — ${skill.name} removed from ${host.displayLabel}')
                : 'Failed on ${host.displayLabel}: ${link.installDetail ?? link.installStatus.name}',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      SafeLog.d('Skill host toggle failed', e);
      if (!mounted) return;
      setState(() => _busyHosts.remove(host.id));
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<void> _delete() async {
    if (_existing == null) return;
    await ref.read(appDatabaseProvider).deleteSkill(_existing!.id);
    ref.invalidate(skillListProvider);
    ref.invalidate(skillHostLinksProvider);
    if (!mounted) return;
    if (widget.embedded) {
      closeSettingsSubpage(context, ref);
    } else {
      context.pop();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _body.dispose();
    super.dispose();
  }

  void _backToSettings() {
    if (widget.embedded) {
      closeSettingsSubpage(context, ref);
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/settings');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      if (widget.embedded) {
        return const Center(child: CircularProgressIndicator());
      }
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final title = _existing == null ? 'Add skill' : _existing!.name;
    final form = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'code-review',
            helperText: 'Lowercase letters, numbers, hyphens — becomes the folder name',
            border: OutlineInputBorder(),
          ),
          onChanged: (v) {
            // Soft-slug as they type when creating.
            if (_existing == null && v.contains(RegExp(r'[A-Z\s]'))) {
              final slug = AgentSkill.slugify(v);
              if (slug != v && AgentSkill.isValidName(slug)) {
                final sel = _name.selection;
                _name.value = TextEditingValue(
                  text: slug,
                  selection: TextSelection.collapsed(
                    offset: slug.length.clamp(0, slug.length),
                  ),
                );
                // Keep caret near end when slugifying.
                if (sel.baseOffset < slug.length) {
                  _name.selection = TextSelection.collapsed(offset: slug.length);
                }
              }
            }
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _description,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Description',
            hintText:
                'Reviews PRs against team standards. Use when the user asks for a code review or mentions a pull request.',
            helperText: 'Third person — the agent uses this to decide when to apply the skill',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _body,
          minLines: 12,
          maxLines: 24,
          decoration: const InputDecoration(
            labelText: 'SKILL.md body',
            alignLabelWithHint: true,
            hintText:
                '# Code review\n\n## Instructions\n1. …\n\n## Examples\n…',
            border: OutlineInputBorder(),
          ),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Slash-command only'),
          subtitle: const Text(
            'When on, the skill loads only via /name — not from ambient context',
          ),
          value: _disableModelInvocation,
          onChanged: (v) => setState(() => _disableModelInvocation = v),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving ? null : _saveOnly,
          child: Text(_saving ? 'Saving…' : 'Save skill'),
        ),
        const SizedBox(height: 28),
        Text(
          'Install on hosts',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Toggle a host to write ~/.cursor/skills/<name>/SKILL.md and '
          '~/.claude/skills/<name>/SKILL.md over SSH.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (_hosts.isEmpty)
          const Text('Add a host first in the Hosts tab.')
        else
          ..._hosts.map((host) {
            final link = _links[host.id];
            final enabled = link?.enabled == true &&
                link?.installStatus != SkillHostInstallStatus.removed &&
                link?.installStatus != SkillHostInstallStatus.failed;
            final busy = _busyHosts.contains(host.id) ||
                link?.installStatus == SkillHostInstallStatus.installing;
            return SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(host.displayLabel),
              subtitle: Text(
                [
                  host.endpointLabel,
                  if (link?.installStatus != null) link!.installStatus.name,
                  if (link?.installDetail != null &&
                      link!.installDetail!.isNotEmpty)
                    link.installDetail!,
                ].join(' · '),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
              value: enabled || busy && link?.enabled == true,
              onChanged: busy ? null : (v) => unawaited(_toggleHost(host, v)),
              secondary: busy
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      link?.installStatus == SkillHostInstallStatus.installed
                          ? Icons.check_circle_outline
                          : Icons.auto_awesome_outlined,
                    ),
            );
          }),
        if (_existing != null) ...[
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete skill'),
          ),
        ],
      ],
    );

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: _backToSettings,
                  icon: const Icon(Icons.arrow_back),
                ),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: form),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _backToSettings,
        ),
      ),
      body: form,
    );
  }
}
