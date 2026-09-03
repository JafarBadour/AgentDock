import 'package:flutter/material.dart';

import '../../data/models/agent_model.dart';

/// Bottom sheet for picking the agent model.
///
/// Thinking / Fast / context are baked into each preset by the agent rather
/// than being separately settable, so they appear here as filters and badges —
/// you narrow the list down to the combination you want and pick it.
class ModelPickerSheet extends StatefulWidget {
  const ModelPickerSheet({
    super.key,
    required this.models,
    this.selectedId,
    this.connected = false,
  });

  final List<AgentModel> models;
  final String? selectedId;
  final bool connected;

  /// Returns the chosen model id, or null if dismissed.
  static Future<String?> show(
    BuildContext context, {
    required List<AgentModel> models,
    String? selectedId,
    bool connected = false,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ModelPickerSheet(
        models: models,
        selectedId: selectedId,
        connected: connected,
      ),
    );
  }

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  final _search = TextEditingController();
  final _filters = <ModelFilter>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<AgentModel> get _visible {
    return widget.models
        .where((m) => m.matchesQuery(_search.text))
        .where((m) => _filters.every((f) => f.matches(m)))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _visible;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Row(
                children: [
                  Text('Model', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  Text(
                    '${visible.length} of ${widget.models.length}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Thinking, Fast and context are fixed per model. Filter to find '
                'the combination you want.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search models',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(_search.clear),
                        ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final filter in ModelFilter.values)
                    FilterChip(
                      label: Text(filter.label),
                      selected: _filters.contains(filter),
                      onSelected: (on) => setState(() {
                        if (on) {
                          _filters.add(filter);
                        } else {
                          _filters.remove(filter);
                        }
                      }),
                    ),
                ],
              ),
            ),
            const Divider(height: 16),
            Flexible(
              child: visible.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                      child: Text(
                        widget.models.isEmpty
                            ? (widget.connected
                                ? 'Connected, but the agent has not advertised any models yet. Close this, wait a moment, then open Model again.'
                                : 'No models yet. Tap Connect on the chat first — the list loads from the live agent session.')
                            : 'No model matches those filters. Clear Thinking / Fast / Large context and try again.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final model = visible[index];
                        final selected = model.modelId == widget.selectedId;
                        return ListTile(
                          leading: Icon(
                            selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            color: selected ? theme.colorScheme.primary : null,
                          ),
                          title: Text(
                            model.name,
                            style: TextStyle(
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.normal,
                            ),
                          ),
                          subtitle: model.badges.isEmpty
                              ? null
                              : Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      for (final badge in model.badges)
                                        _Badge(text: badge),
                                    ],
                                  ),
                                ),
                          onTap: () => Navigator.pop(context, model.modelId),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
