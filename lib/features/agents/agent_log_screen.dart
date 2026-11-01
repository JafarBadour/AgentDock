import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/models/host.dart';
import '../../services/agent_log.dart';
import 'chat_markdown.dart' show monoFamily, monoPackage;

/// The host's daemon log, with the reason this chat last stopped pulled out.
///
/// Opened from the health sheet when someone asks why they were
/// disconnected. The answer is almost always the 15-minute idle reaper, and
/// saying so plainly beats making them read 500 identical lines.
class AgentLogScreen extends ConsumerStatefulWidget {
  const AgentLogScreen({
    super.key,
    required this.host,
    required this.chatId,
    this.chatTitle,
    this.fetchOverride,
  });

  final Host host;
  final String chatId;
  final String? chatTitle;

  /// Stands in for the SSH read, so the screen can be driven in a test
  /// without a host on the other end.
  @visibleForTesting
  final Future<String> Function()? fetchOverride;

  static Future<void> open(
    BuildContext context, {
    required Host host,
    required String chatId,
    String? chatTitle,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AgentLogScreen(
          host: host,
          chatId: chatId,
          chatTitle: chatTitle,
        ),
      ),
    );
  }

  @override
  ConsumerState<AgentLogScreen> createState() => _AgentLogScreenState();
}

class _AgentLogScreenState extends ConsumerState<AgentLogScreen> {
  List<AgentLogLine> _lines = const [];
  DateTime? _modified;
  String _raw = '';
  bool _loading = true;
  bool _thisChatOnly = true;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final override = widget.fetchOverride;
    final snap = override != null
        ? AgentLogSnapshot.parse(await override())
        : await ref.read(sshServiceProvider).fetchAgentLog(widget.host);
    if (!mounted) return;
    setState(() {
      _raw = snap.text;
      _modified = snap.modified;
      _lines = parseAgentLog(snap.text);
      _loading = false;
    });
    // The newest line is the one they came for.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  List<AgentLogLine> get _visible => _thisChatOnly
      ? _lines.where((l) => l.chatId == widget.chatId).toList()
      : _lines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason = explainLastStop(
      _lines,
      chatId: widget.chatId,
      fileModified: _modified,
    );
    final visible = _visible;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent log'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            onPressed: _raw.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: _raw));
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Log copied')),
                    );
                  },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '${widget.chatTitle ?? 'This agent'} · ${widget.host.displayLabel}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (reason != null) _ReasonCard(reason: reason),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: true, label: Text('This agent')),
                    ButtonSegment(value: false, label: Text('Whole host')),
                  ],
                  selected: {_thisChatOnly},
                  onSelectionChanged: (s) =>
                      setState(() => _thisChatOnly = s.first),
                ),
                const Spacer(),
                Text(
                  '${visible.length} lines',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                ? _Empty(thisChatOnly: _thisChatOnly)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    itemCount: visible.length,
                    itemBuilder: (_, i) =>
                        _LogRow(line: visible[i], chatId: widget.chatId),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ReasonCard extends StatelessWidget {
  const _ReasonCard({required this.reason});

  final AgentStopReason reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bad = reason.kind == AgentLogKind.failure;
    final tint = bad ? theme.colorScheme.error : theme.colorScheme.primary;
    final ago = agoLabel(reason.at, certainty: reason.certainty);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tint.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                bad ? Icons.error_outline : Icons.bedtime_outlined,
                size: 17,
                color: tint,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  reason.headline,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (ago != null)
                Text(
                  ago,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(reason.detail, style: theme.textTheme.bodySmall),
          if (reason.occurrences > 1) ...[
            const SizedBox(height: 6),
            Text(
              '${reason.occurrences} times in this log',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (reason.certainty != TimeCertainty.exact) ...[
            const SizedBox(height: 6),
            Text(
              ago == null
                  ? 'This host does not timestamp its log, so there is no '
                        'time to show. Connect to it once to update ADSM.'
                  : 'Timed from the log file, not the line — this host does '
                        'not timestamp its own. Connect to it once to update '
                        'ADSM.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.line, required this.chatId});

  final AgentLogLine line;
  final String chatId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mine = line.chatId == chatId;
    final color = switch (line.kind) {
      AgentLogKind.failure => theme.colorScheme.error,
      AgentLogKind.idleStop => theme.colorScheme.onSurface,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        line.raw,
        style: theme.textTheme.bodySmall?.copyWith(
          // The bundled mono the chat already uses, so a log line needs no
          // system font to be there and looks the same on every platform.
          fontFamily: monoFamily,
          package: monoPackage,
          fontSize: 11.5,
          height: 1.35,
          color: mine ? color : color.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.thisChatOnly});

  final bool thisChatOnly;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          thisChatOnly
              ? 'Nothing in the log mentions this agent yet. Switch to '
                    '"Whole host" to see everything the daemon wrote.'
              : 'The log is empty.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
