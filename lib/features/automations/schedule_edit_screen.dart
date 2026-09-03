import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/models/chat.dart';
import '../../data/models/host.dart';
import '../../data/models/repo.dart';
import '../../data/models/scheduled_job.dart';
import '../agents/agents_screen.dart';

class ScheduleEditScreen extends ConsumerStatefulWidget {
  const ScheduleEditScreen({
    super.key,
    this.jobId,
    this.initialChatId,
    this.initialPrompt,
    this.initialContextSummary,
    this.useCompressedContext = false,
  });

  final String? jobId;
  final String? initialChatId;
  final String? initialPrompt;
  final String? initialContextSummary;
  final bool useCompressedContext;

  @override
  ConsumerState<ScheduleEditScreen> createState() => _ScheduleEditScreenState();
}

class _ScheduleEditScreenState extends ConsumerState<ScheduleEditScreen> {
  final _title = TextEditingController();
  final _prompt = TextEditingController();
  final _interval = TextEditingController(text: '60');
  final _donePrompt = TextEditingController();

  ScheduleKind _kind = ScheduleKind.daily;
  bool _enabled = true;
  bool _loading = true;
  bool _saving = false;
  bool _running = false;
  bool _attachContext = false;
  bool _repeatUntilDone = false;
  String? _contextSummary;
  String? _chatId;
  int _hour = 9;
  int _minute = 0;
  DateTime _onceAt = DateTime.now().add(const Duration(hours: 1));
  final Set<int> _weekdays = {DateTime.monday};
  ScheduledJob? _existing;

  List<_AgentOption> _agents = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _title.dispose();
    _prompt.dispose();
    _interval.dispose();
    _donePrompt.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final tree = await ref.read(agentsTreeProvider.future);
    final hostsById = {for (final h in tree.hosts) h.id: h};
    final options = <_AgentOption>[];
    for (final repo in tree.repos) {
      final host = hostsById[repo.hostId];
      for (final chat in tree.chatsByRepo[repo.id] ?? const <Chat>[]) {
        options.add(
          _AgentOption(
            chat: chat,
            repo: repo,
            host: host,
          ),
        );
      }
    }
    options.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );

    if (widget.jobId != null) {
      final job = await db.getScheduledJob(widget.jobId!);
      if (job != null) {
        _existing = job;
        _title.text = job.title;
        _prompt.text = job.prompt;
        _kind = job.kind;
        _enabled = job.enabled;
        _chatId = job.chatId;
        _hour = job.hour ?? 9;
        _minute = job.minute ?? 0;
        _interval.text = '${job.intervalMinutes ?? 60}';
        _onceAt = job.nextRunAt.toLocal();
        _weekdays
          ..clear()
          ..addAll(job.weekdays.isEmpty ? {DateTime.monday} : job.weekdays);
        _donePrompt.text = job.donePrompt ?? '';
        _contextSummary = job.contextSummary;
        _attachContext =
            job.contextSummary != null && job.contextSummary!.isNotEmpty;
        _repeatUntilDone = job.repeatUntilDone;
      }
    } else {
      _chatId = widget.initialChatId;
      if (widget.initialPrompt != null && widget.initialPrompt!.isNotEmpty) {
        _prompt.text = widget.initialPrompt!;
      }
      if (widget.initialContextSummary != null &&
          widget.initialContextSummary!.isNotEmpty) {
        _contextSummary = widget.initialContextSummary;
        _attachContext = true;
      } else if (widget.useCompressedContext && _chatId != null) {
        final prefs = await SharedPreferences.getInstance();
        final ctx = prefs.getString('compressed_ctx_$_chatId');
        if (ctx != null && ctx.isNotEmpty) {
          _contextSummary = ctx;
          _attachContext = true;
        }
      }
    }

    if (_chatId == null && options.isNotEmpty) {
      _chatId = options.first.chat.id;
    }

    if (mounted) {
      setState(() {
        _agents = options;
        _loading = false;
      });
    }
  }

  Future<void> _pickOnceDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _onceAt,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_onceAt),
    );
    if (time == null || !mounted) return;
    setState(() {
      _onceAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _pickDailyTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _hour, minute: _minute),
    );
    if (time == null || !mounted) return;
    setState(() {
      _hour = time.hour;
      _minute = time.minute;
    });
  }

  Future<void> _save() async {
    final prompt = _prompt.text.trim();
    final chatId = _chatId;
    if (chatId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Create an agent chat first.')),
      );
      return;
    }
    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Prompt is required.')),
      );
      return;
    }
    if (_kind == ScheduleKind.weekly && _weekdays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick at least one weekday.')),
      );
      return;
    }

    setState(() => _saving = true);
    final now = DateTime.now();
    final intervalMins = int.tryParse(_interval.text.trim()) ?? 60;
    final title = _title.text.trim().isEmpty
        ? (prompt.length > 40 ? '${prompt.substring(0, 40)}…' : prompt)
        : _title.text.trim();

    final next = _kind == ScheduleKind.once
        ? _onceAt
        : ScheduledJob.initialNextRun(
            kind: _kind,
            now: now,
            preferred: _kind == ScheduleKind.once ? _onceAt : null,
            intervalMinutes: intervalMins,
            hour: _hour,
            minute: _minute,
            weekdays: _weekdays.toList()..sort(),
          );

    final done = _donePrompt.text.trim();
    final job = ScheduledJob(
      id: _existing?.id ?? const Uuid().v4(),
      number: _existing?.number ??
          await ref.read(appDatabaseProvider).nextScheduledJobNumber(),
      title: title,
      chatId: chatId,
      prompt: prompt,
      kind: _kind,
      enabled: _enabled,
      intervalMinutes: _kind == ScheduleKind.interval ? intervalMins : null,
      hour: (_kind == ScheduleKind.daily || _kind == ScheduleKind.weekly)
          ? _hour
          : null,
      minute: (_kind == ScheduleKind.daily || _kind == ScheduleKind.weekly)
          ? _minute
          : null,
      weekdays:
          _kind == ScheduleKind.weekly ? (_weekdays.toList()..sort()) : const [],
      nextRunAt: next,
      lastRunAt: _existing?.lastRunAt,
      lastError: null,
      donePrompt: done.isEmpty ? null : done,
      contextSummary: _attachContext ? _contextSummary : null,
      repeatUntilDone: done.isNotEmpty && _repeatUntilDone,
      createdAt: _existing?.createdAt ?? now,
      updatedAt: now,
    );

    try {
      await ref.read(scheduleRunnerProvider).saveJob(job);
      if (mounted) {
        setState(() => _saving = false);
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved locally; host sync failed: $e')),
        );
        context.pop();
      }
    }
  }

  Future<void> _delete() async {
    final id = _existing?.id;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete schedule?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(scheduleRunnerProvider).deleteJob(id);
    if (mounted) context.pop();
  }

  Future<void> _runNow() async {
    if (_existing == null) {
      await _save();
      return;
    }
    setState(() => _running = true);
    try {
      await ref.read(scheduleRunnerProvider).runNow(_existing!.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Host is running the schedule.')),
        );
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Run failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final ctxPreview = _contextSummary?.trim() ?? '';
    final hasCtx = ctxPreview.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _existing == null
              ? 'New schedule'
              : 'Edit ${_existing!.numberLabel}',
        ),
        actions: [
          if (_existing != null)
            IconButton(
              tooltip: 'Delete',
              onPressed: _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: 'Title',
              hintText: 'Optional — defaults from prompt',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            // ignore: deprecated_member_use
            value: _agents.any((a) => a.chat.id == _chatId) ? _chatId : null,
            decoration: const InputDecoration(labelText: 'Agent chat'),
            items: [
              for (final a in _agents)
                DropdownMenuItem(
                  value: a.chat.id,
                  child: Text(a.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: _agents.isEmpty
                ? null
                : (v) => setState(() => _chatId = v),
          ),
          if (_agents.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'No agent chats yet — create one under Agents first.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _prompt,
            minLines: 4,
            maxLines: 10,
            decoration: const InputDecoration(
              labelText: 'Prompt',
              alignLabelWithHint: true,
              hintText: 'What should the agent do when this fires?',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _donePrompt,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Done criteria (optional)',
              alignLabelWithHint: true,
              hintText:
                  'After each run, ask the agent if this is finished. '
                  'It must answer DONE: yes or DONE: no.',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Repeat until done'),
            subtitle: const Text(
              'Keep the schedule enabled until the agent answers DONE: yes',
            ),
            value: _repeatUntilDone,
            onChanged: (v) => setState(() => _repeatUntilDone = v),
          ),
          if (hasCtx)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Attach compressed context'),
              subtitle: Text(
                ctxPreview.length > 120
                    ? '${ctxPreview.substring(0, 120)}…'
                    : ctxPreview,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              value: _attachContext,
              onChanged: (v) => setState(() => _attachContext = v),
            ),
          const SizedBox(height: 12),
          Text('Schedule', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in ScheduleKind.values)
                ChoiceChip(
                  label: Text(k.label),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
            ],
          ),
          const SizedBox(height: 16),
          ..._kindFields(context),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Enabled'),
            subtitle: const Text(
              'Runs on the host ADSM even if this phone is offline',
            ),
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
          if (_existing != null) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _running || _saving ? null : _runNow,
              child: Text(_running ? 'Running…' : 'Run now'),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _kindFields(BuildContext context) {
    switch (_kind) {
      case ScheduleKind.once:
        return [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Run at'),
            subtitle: Text(_fmt(_onceAt)),
            trailing: const Icon(Icons.event),
            onTap: _pickOnceDate,
          ),
        ];
      case ScheduleKind.interval:
        return [
          TextField(
            controller: _interval,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Every N minutes',
              helperText: 'Minimum 1 · first run after save',
            ),
          ),
        ];
      case ScheduleKind.daily:
        return [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Time of day'),
            subtitle: Text(
              '${_hour.toString().padLeft(2, '0')}:'
              '${_minute.toString().padLeft(2, '0')}',
            ),
            trailing: const Icon(Icons.schedule),
            onTap: _pickDailyTime,
          ),
        ];
      case ScheduleKind.weekly:
        return [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Time of day'),
            subtitle: Text(
              '${_hour.toString().padLeft(2, '0')}:'
              '${_minute.toString().padLeft(2, '0')}',
            ),
            trailing: const Icon(Icons.schedule),
            onTap: _pickDailyTime,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final day in const [
                DateTime.monday,
                DateTime.tuesday,
                DateTime.wednesday,
                DateTime.thursday,
                DateTime.friday,
                DateTime.saturday,
                DateTime.sunday,
              ])
                FilterChip(
                  label: Text(_dayName(day)),
                  selected: _weekdays.contains(day),
                  onSelected: (on) {
                    setState(() {
                      if (on) {
                        _weekdays.add(day);
                      } else {
                        _weekdays.remove(day);
                      }
                    });
                  },
                ),
            ],
          ),
        ];
    }
  }

  static String _dayName(int d) => switch (d) {
        1 => 'Mon',
        2 => 'Tue',
        3 => 'Wed',
        4 => 'Thu',
        5 => 'Fri',
        6 => 'Sat',
        7 => 'Sun',
        _ => '?',
      };

  static String _fmt(DateTime dt) {
    final l = dt.toLocal();
    String p(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${p(l.month)}-${p(l.day)} ${p(l.hour)}:${p(l.minute)}';
  }
}

class _AgentOption {
  const _AgentOption({
    required this.chat,
    required this.repo,
    this.host,
  });

  final Chat chat;
  final Repo repo;
  final Host? host;

  String get label {
    final hostLabel = host?.displayLabel ?? 'host';
    return '${chat.title} · ${repo.name} · $hostLabel';
  }
}
